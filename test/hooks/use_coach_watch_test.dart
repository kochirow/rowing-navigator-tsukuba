import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/coach_config.dart';
import 'package:rowing_navigator/hooks/use_coach_watch.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  final now = DateTime.utc(2026, 7, 22, 12);

  Boat boat({
    required DateTime observedAt,
    DateTime? serverUpdatedAt,
  }) {
    return Boat(
      boatId: 'boat-a',
      boatType: BoatType.r_1x,
      lat: 36.075,
      lng: 140.118,
      heading: 180,
      speed: 0,
      timestamp: observedAt,
      serverUpdatedAt: serverUpdatedAt,
    );
  }

  test('監視鮮度は再描画時刻ではなくserverUpdatedAtを優先する', () {
    final updatedAt = now.subtract(const Duration(seconds: 20));
    final target = boat(
      observedAt: now.subtract(const Duration(seconds: 5)),
      serverUpdatedAt: updatedAt,
    );

    expect(coachFreshnessTimestamp(target, now), updatedAt);
    expect(coachBoatUpdateAge(target, now), const Duration(seconds: 20));
  });

  test('serverUpdatedAtがない旧データは観測時刻を使う', () {
    final observedAt = now.subtract(const Duration(seconds: 12));
    final target = boat(observedAt: observedAt);

    expect(coachFreshnessTimestamp(target, now), observedAt);
    expect(coachBoatUpdateAge(target, now), const Duration(seconds: 12));
  });

  test('未来時刻は現在時刻へ丸めて負の経過時間を作らない', () {
    final target = boat(
      observedAt: now,
      serverUpdatedAt: now.add(const Duration(minutes: 1)),
    );

    expect(coachFreshnessTimestamp(target, now), now);
    expect(coachBoatUpdateAge(target, now), Duration.zero);
  });
  group('更新途絶のしきい値', () {
    // 45秒では停止中送信10秒 + 画面OFF + 通信ジッタで日常的に成立し、
    // 「細かいエラーを大きく伝えすぎ」の原因になっていた。
    test('45秒では更新途絶にしない', () {
      expect(coachBoatUpdateIsLost(const Duration(seconds: 45)), isFalse);
      expect(coachBoatUpdateIsLost(const Duration(seconds: 89)), isFalse);
    });

    test('しきい値ちょうどはまだ途絶にしない', () {
      expect(coachBoatUpdateIsLost(const Duration(seconds: lostAlertSec)),
          isFalse);
    });

    test('90秒を超えたら更新途絶にする', () {
      expect(
        coachBoatUpdateIsLost(const Duration(seconds: lostAlertSec + 1)),
        isTrue,
      );
      expect(coachBoatUpdateIsLost(const Duration(minutes: 5)), isTrue);
    });

    test('停止中送信間隔の何倍まで許容しているかを固定する', () {
      // 前提が変わったら DESIGN_PRINCIPLES 3.4 と合わせて見直す。
      expect(lostAlertSec, 90);
    });
  });

  group('監視モードの音', () {
    test('既定では鳴らす異常が1つも無い(監視は無音)', () {
      // 監視者は画面を見られる位置にいる。音はトランシーバーと干渉し、
      // 近隣にも響く(DESIGN_PRINCIPLES 原則2 = 使い方は使い手が決める)。
      expect(coachAudibleAnomalyKindNames, isEmpty);
      for (final kind in BoatAnomalyKind.values) {
        expect(isAudibleCoachAnomalyKind(kind), isFalse);
      }
    });

    test('設定の名前は実在する種類でなければならない', () {
      // 設定を String で持っているので、綴り誤りをここで検出する。
      final validNames =
          BoatAnomalyKind.values.map((kind) => kind.name).toSet();
      expect(coachAudibleAnomalyKindNames.difference(validNames), isEmpty);
    });
  });

  group('BoatAnomaly', () {
    BoatAnomaly anomaly({
      required BoatAnomalyKind kind,
      required DateTime detectedAt,
      String boatId = 'boat-1',
      String displayName = '第1エイト',
    }) =>
        BoatAnomaly(
          boatId: boatId,
          displayName: displayName,
          kind: kind,
          detectedAt: detectedAt,
        );

    test('艇と種類の組で同一性を持つ(再通知の抑制に使う)', () {
      final stopped = anomaly(
        kind: BoatAnomalyKind.stopped,
        detectedAt: now,
      );
      final sameAgain = anomaly(
        kind: BoatAnomalyKind.stopped,
        detectedAt: now.subtract(const Duration(minutes: 3)),
      );
      final lost = anomaly(kind: BoatAnomalyKind.lost, detectedAt: now);

      expect(stopped.key, sameAgain.key);
      expect(stopped.key, isNot(lost.key));
    });

    test('初検知からの経過を「◯分前から」で示す', () {
      // 「いつから停止しているか」が分からないと、様子見か即対応かを
      // コーチが判断できない。
      expect(
        anomaly(
          kind: BoatAnomalyKind.stopped,
          detectedAt: now.subtract(const Duration(minutes: 3)),
        ).continuedLabel(now),
        '3分前から',
      );
      expect(
        anomaly(
          kind: BoatAnomalyKind.lost,
          detectedAt: now.subtract(const Duration(seconds: 45)),
        ).continuedLabel(now),
        '45秒前から',
      );
    });

    test('検知直後は継続時間を出さない', () {
      expect(
        anomaly(kind: BoatAnomalyKind.lost, detectedAt: now)
            .continuedLabel(now),
        isNull,
      );
    });

    test('コーチへ見せる名前は内部IDではなく表示名', () {
      final target = anomaly(
        kind: BoatAnomalyKind.lost,
        detectedAt: now,
        boatId: 'c2f1a9e0-2b',
        displayName: '第2クォド',
      );
      expect(target.displayName, '第2クォド');
      expect(target.label, '更新途絶');
    });
  });
}
