import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:rowing_navigator/api/live_position_api.dart';
import 'package:rowing_navigator/api/message_api.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/models/remote_boat_message.dart';

import '../services/other_boat_track_store.dart';
import 'compact_position_joiner.dart';

/// RTDB/Firestore の購読経路そのものの障害。
///
/// 個別レコードの不正とは混ぜない。これだけが「他艇受信不可」の
/// system fault の根拠になる。
class TransportFault {
  final String code;

  const TransportFault(this.code);
}

/// 1隻ぶんの位置レコードが検証を通らなかったことを表す診断情報。
///
/// 通信経路は生きている証拠でもあるため、system fault の根拠にはしない。
/// 艇IDは診断へ生で出さず、SHA-256 の先頭8桁だけを残す。
class RecordFault {
  final String boatIdHash;
  final String status;
  final String? validationFailure;

  const RecordFault({
    required this.boatIdHash,
    required this.status,
    this.validationFailure,
  });

  factory RecordFault.fromTrackUpdate({
    required String boatId,
    required OtherBoatTrackUpdateStatus status,
    RemoteBoatMessageValidationFailure? validationFailure,
  }) {
    final digest = sha256.convert(utf8.encode(boatId)).toString();
    return RecordFault(
      boatIdHash: digest.substring(0, 8),
      status: status.name,
      validationFailure: validationFailure == null
          ? null
          : '${validationFailure.field}:${validationFailure.code.name}',
    );
  }

  Map<String, dynamic> toDiagnosticDetails() => {
        'boatIdHash': boatIdHash,
        'status': status,
        if (validationFailure != null) 'validationFailure': validationFailure,
      };
}

/// 個別レコードの拒否を診断用にだけ時限保持する。
///
/// この状態は通信障害へ昇格させない。30秒を過ぎた艇IDを残さず、
/// 一度受理された艇は即座に消すことで、古い不正更新をいつまでも
/// 現在の問題として扱わない。
class RejectedBoatIdRetention {
  final Duration retention;
  final Map<String, DateTime> _rejectedAt = <String, DateTime>{};

  RejectedBoatIdRetention({
    this.retention = const Duration(
      seconds: remoteDataRejectionRetentionSeconds,
    ),
  });

  void record(String boatId, {required DateTime at}) {
    _rejectedAt[boatId] = at.toUtc();
  }

  void accept(String boatId) => _rejectedAt.remove(boatId);

  void remove(String boatId) => _rejectedAt.remove(boatId);

  void prune({required DateTime now}) {
    final cutoff = now.toUtc().subtract(retention);
    _rejectedAt.removeWhere(
      (_, rejectedAt) => !rejectedAt.isAfter(cutoff),
    );
  }

  bool contains(String boatId) => _rejectedAt.containsKey(boatId);

  int get length => _rejectedAt.length;
}

/// 艇情報メッセージの送受信サービス。
/// useRealtimeDatabaseForPositions(navigator_config.dart)で
/// Realtime Database(推奨) / Firestore(切り戻し用)を切り替えられる。
/// どちらのバックエンドでも上位層のインターフェースは同一。
class MessageService {
  // Firestore バックエンド(切り戻し用に温存)
  final _firestoreRef = MessageAPI().collection;
  // Realtime Database バックエンド
  final _rtdbApi = LivePositionAPI();
  late final OtherBoatTrackStore _trackStore;
  int _serverTimeOffsetMillis = 0;
  int _acceptedFutureTimestampRecordCount = 0;
  int _maxAcceptedFutureTimestampSkewMillis = 0;
  DateTime? _serverTimeOffsetUpdatedAt;
  String? _publishedProfileFingerprint;
  StreamSubscription<DatabaseEvent>? _publisherConnectionSubscription;
  String? _publishingBoatId;
  bool _publisherConnected = false;
  bool _disconnectRemovalArmed = false;
  int _publisherConnectionEpoch = 0;
  Completer<void> _nextPublisherConnection = Completer<void>();
  Future<void>? _disconnectArmingFuture;

