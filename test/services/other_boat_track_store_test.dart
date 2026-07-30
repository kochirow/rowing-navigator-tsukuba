import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/remote_boat_message.dart';
import 'package:rowing_navigator/services/other_boat_track_store.dart';
import 'package:rowing_navigator/config/protocol_config.dart';

void main() {
  final baseTime = DateTime.utc(2026, 7, 15, 12);

  Map<Object?, Object?> messageJson({
    String boatId = 'boat-a',
    String displayName = '後藤',
    String sessionId = 'session-a',
    int sequence = 1,
    DateTime? serverUpdatedAt,
    DateTime? observedAt,
  }) {
    final serverTime = serverUpdatedAt ?? baseTime;
    return {
      'protocolVersion': 1,
      'appVersion': currentPositionAppVersion,
      'profileVersion': currentHazardProfileVersion,
      'boatId': boatId,
      'displayName': displayName,
      'sessionId': sessionId,
      'sequence': sequence,
      'serverUpdatedAt': serverTime.millisecondsSinceEpoch,
      'observedAt': (observedAt ?? serverTime).millisecondsSinceEpoch,
      'lat': 36.075,
      'lng': 140.118,
      'accuracy': 4.0,
      'course': 180.0,
      'courseAccuracy': 5.0,
      'speed': 4.2,
      'speedAccuracy': 0.3,
      'battery': 80,
      'boatType': 'r_1x',
      'turnRate': 0.0,
      'navigationState': 'moving',
      'capabilities': ['course', 'accuracy'],
    };
  }

  group('RemoteBoatMessage', () {
    test('正常メッセージを不変モデルに変換できる', () {
      final result = RemoteBoatMessage.tryParse(
        messageJson(),
        estimatedServerNow: baseTime,
      );

      expect(result.isValid, isTrue);
      expect(result.failure, isNull);
      expect(result.message!.boatId, 'boat-a');
      expect(result.message!.displayName, '後藤');
      expect(result.message!.serverUpdatedAt, baseTime);
      expect(result.message!.capabilities, ['course', 'accuracy']);
      expect(result.message!.toJson()['sequence'], 1);
      expect(
        () => result.message!.capabilities.add('mutate'),
        throwsUnsupportedError,
      );
    });

    test('NaN、範囲外、巨大sequenceを拒否する', () {
      final invalidCases = <(String, Object?, RemoteBoatMessageValidationCode)>[
        ('lat', double.nan, RemoteBoatMessageValidationCode.nonFinite),
        ('lng', 181, RemoteBoatMessageValidationCode.outOfRange),
        ('accuracy', 0, RemoteBoatMessageValidationCode.outOfRange),
        ('course', 360, RemoteBoatMessageValidationCode.outOfRange),
        ('speed', double.infinity, RemoteBoatMessageValidationCode.nonFinite),
        (
          'sequence',
          RemoteBoatMessage.maxSafeInteger + 1,
          RemoteBoatMessageValidationCode.outOfRange,
        ),
      ];

      for (final invalid in invalidCases) {
        final json = messageJson()..[invalid.$1] = invalid.$2;
        final result = RemoteBoatMessage.tryParse(
          json,
          estimatedServerNow: baseTime,
        );
        expect(result.isValid, isFalse, reason: invalid.$1);
        expect(result.failure!.field, invalid.$1);
        expect(result.failure!.code, invalid.$3);
      }
    });

    test('server時刻の未来値は拒否し、observedAtはRules同等の5秒差まで許容する', () {
      final futureServer = RemoteBoatMessage.tryParse(
        messageJson(
          serverUpdatedAt: baseTime.add(const Duration(milliseconds: 1)),
        ),
        estimatedServerNow: baseTime,
      );
      expect(futureServer.isValid, isFalse);
      expect(futureServer.failure!.field, 'serverUpdatedAt');

      final toleratedObservedAt = RemoteBoatMessage.tryParse(
        messageJson(
          observedAt: baseTime.add(const Duration(seconds: 5)),
        ),
        estimatedServerNow: baseTime,
      );
      expect(toleratedObservedAt.isValid, isTrue);

      final excessiveObservedAt = RemoteBoatMessage.tryParse(
        messageJson(
          observedAt: baseTime.add(const Duration(milliseconds: 5001)),
        ),
        estimatedServerNow: baseTime,
      );
      expect(excessiveObservedAt.isValid, isFalse);
      expect(excessiveObservedAt.failure!.field, 'observedAt');
    });

    test('同一sessionのobservedAtが時計補正で戻ってもsequence順で受理する', () {
      var now = baseTime;
      final store = OtherBoatTrackStore(estimatedServerNow: () => now);
      expect(store.ingestJson(messageJson(sequence: 1)).accepted, isTrue);
      now = baseTime.add(const Duration(seconds: 2));
      final result = store.ingestJson(messageJson(
        sequence: 2,
        serverUpdatedAt: now,
        observedAt: baseTime.subtract(const Duration(minutes: 1)),
      ));
      expect(result.accepted, isTrue);
      expect(store.snapshot('boat-a')!.message.sequence, 2);
    });

    test('未知protocolは受理し、範囲外値と過長識別子は拒否する', () {
      final future = RemoteBoatMessage.tryParse(
        messageJson()..['protocolVersion'] = 2,
        estimatedServerNow: baseTime,
      );
      expect(future.isValid, isTrue);
      expect(future.message!.protocolVersion, 2);

      final outOfRange = RemoteBoatMessage.tryParse(
        messageJson()..['protocolVersion'] = 0,
        estimatedServerNow: baseTime,
      );
      expect(
          outOfRange.failure!.code, RemoteBoatMessageValidationCode.outOfRange);

      final tooLong = RemoteBoatMessage.tryParse(
        messageJson()..['boatId'] = List.filled(129, 'x').join(),
        estimatedServerNow: baseTime,
      );
      expect(
        tooLong.failure!.code,
        RemoteBoatMessageValidationCode.stringTooLong,
      );

      final tooLongName = RemoteBoatMessage.tryParse(
        messageJson(displayName: List.filled(21, '名').join()),
        estimatedServerNow: baseTime,
      );
      expect(tooLongName.failure!.field, 'displayName');
      expect(
        tooLongName.failure!.code,
        RemoteBoatMessageValidationCode.stringTooLong,
      );
    });

    test('appVersionが違っても受理する(互換の判断はprotocolVersionだけ)', () {
      // 版が違う艇を破棄すると、配信のたびに混在期間中のどちらかの群が
      // 互いの地図から消え、衝突警告の対象から外れる(原則1: 機能を止めない)。
      final newer = RemoteBoatMessage.tryParse(
        messageJson()..['appVersion'] = '1.0.1',
        estimatedServerNow: baseTime,
      );
      expect(newer.isValid, isTrue);
      expect(newer.message!.appVersion, '1.0.1');

      final older = RemoteBoatMessage.tryParse(
        messageJson()..['appVersion'] = '0.9.0+1',
        estimatedServerNow: baseTime,
      );
      expect(older.isValid, isTrue);

      // 文字列としての妥当性だけは残す。
      final tooLong = RemoteBoatMessage.tryParse(
        messageJson()..['appVersion'] = List.filled(65, 'x').join(),
        estimatedServerNow: baseTime,
      );
      expect(tooLong.isValid, isFalse);
      expect(tooLong.failure!.field, 'appVersion');
      expect(
        tooLong.failure!.code,
        RemoteBoatMessageValidationCode.stringTooLong,
      );
    });

    test('未知protocolを既定で受理し、明示時だけ厳格判定できる', () {
      final supported = RemoteBoatMessage.tryParse(
        messageJson()..['protocolVersion'] = currentPositionProtocolVersion,
        estimatedServerNow: baseTime,
      );
      expect(supported.isValid, isTrue);

      final future = RemoteBoatMessage.tryParse(
        messageJson()..['protocolVersion'] = currentPositionProtocolVersion + 1,
        estimatedServerNow: baseTime,
      );
      expect(future.isValid, isTrue);

      final strict = RemoteBoatMessage.tryParse(
        messageJson()..['protocolVersion'] = currentPositionProtocolVersion + 1,
        estimatedServerNow: baseTime,
        supportedProtocolVersions: supportedPositionProtocolVersions,
      );
      expect(strict.isValid, isFalse);
      expect(strict.failure!.field, 'protocolVersion');
      expect(
        strict.failure!.code,
        RemoteBoatMessageValidationCode.unsupportedProtocolVersion,
      );
    });

    test('異なるprofile versionと将来の艇種名も位置ごと受理する', () {
      final result = RemoteBoatMessage.tryParse(
        messageJson()
          ..['profileVersion'] = 'sakuragawa-v99'
          ..['boatType'] = 'future_boat',
        estimatedServerNow: baseTime,
      );
      expect(result.isValid, isTrue);
      expect(result.message!.profileVersion, 'sakuragawa-v99');
      expect(result.message!.boatType, 'future_boat');

      final strictProfile = RemoteBoatMessage.tryParse(
        messageJson()..['profileVersion'] = 'sakuragawa-v99',
        estimatedServerNow: baseTime,
        supportedProfileVersions: supportedHazardProfileVersions,
      );
      expect(strictProfile.failure!.code,
          RemoteBoatMessageValidationCode.unsupportedProfileVersion);
    });
  });

  group('OtherBoatTrackStore ordering', () {
    test('同sessionのsequence重複と逆転を拒否する', () {
      final store = OtherBoatTrackStore(estimatedServerNow: () => baseTime);

      expect(store.ingestJson(messageJson(sequence: 5)).accepted, isTrue);
      expect(
        store.ingestJson(messageJson(sequence: 5)).status,
        OtherBoatTrackUpdateStatus.rejectedDuplicate,
      );
      expect(
        store.ingestJson(messageJson(sequence: 4)).status,
        OtherBoatTrackUpdateStatus.rejectedOutOfOrder,
      );
      expect(store.snapshot('boat-a')!.message.sequence, 5);
    });

    test('新sessionは旧sessionを閉じ、旧sessionの遅延到着を拒否する', () {
      var now = baseTime;
      var monotonic = Duration.zero;
      final store = OtherBoatTrackStore(
        estimatedServerNow: () => now,
        monotonicNow: () => monotonic,
      );
      expect(store.ingestJson(messageJson(sequence: 7)).accepted, isTrue);

      now = baseTime.add(const Duration(seconds: 1));
      monotonic = const Duration(seconds: 1);
      final replacement = store.ingestJson(
        messageJson(
          sessionId: 'session-b',
          sequence: 0,
          serverUpdatedAt: now,
        ),
      );
      expect(replacement.status, OtherBoatTrackUpdateStatus.replacedSession);
      expect(store.snapshot('boat-a')!.message.sessionId, 'session-b');

      expect(
        store
            .ingestJson(messageJson(sessionId: 'session-a', sequence: 8))
            .status,
        OtherBoatTrackUpdateStatus.rejectedClosedSession,
      );
      expect(store.snapshot('boat-a')!.message.sessionId, 'session-b');
    });

    test('別sessionでもserver時刻が古いメッセージは交代しない', () {
      var now = baseTime.add(const Duration(seconds: 2));
      final store = OtherBoatTrackStore(estimatedServerNow: () => now);
      expect(
        store
            .ingestJson(messageJson(
              serverUpdatedAt: baseTime.add(const Duration(seconds: 1)),
            ))
            .accepted,
        isTrue,
      );

      final stale = store.ingestJson(
        messageJson(
          sessionId: 'delayed-session',
          serverUpdatedAt: baseTime,
        ),
      );
      expect(stale.status, OtherBoatTrackUpdateStatus.rejectedStaleTimestamp);
      expect(store.snapshot('boat-a')!.message.sessionId, 'session-a');
    });

    test('不正な別艇メッセージは既存艇のtrackを壊さない', () {
      final store = OtherBoatTrackStore(estimatedServerNow: () => baseTime);
      expect(store.ingestJson(messageJson()).accepted, isTrue);

      final invalid = messageJson(boatId: 'boat-b')..['lat'] = double.nan;
      final result = store.ingestJson(invalid);

      expect(result.status, OtherBoatTrackUpdateStatus.rejectedInvalidMessage);
      expect(result.boatId, 'boat-b');
      expect(store.length, 1);
      expect(store.snapshot('boat-a')!.message.sequence, 1);
      expect(store.snapshot('boat-b'), isNull);
    });
  });

  group('OtherBoatTrackStore freshness', () {
    test('3/6/30秒境界でfreshnessが決定的に遷移する', () {
      var monotonic = Duration.zero;
      final store = OtherBoatTrackStore(
        estimatedServerNow: () => baseTime,
        monotonicNow: () => monotonic,
      );
      expect(store.ingestJson(messageJson()).accepted, isTrue);

      monotonic = const Duration(milliseconds: 2999);
      expect(
        store.snapshot('boat-a')!.freshness,
        OtherBoatTrackFreshness.fresh,
      );
      monotonic = const Duration(seconds: 3);
      expect(
        store.snapshot('boat-a')!.freshness,
        OtherBoatTrackFreshness.degraded,
      );
      monotonic = const Duration(seconds: 6);
      expect(
        store.snapshot('boat-a')!.freshness,
        OtherBoatTrackFreshness.lostForPrediction,
      );
      monotonic = OtherBoatTrackStore.lostForPredictionThrough;
      expect(
        store.snapshot('boat-a')!.freshness,
        OtherBoatTrackFreshness.lostForPrediction,
      );
      monotonic = OtherBoatTrackStore.lostForPredictionThrough +
          const Duration(milliseconds: 1);
      expect(
        store.snapshot('boat-a')!.freshness,
        OtherBoatTrackFreshness.expired,
      );
    });

    test('server上で既に経過したageにmonotonic経過を足す', () {
      var monotonic = Duration.zero;
      final store = OtherBoatTrackStore(
        estimatedServerNow: () => baseTime,
        monotonicNow: () => monotonic,
      );
      expect(
        store
            .ingestJson(messageJson(
              serverUpdatedAt: baseTime.subtract(const Duration(seconds: 2)),
            ))
            .accepted,
        isTrue,
      );
      expect(store.snapshot('boat-a')!.age, const Duration(seconds: 2));

      monotonic = const Duration(seconds: 1);
      expect(
        store.snapshot('boat-a')!.freshness,
        OtherBoatTrackFreshness.degraded,
      );
    });

    test('active警告艇は劣化後もholdし、expired pruneで消えない', () {
      var monotonic = Duration.zero;
      final active = <String>{'boat-a'};
      final store = OtherBoatTrackStore(
        estimatedServerNow: () => baseTime,
        monotonicNow: () => monotonic,
        isActiveWarningTarget: active.contains,
      );
      expect(store.ingestJson(messageJson()).accepted, isTrue);

      monotonic = const Duration(seconds: 3);
      expect(store.snapshot('boat-a')!.shouldHoldActiveWarning, isTrue);
      monotonic = OtherBoatTrackStore.lostForPredictionThrough +
          const Duration(seconds: 1);
      final expired = store.snapshot('boat-a')!;
      expect(expired.freshness, OtherBoatTrackFreshness.expired);
      expect(expired.mayPredict, isFalse);
      expect(expired.shouldRemainVisible, isTrue);
      expect(store.pruneExpiredInactive(), 0);
      expect(store.snapshot('boat-a'), isNotNull);
    });
  });

  group('OtherBoatTrackStore capacity', () {
    test('新鮮な100艇を保持し、101艇目を拒否する', () {
      final store = OtherBoatTrackStore(estimatedServerNow: () => baseTime);
      for (var index = 0; index < 100; index++) {
        expect(
          store.ingestJson(messageJson(boatId: 'boat-$index')).accepted,
          isTrue,
        );
      }

      final overflow = store.ingestJson(messageJson(boatId: 'boat-100'));
      expect(overflow.status, OtherBoatTrackUpdateStatus.rejectedCapacity);
      expect(store.length, 100);
    });

    test('上限時はexpiredかつ非activeの最古trackを入れ替える', () {
      var monotonic = Duration.zero;
      final store = OtherBoatTrackStore(
        maxTracks: 2,
        estimatedServerNow: () => baseTime,
        monotonicNow: () => monotonic,
      );
      expect(store.ingestJson(messageJson(boatId: 'old-a')).accepted, isTrue);
      monotonic = const Duration(seconds: 1);
      expect(store.ingestJson(messageJson(boatId: 'old-b')).accepted, isTrue);

      monotonic = OtherBoatTrackStore.lostForPredictionThrough +
          const Duration(seconds: 2);
      expect(store.ingestJson(messageJson(boatId: 'new-c')).accepted, isTrue);
      expect(store.length, 2);
      expect(store.snapshot('old-a'), isNull);
      expect(store.snapshot('old-b'), isNotNull);
      expect(store.snapshot('new-c'), isNotNull);
    });
  });
}
