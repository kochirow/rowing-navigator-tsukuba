import 'dart:collection';

import '../config/risk_evaluator_config.dart';
import '../models/remote_boat_message.dart';

enum OtherBoatTrackFreshness {
  fresh,
  degraded,
  lostForPrediction,
  expired,
}

enum OtherBoatTrackUpdateStatus {
  accepted,
  replacedSession,
  rejectedInvalidMessage,
  rejectedDuplicate,
  rejectedOutOfOrder,
  rejectedClosedSession,
  rejectedStaleTimestamp,
  rejectedCapacity,
}

class OtherBoatTrackUpdateResult {
  final OtherBoatTrackUpdateStatus status;
  final String? boatId;
  final RemoteBoatMessageValidationFailure? validationFailure;

  /// 受理したレコードの `serverUpdatedAt - estimatedServerNow`。
  ///
  /// 鮮度判定では0へ丸めるが、時計ずれの発生量は診断へ残す必要がある。
  /// 棄却・過去時刻・未来ずれのないレコードではnull。
  final Duration? acceptedFutureTimestampSkew;

  const OtherBoatTrackUpdateResult({
    required this.status,
    this.boatId,
    this.validationFailure,
    this.acceptedFutureTimestampSkew,
  });

  bool get accepted =>
      status == OtherBoatTrackUpdateStatus.accepted ||
      status == OtherBoatTrackUpdateStatus.replacedSession;

  OtherBoatTrackUpdateResult withAcceptedFutureTimestampSkew(
    Duration? skew,
  ) =>
      OtherBoatTrackUpdateResult(
        status: status,
        boatId: boatId,
        validationFailure: validationFailure,
        acceptedFutureTimestampSkew: accepted ? skew : null,
      );
}

/// 検証済み他艇トラックと、現在の通信鮮度。
class OtherBoatTrackSnapshot {
  final RemoteBoatMessage message;
  final Duration age;
  final OtherBoatTrackFreshness freshness;
  final bool isActiveWarningTarget;

  const OtherBoatTrackSnapshot({
    required this.message,
    required this.age,
    required this.freshness,
    required this.isActiveWarningTarget,
  });

  /// fresh/degradedだけが新しい直線外挿の入力にできる。
  bool get mayPredict =>
      freshness == OtherBoatTrackFreshness.fresh ||
      freshness == OtherBoatTrackFreshness.degraded;

  /// degraded以降の通信劣化は、active警告をsafeにする根拠にしない。
  bool get shouldHoldActiveWarning =>
      isActiveWarningTarget && freshness != OtherBoatTrackFreshness.fresh;

  /// expiredでもactive警告の途絶トラックはUIとFSM向けに残す。
  bool get shouldRemainVisible =>
      freshness != OtherBoatTrackFreshness.expired || isActiveWarningTarget;
}

typedef ActiveWarningTargetLookup = bool Function(String boatId);

/// 他艇ごとに受信メッセージを検証・順序付けする。
///
/// Firebaseから独立した純粋Dart部品。鮮度は受信時にserver timeとの差を
/// 固定し、その後はlocal monotonic timeだけで増加させる。
class OtherBoatTrackStore {
  static const Duration freshUntil = Duration(seconds: 3);
  static const Duration degradedUntil = Duration(seconds: 6);

  /// 予測を止めた後も、表示用TTLまでは最終位置を保持する。
  /// 停止艇の送信間隔は10秒なので、10秒ちょうどで削除すると通信ジッタで
  /// 点滅する。リスク評価層と同じ可視TTLを単一の基準にする。
  static const Duration lostForPredictionThrough =
      Duration(seconds: boatStaleTimeoutSeconds);
  static const int defaultMaxTracks = 100;
  static const int _maxClosedSessionsPerBoat = 16;

  final int maxTracks;
  final DateTime Function() _estimatedServerNow;
  final ActiveWarningTargetLookup _isActiveWarningTarget;
  final Stopwatch _stopwatch = Stopwatch();
  late final Duration Function() _monotonicNow;
  final Map<String, _TrackEntry> _entries = {};

  OtherBoatTrackStore({
    this.maxTracks = defaultMaxTracks,
    DateTime Function()? estimatedServerNow,
    Duration Function()? monotonicNow,
    ActiveWarningTargetLookup? isActiveWarningTarget,
  })  : assert(maxTracks > 0),
        _estimatedServerNow =
            estimatedServerNow ?? (() => DateTime.now().toUtc()),
        _isActiveWarningTarget = isActiveWarningTarget ?? ((_) => false) {
    if (monotonicNow != null) {
      _monotonicNow = monotonicNow;
    } else {
      _stopwatch.start();
      _monotonicNow = () => _stopwatch.elapsed;
    }
  }