  MessageService({OtherBoatTrackStore? trackStore}) {
    _trackStore = trackStore ??
        OtherBoatTrackStore(estimatedServerNow: _estimatedServerNow);
  }

  DateTime _estimatedServerNow() => DateTime.now()
      .toUtc()
      .add(Duration(milliseconds: _serverTimeOffsetMillis));

  /// `.info/serverTimeOffset` の最新値 [ms]。**診断専用**。
  ///
  /// 他艇レコードの受理・棄却は「端末時計 + この値」を現在として判断する。
  /// ずれが大きいまま気づけないと、正常なレコードを未来扱いで捨てる
  /// (2026-08-05 実機ログで693件)。次回ログで確認できるよう残す。
  int get serverTimeOffsetMillis => _serverTimeOffsetMillis;

  /// 今回の航行で受理した未来時刻レコードの件数。**診断専用**。
  int get acceptedFutureTimestampRecordCount =>
      _acceptedFutureTimestampRecordCount;

  /// 今回の航行で受理した未来時刻の最大ずれ [ms]。**診断専用**。
  int get maxAcceptedFutureTimestampSkewMillis =>
      _maxAcceptedFutureTimestampSkewMillis;

  /// `.info/serverTimeOffset` の最新値を受け取った端末時刻。**診断専用**。
  DateTime? get serverTimeOffsetUpdatedAt => _serverTimeOffsetUpdatedAt;

  /// 航行単位の時計ずれカウンタを開始時にリセットする。
  void resetClockSkewDiagnostics() {
    _acceptedFutureTimestampRecordCount = 0;
    _maxAcceptedFutureTimestampSkewMillis = 0;
  }

  void _recordAcceptedFutureTimestamp(OtherBoatTrackUpdateResult result) {
    final skew = result.acceptedFutureTimestampSkew;
    if (!result.accepted || skew == null) return;
    _acceptedFutureTimestampRecordCount++;
    _maxAcceptedFutureTimestampSkewMillis = math.max(
      _maxAcceptedFutureTimestampSkewMillis,
      // serverUpdatedAtはms精度で、estimatedServerNowはus精度なので、
      // 1ms未満の正のずれも「発生した」と読めるよう1msへ丸め上げる。
      math.max(1, skew.inMilliseconds),
    );
  }

  Future<void> sendMessage(Message message) async {
    if (useRealtimeDatabaseForPositions) {
      final publishingBoatId = _publishingBoatId;
      if (publishingBoatId != null) {
        if (publishingBoatId != message.boatId) {
          throw StateError('登録した艘と異なる位置を送信できません。');
        }
        // onDisconnect登録のACKを待つのは送信専用mailboxだけ。
        // 呼出元のGPS・危険判定パイプラインはこのFutureを待たない。
        await _ensureDisconnectRemovalArmed(message.boatId);
      }
      final profileFingerprint = '${message.displayName}\u0000'
          '${message.boatType.name}\u0000${message.protocolVersion}\u0000'
          '${message.appVersion}\u0000${message.profileVersion}';
      final includeProfile = _publishedProfileFingerprint != profileFingerprint;
      final publishEpoch = _publisherConnectionEpoch;
      await _rtdbApi.publishBoatData(
        boatId: message.boatId,
        position: message.toCompactRtdbJson(
          serverUpdatedAt: ServerValue.timestamp,
        ),
        profile: includeProfile
            ? message.toRtdbProfileJson(updatedAt: ServerValue.timestamp)
            : null,
      );
      // 書込中に接続が一度でも変わった場合は、次の送信で
      // profileも再送する。onDisconnect後のposition単独復活を防ぐ。
      if (includeProfile &&
          publishEpoch == _publisherConnectionEpoch &&
          (_publishingBoatId == null || _publisherConnected)) {
        _publishedProfileFingerprint = profileFingerprint;
      }
    } else {
      final json = message.toJson()
        ..['serverUpdatedAt'] = FieldValue.serverTimestamp();
      await _firestoreRef.doc(message.boatId).set(json);
    }
  }

  Stream<List<dynamic>> getMessagesStream() {
    if (useRealtimeDatabaseForPositions) {
      return _getValidatedRtdbMessagesStream();
    }
    return _firestoreRef.snapshots().map((snapshot) {
      final List<dynamic> messages = [];
      for (final doc in snapshot.docs) {
        // 1件の不正ドキュメントで全艇の受信が止まらないよう例外を分離する
        try {
          messages.add(Message.fromJson(doc.data()));
        } catch (e) {
          messages.add(RecordFault.fromTrackUpdate(
            boatId: doc.id,
            status: OtherBoatTrackUpdateStatus.rejectedInvalidMessage,
          ));
          if (kDebugMode) {
            debugPrint('Invalid message document ignored: ${doc.id} $e');
          }
        }
      }
      return messages;
    });
  }

  /// RTDBから受けた生データをプロトコル検証し、
  /// session/sequenceの逆転と幽霊艇を排除してから上位層へ流す。
  /// 1秒タイマーは鮮度状態の更新用で、GPS処理より十分軽い。
  Stream<List<dynamic>> _getValidatedRtdbMessagesStream() {
    late final StreamController<List<dynamic>> controller;
    StreamSubscription<DatabaseEvent>? positionAddedSubscription;
    StreamSubscription<DatabaseEvent>? positionChangedSubscription;
    StreamSubscription<DatabaseEvent>? positionRemovedSubscription;
    StreamSubscription<DatabaseEvent>? profileAddedSubscription;
    StreamSubscription<DatabaseEvent>? profileChangedSubscription;
    StreamSubscription<DatabaseEvent>? profileRemovedSubscription;
    StreamSubscription<DatabaseEvent>? offsetSubscription;
    Timer? freshnessTimer;
    Timer? offsetFallbackTimer;
    final positionJoiner = CompactPositionJoiner();
    final rejectedBoatIds = RejectedBoatIdRetention();
    final pendingRecordFaults = <RecordFault>[];
    final transportFaultCodes = <String>{};
    var serverOffsetReady = false;

    List<dynamic> currentMessages() {
      _trackStore.pruneExpiredInactive();
      rejectedBoatIds.prune(now: DateTime.now());
      final result = <dynamic>[
        ..._trackStore.snapshots().map((track) {
          final json = Map<String, dynamic>.from(track.message.toJson());
          // 下流は既存Boat APIを維持するためserverUpdatedAtを参照する。
          // 端末時計同士を比較せず、storeが単調時刻で求めたageを
          // この端末のwall clockへ写して渡す。
          json['serverUpdatedAt'] =
              DateTime.now().toUtc().subtract(track.age).millisecondsSinceEpoch;
          return Message.fromRtdbJson(json);
        }),
        ...pendingRecordFaults,
        ...transportFaultCodes.map(TransportFault.new),
      ];
      pendingRecordFaults.clear();
      return result;
    }

    void emitCurrent() {
      if (!controller.isClosed) controller.add(currentMessages());
    }

    void clearTransportFault(String code) {
      transportFaultCodes.remove(code);
    }

    void retainRecordRejection(
      String sourceBoatId,
      OtherBoatTrackUpdateResult result,
    ) {
      final boatId = result.boatId ?? sourceBoatId;
      pendingRecordFaults.add(RecordFault.fromTrackUpdate(
        boatId: boatId,
        status: result.status,
        validationFailure: result.validationFailure,
      ));
      // 既に検証済みトラックがあれば、個別の古い/不正更新はその艇を
      // 受信不能とは見なさない。未登録艇だけを診断上の時限集合に残す。
      if (_trackStore.snapshot(boatId) == null) {
        rejectedBoatIds.record(boatId, at: DateTime.now());
      }
    }

    void processPosition(String boatId, Map<Object?, Object?> compact) {
      clearTransportFault('RTDB_POSITION_STREAM_ERROR');
      positionJoiner.putPosition(boatId, compact);
      if (!serverOffsetReady) {
        return;
      }
      final expanded = positionJoiner.takeExpanded(boatId);
      if (expanded == null) return;
      final result = _trackStore.ingestJson(expanded);
      _recordAcceptedFutureTimestamp(result);
      if (result.status == OtherBoatTrackUpdateStatus.rejectedInvalidMessage ||
          result.status == OtherBoatTrackUpdateStatus.rejectedCapacity) {
        retainRecordRejection(boatId, result);
        if (kDebugMode) {
          debugPrint(
            'Invalid live position ignored: $boatId '
            '${result.status} ${result.validationFailure}',
          );
        }
      } else if (result.accepted) {
        rejectedBoatIds.accept(boatId);
      }
      emitCurrent();
    }

    void onPosition(DatabaseEvent event) {
      final boatId = event.snapshot.key;
      final value = event.snapshot.value;
      if (boatId == null || value is! Map) return;
      processPosition(boatId, Map<Object?, Object?>.from(value));
    }

    void onPositionRemoved(DatabaseEvent event) {
      final boatId = event.snapshot.key;
      if (boatId == null) return;
      positionJoiner.removePosition(boatId);
      rejectedBoatIds.remove(boatId);
      // onDisconnect削除は通信断と停止の両方で起きうる。
      // 即座にsafeとせず、最後の受信時刻からのTTLまで保持する。
      emitCurrent();
    }

    void onProfile(DatabaseEvent event) {
      clearTransportFault('RTDB_PROFILE_STREAM_ERROR');
      final boatId = event.snapshot.key;
      final value = event.snapshot.value;
      if (boatId == null || value is! Map) return;
      positionJoiner.putProfile(boatId, Map<Object?, Object?>.from(value));
      if (!serverOffsetReady) return;
      final expanded = positionJoiner.takeExpanded(boatId);
      if (expanded == null) return;
      final result = _trackStore.ingestJson(expanded);
      _recordAcceptedFutureTimestamp(result);
      if (result.status == OtherBoatTrackUpdateStatus.rejectedInvalidMessage ||
          result.status == OtherBoatTrackUpdateStatus.rejectedCapacity) {
        retainRecordRejection(boatId, result);
      } else if (result.accepted) {
        rejectedBoatIds.accept(boatId);
      }
      emitCurrent();
    }

    void onProfileRemoved(DatabaseEvent event) {
      final boatId = event.snapshot.key;
      if (boatId == null) return;
      positionJoiner.removeProfile(boatId);
    }

    void onStreamError(
      String code,
      Object error,
      StackTrace stackTrace,
    ) {
      transportFaultCodes.add(code);
      if (kDebugMode) {
        debugPrint('RTDB transport stream error ($code): $error');
      }
      emitCurrent();
      // system faultを即座に可視化したあと、既存の自動再接続も維持する。
      // RecordFault と違い、ここは通信経路の失敗なので上位の
      // ResilientStreamSupervisor へも必ず伝える。
      if (!controller.isClosed) controller.addError(error, stackTrace);
    }

    void drainPending() {
      for (final boatId in positionJoiner.pendingBoatIds) {
        final expanded = positionJoiner.takeExpanded(boatId);
        if (expanded == null) continue;
        final result = _trackStore.ingestJson(expanded);
        _recordAcceptedFutureTimestamp(result);
        if (result.status ==
                OtherBoatTrackUpdateStatus.rejectedInvalidMessage ||
            result.status == OtherBoatTrackUpdateStatus.rejectedCapacity) {
          retainRecordRejection(boatId, result);
        } else if (result.accepted) {
          rejectedBoatIds.accept(boatId);
        }
      }
      emitCurrent();
    }

    controller = StreamController<List<dynamic>>(
      onListen: () {
        // サーバー時計補正を先に購読し、初回受信は最大2秒待つ。
        // .infoが利用できない場合だけ端末時計へフォールバックする。
        offsetSubscription = _rtdbApi.serverTimeOffsetRef.onValue.listen(
          (event) {
            clearTransportFault('RTDB_SERVER_OFFSET_STREAM_ERROR');
            final value = event.snapshot.value;
            if (value is num) {
              _serverTimeOffsetMillis = value.toInt();
              _serverTimeOffsetUpdatedAt = DateTime.now().toUtc();
            }
            serverOffsetReady = true;
            offsetFallbackTimer?.cancel();
            drainPending();
          },
          onError: (Object error, StackTrace stackTrace) {
            // serverTimeOffset は端末時計フォールバックを持つ補助経路であり、
            // 他艇位置の受信経路ではない。ここだけの失敗で「受信不可」には
            // しない(2秒後にdrainPendingが端末時計で処理を継続する)。
            debugPrint('Server time offset stream error: $error');
          },
        );
        // 親onValueは1艇の更新のたびに全12艇分を再転送する。
        // child差分購読で変化した1艇分だけ受け取る。
        positionAddedSubscription = _rtdbApi.ref.onChildAdded.listen(onPosition,
            onError: (Object error, StackTrace stackTrace) => onStreamError(
                  'RTDB_POSITION_STREAM_ERROR',
                  error,
                  stackTrace,
                ));
        positionChangedSubscription =
            _rtdbApi.ref.onChildChanged.listen(onPosition,
                onError: (Object error, StackTrace stackTrace) => onStreamError(
                      'RTDB_POSITION_STREAM_ERROR',
                      error,
                      stackTrace,
                    ));
        positionRemovedSubscription =
            _rtdbApi.ref.onChildRemoved.listen(onPositionRemoved,
                onError: (Object error, StackTrace stackTrace) => onStreamError(
                      'RTDB_POSITION_STREAM_ERROR',
                      error,
                      stackTrace,
                    ));
        profileAddedSubscription =
            _rtdbApi.profilesRef.onChildAdded.listen(onProfile,
                onError: (Object error, StackTrace stackTrace) => onStreamError(
                      'RTDB_PROFILE_STREAM_ERROR',
                      error,
                      stackTrace,
                    ));
        profileChangedSubscription =
            _rtdbApi.profilesRef.onChildChanged.listen(onProfile,
                onError: (Object error, StackTrace stackTrace) => onStreamError(
                      'RTDB_PROFILE_STREAM_ERROR',
                      error,
                      stackTrace,
                    ));
        profileRemovedSubscription =
            _rtdbApi.profilesRef.onChildRemoved.listen(onProfileRemoved,
                onError: (Object error, StackTrace stackTrace) => onStreamError(
                      'RTDB_PROFILE_STREAM_ERROR',
                      error,
                      stackTrace,
                    ));
        offsetFallbackTimer = Timer(const Duration(seconds: 2), () {
          serverOffsetReady = true;
          drainPending();
        });
        freshnessTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => emitCurrent(),
        );
      },
      onCancel: () async {
        freshnessTimer?.cancel();
        offsetFallbackTimer?.cancel();
        // 1本のcancel失敗で後続購読を残さない。callback側もcontrollerの
        // closeを確認するため、全購読を独立にbest-effortで解放する。
        await Future.wait<void>([
          positionAddedSubscription,
          positionChangedSubscription,
          positionRemovedSubscription,
          profileAddedSubscription,
          profileChangedSubscription,
          profileRemovedSubscription,
          offsetSubscription,
        ].whereType<StreamSubscription>().map((subscription) async {
          try {
            await subscription.cancel().timeout(const Duration(seconds: 2));
          } catch (error) {
            if (kDebugMode) {
              debugPrint('RTDB subscription cancel failed: $error');
            }
          }
        }));
      },
    );
    return controller.stream;
  }

  Future<void> clearMessage(String boatId) async {
    // offline writeのACKが保留されても、次回の最初のsendで
    // profileを必ず再掲載できるよう、ACK待ちの前に無効化する。
    _publishedProfileFingerprint = null;
    if (useRealtimeDatabaseForPositions) {
      await _rtdbApi.clearBoatData(boatId);
    } else {
      await _firestoreRef.doc(boatId).delete();
    }
  }

  /// 接続が切れたとき(アプリ強制終了・圏外など)に
  /// サーバー側で自艇データを自動削除する(RTDBのみ対応)。
  /// 幽霊艇対策のクライアント側フィルタと二重の防御になる。
  Future<void> registerOnDisconnect(String boatId) async {
    if (!useRealtimeDatabaseForPositions) return;
    await stopPublishing();
    _publishingBoatId = boatId;
    _publishedProfileFingerprint = null;
    _publisherConnected = false;
    _disconnectRemovalArmed = false;
    _publisherConnectionEpoch += 1;
    _nextPublisherConnection = Completer<void>();
    _publisherConnectionSubscription = _rtdbApi.connectedRef.onValue.listen(
      (event) {
        final connected = event.snapshot.value == true;
        if (connected == _publisherConnected) return;
        _publisherConnected = connected;
        _disconnectRemovalArmed = false;
        _publishedProfileFingerprint = null;
        _publisherConnectionEpoch += 1;
        if (connected) {
          if (!_nextPublisherConnection.isCompleted) {
            _nextPublisherConnection.complete();
          }
        } else if (_nextPublisherConnection.isCompleted) {
          _nextPublisherConnection = Completer<void>();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _publisherConnected = false;
        _disconnectRemovalArmed = false;
        _publishedProfileFingerprint = null;
        _publisherConnectionEpoch += 1;
        if (_nextPublisherConnection.isCompleted) {
          _nextPublisherConnection = Completer<void>();
        }
        debugPrint('Publisher connection stream error: $error');
      },
    );
    // 初回も必ず「onDisconnect登録→位置write」の順にする。
    // 圏外中はこのFutureが保留されるが、useNavigatorは短い
    // timeout後に端末内の安全判定を開始する。
    await _ensureDisconnectRemovalArmed(boatId);
  }

  Future<void> _ensureDisconnectRemovalArmed(String boatId) async {
    while (_publishingBoatId == boatId) {
      if (!_publisherConnected) {
        final nextConnection = _nextPublisherConnection;
        await nextConnection.future;
        continue;
      }
      if (_disconnectRemovalArmed) return;

      final armEpoch = _publisherConnectionEpoch;
      final existing = _disconnectArmingFuture;
      final arming = existing ?? _rtdbApi.armBoatDataRemoval(boatId);
      _disconnectArmingFuture = arming;
      try {
        await arming;
      } finally {
        if (identical(_disconnectArmingFuture, arming)) {
          _disconnectArmingFuture = null;
        }
      }
      if (_publishingBoatId != boatId) {
        throw StateError('位置共有セッションは終了しました。');
      }
      if (_publisherConnected && armEpoch == _publisherConnectionEpoch) {
        _disconnectRemovalArmed = true;
        return;
      }
    }
    throw StateError('位置共有セッションがありません。');
  }

  /// 再接続監視を停止する。native側で実行中のwriteは
  /// キャンセルできないため、呼出元は続けてclearMessageを発行する。
  Future<void> stopPublishing() async {
    _publishingBoatId = null;
    _publisherConnected = false;
    _disconnectRemovalArmed = false;
    _publishedProfileFingerprint = null;
    _publisherConnectionEpoch += 1;
    _disconnectArmingFuture = null;
    if (!_nextPublisherConnection.isCompleted) {
      // 接続待ちの_ensureを起こし、セッション終了として戻す。
      _nextPublisherConnection.complete();
    }
    final subscription = _publisherConnectionSubscription;
    _publisherConnectionSubscription = null;
    await subscription?.cancel();
  }
}