  int get length => _entries.length;

  /// 生メッセージを検証し、不正な艇だけを拒否する。
  OtherBoatTrackUpdateResult ingestJson(Map<Object?, Object?> json) {
    final serverNow = _estimatedServerNow().toUtc();
    final parsed = RemoteBoatMessage.tryParse(
      json,
      estimatedServerNow: serverNow,
    );
    if (!parsed.isValid) {
      return OtherBoatTrackUpdateResult(
        status: OtherBoatTrackUpdateStatus.rejectedInvalidMessage,
        boatId: _safeBoatId(json['boatId']),
        validationFailure: parsed.failure,
      );
    }
    final message = parsed.message!;
    return _ingest(message, serverNow: serverNow)
        .withAcceptedFutureTimestampSkew(
      _acceptedFutureSkew(message, serverNow),
    );
  }

  /// 別層で既に検証したメッセージを受け入れる。
  OtherBoatTrackUpdateResult ingest(RemoteBoatMessage message) {
    final serverNow = _estimatedServerNow().toUtc();
    return _ingest(message, serverNow: serverNow)
        .withAcceptedFutureTimestampSkew(
      _acceptedFutureSkew(message, serverNow),
    );
  }

  static Duration? _acceptedFutureSkew(
    RemoteBoatMessage message,
    DateTime serverNow,
  ) {
    final skew = message.serverUpdatedAt.difference(serverNow);
    return skew.isNegative || skew == Duration.zero ? null : skew;
  }

  OtherBoatTrackUpdateResult _ingest(
    RemoteBoatMessage message, {
    required DateTime serverNow,
  }) {
    var ageAtReceipt = serverNow.difference(message.serverUpdatedAt);
    if (ageAtReceipt.isNegative) {
      // [serverNow] はサーバー時刻の推定値である。推定がわずかに遅れただけの
      // 正常なレコードを「未来から来た」として捨てない。許容を超えたものだけ
      // 棄却し、許容内は age = 0 として鮮度の階層へ渡す
      // (`freshUntil` < `boatPredictionTimeoutSeconds` < `boatStaleTimeoutSeconds`)。
      //
      // **外挿(`extrapolateToNow`)の基準は `serverUpdatedAt` のままにする。**
      // ここで丸めるのは鮮度判定に使う age だけで、位置の外挿量は変えない。
      // 取り違えると他艇が実際より先へ描かれる。
      if (ageAtReceipt.abs() > RemoteBoatMessage.maxFutureTimestampSkew) {
        return OtherBoatTrackUpdateResult(
          status: OtherBoatTrackUpdateStatus.rejectedInvalidMessage,
          boatId: message.boatId,
          validationFailure: const RemoteBoatMessageValidationFailure(
            field: 'serverUpdatedAt',
            code: RemoteBoatMessageValidationCode.futureTimestamp,
          ),
        );
      }
      ageAtReceipt = Duration.zero;
    }

    final monotonicReceivedAt = _monotonicNow();
    final existing = _entries[message.boatId];
    if (existing == null) {
      if (_entries.length >= maxTracks && !_evictExpiredInactive()) {
        return OtherBoatTrackUpdateResult(
          status: OtherBoatTrackUpdateStatus.rejectedCapacity,
          boatId: message.boatId,
        );
      }
      _entries[message.boatId] = _TrackEntry(
        message: message,
        ageAtReceipt: ageAtReceipt,
        monotonicReceivedAt: monotonicReceivedAt,
      );
      return OtherBoatTrackUpdateResult(
        status: OtherBoatTrackUpdateStatus.accepted,
        boatId: message.boatId,
      );
    }

    if (message.sessionId == existing.message.sessionId) {
      if (message.sequence == existing.message.sequence) {
        return OtherBoatTrackUpdateResult(
          status: OtherBoatTrackUpdateStatus.rejectedDuplicate,
          boatId: message.boatId,
        );
      }
      if (message.sequence < existing.message.sequence) {
        return OtherBoatTrackUpdateResult(
          status: OtherBoatTrackUpdateStatus.rejectedOutOfOrder,
          boatId: message.boatId,
        );
      }
      // session内の順序はsequenceと信頼できるserverUpdatedAtで決める。
      // 端末時刻の自動補正でobservedAtが戻っても新しい位置を捨てない。
      if (message.serverUpdatedAt.isBefore(existing.message.serverUpdatedAt)) {
        return OtherBoatTrackUpdateResult(
          status: OtherBoatTrackUpdateStatus.rejectedStaleTimestamp,
          boatId: message.boatId,
        );
      }
      existing
        ..message = message
        ..ageAtReceipt = ageAtReceipt
        ..monotonicReceivedAt = monotonicReceivedAt;
      return OtherBoatTrackUpdateResult(
        status: OtherBoatTrackUpdateStatus.accepted,
        boatId: message.boatId,
      );
    }

    if (existing.closedSessionIds.contains(message.sessionId)) {
      return OtherBoatTrackUpdateResult(
        status: OtherBoatTrackUpdateStatus.rejectedClosedSession,
        boatId: message.boatId,
      );
    }
    if (message.serverUpdatedAt.isBefore(existing.message.serverUpdatedAt)) {
      return OtherBoatTrackUpdateResult(
        status: OtherBoatTrackUpdateStatus.rejectedStaleTimestamp,
        boatId: message.boatId,
      );
    }

    existing.closedSessionIds.add(existing.message.sessionId);
    while (existing.closedSessionIds.length > _maxClosedSessionsPerBoat) {
      existing.closedSessionIds.remove(existing.closedSessionIds.first);
    }
    existing
      ..message = message
      ..ageAtReceipt = ageAtReceipt
      ..monotonicReceivedAt = monotonicReceivedAt;
    return OtherBoatTrackUpdateResult(
      status: OtherBoatTrackUpdateStatus.replacedSession,
      boatId: message.boatId,
    );
  }

  OtherBoatTrackSnapshot? snapshot(String boatId) {
    final entry = _entries[boatId];
    if (entry == null) return null;
    return _snapshot(entry);
  }

  List<OtherBoatTrackSnapshot> snapshots({bool includeHiddenExpired = false}) {
    final result = _entries.values.map(_snapshot).where(
          (snapshot) => includeHiddenExpired || snapshot.shouldRemainVisible,
        );
    return List.unmodifiable(result);
  }

  /// active警告対象は通信断だけで消さない。
  int pruneExpiredInactive() {
    final ids = _entries.entries
        .where((entry) =>
            _freshness(_age(entry.value)) == OtherBoatTrackFreshness.expired &&
            !_active(entry.key))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final id in ids) {
      _entries.remove(id);
    }
    return ids.length;
  }

  void remove(String boatId) => _entries.remove(boatId);

  OtherBoatTrackSnapshot _snapshot(_TrackEntry entry) {
    final age = _age(entry);
    return OtherBoatTrackSnapshot(
      message: entry.message,
      age: age,
      freshness: _freshness(age),
      isActiveWarningTarget: _active(entry.message.boatId),
    );
  }

  Duration _age(_TrackEntry entry) {
    final elapsed = _monotonicNow() - entry.monotonicReceivedAt;
    return entry.ageAtReceipt + (elapsed.isNegative ? Duration.zero : elapsed);
  }

  static OtherBoatTrackFreshness _freshness(Duration age) {
    if (age < freshUntil) return OtherBoatTrackFreshness.fresh;
    if (age < degradedUntil) return OtherBoatTrackFreshness.degraded;
    if (age <= lostForPredictionThrough) {
      return OtherBoatTrackFreshness.lostForPrediction;
    }
    return OtherBoatTrackFreshness.expired;
  }

  bool _evictExpiredInactive() {
    MapEntry<String, _TrackEntry>? oldest;
    Duration? oldestAge;
    for (final candidate in _entries.entries) {
      if (_active(candidate.key)) continue;
      final age = _age(candidate.value);
      if (_freshness(age) != OtherBoatTrackFreshness.expired) continue;
      if (oldestAge == null || age > oldestAge) {
        oldest = candidate;
        oldestAge = age;
      }
    }
    if (oldest == null) return false;
    _entries.remove(oldest.key);
    return true;
  }

  bool _active(String boatId) {
    try {
      return _isActiveWarningTarget(boatId);
    } catch (_) {
      // 呼出元のFSM参照が失敗した場合は、消す側に倒さない。
      return true;
    }
  }

  static String? _safeBoatId(Object? value) {
    if (value is! String || value.isEmpty || value.length > 128) return null;
    return value;
  }
}

class _TrackEntry {
  RemoteBoatMessage message;
  Duration ageAtReceipt;
  Duration monotonicReceivedAt;
  final LinkedHashSet<String> closedSessionIds = LinkedHashSet<String>();

  _TrackEntry({
    required this.message,
    required this.ageAtReceipt,
    required this.monotonicReceivedAt,
  });
}
