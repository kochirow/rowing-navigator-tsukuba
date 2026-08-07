import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/protection_budget.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';

/// Stage 3 S3-04 / S3-05: 保護量を由来別に持ち、情報欠損で縮まないことを固定する。
///
/// 2026-08-06 実機ログの2つの問題に対応する。
/// 1. `pairGpsCenterDistanceGuardMeters` が上限2.5mで常に飽和し、
///    測位品質に関わらず定数だった(帯が情報を持っていなかった)。
/// 2. 他艇の速度・方位が取れないとき、その成分を0として扱っていた
///    (データ欠損を「動いていない」と読み替えていた。原則6違反)。
void main() {
  Boat boat({
    String boatId = 'b',
    double speed = 2.0,
    double heading = 0.0,
    double? accuracy = 5.0,
    Duration age = Duration.zero,
  }) =>
      Boat(
        boatId: boatId,
        boatType: BoatType.r_1x,
        lat: 36.067,
        lng: 140.2045,
        heading: heading,
        speed: speed,
        timestamp: DateTime.now().subtract(age),
        accuracy: accuracy,
      );

  group('ProtectionBudget の合成', () {
    test('独立成分は二乗和、上限成分は線形加算する', () {
      const budget = ProtectionBudget(
        gnssMeasurementMeters: 3,
        modelMismatchMeters: 4,
        remoteLatencyMeters: 2,
        speedUnknownMeters: 1,
      );
      // sqrt(3²+4²)=5 に、上限成分 2+1 を線形で足す。
      expect(budget.relativeTotalMeters, closeTo(8.0, 1e-9));
    });

    test('相対は通信遅延を含み、絶対は含まない', () {
      const budget = ProtectionBudget(
        gnssMeasurementMeters: 2,
        remoteLatencyMeters: 3,
      );
      expect(budget.relativeTotalMeters, closeTo(5.0, 1e-9));
      // 静的危険区域は自艇の位置だけで決まる。通信遅延は効かない。
      expect(budget.absoluteTotalMeters, closeTo(2.0, 1e-9));
    });

    test('成分を0にすると、その成分ぶんだけ合計が減る(分解可能性)', () {
      const full = ProtectionBudget(
        gnssMeasurementMeters: 2,
        remoteLatencyMeters: 3,
        speedUnknownMeters: 4,
      );
      final without = full.copyWith(speedUnknownMeters: 0);
      expect(
        full.relativeTotalMeters - without.relativeTotalMeters,
        closeTo(4.0, 1e-9),
      );
    });
  });

  group('他艇の保護量', () {
    final evaluator = CollisionRiskEvaluatorService();

    test('速度・方位が取れていれば従来と同じ値になる', () {
      final a = boat(boatId: 'a');
      final b = boat(boatId: 'b');
      final budget = evaluator.pairProtectionBudget(a, b);
      expect(budget.speedUnknownMeters, 0);
      expect(budget.headingUnknownMeters, 0);
      // 欠損ぶんが乗らないので、合計は測位＋通信遅延だけ。
      expect(
        budget.relativeTotalMeters,
        closeTo(
          budget.gnssMeasurementMeters + budget.remoteLatencyMeters,
          1e-9,
        ),
      );
    });

    test('相手の速度が不明なら領域が広がる(0m/s扱いにしない)', () {
      final a = boat(boatId: 'a');
      final unknown = boat(boatId: 'b', speed: double.nan, age: const Duration(seconds: 3));
      final known = boat(boatId: 'b', speed: 0.0, age: const Duration(seconds: 3));
      final unknownBudget = evaluator.pairProtectionBudget(a, unknown);
      final knownBudget = evaluator.pairProtectionBudget(a, known);
      expect(unknownBudget.speedUnknownMeters, greaterThan(0));
      expect(knownBudget.speedUnknownMeters, 0);
      expect(
        unknownBudget.relativeTotalMeters,
        greaterThan(knownBudget.relativeTotalMeters),
      );
    });

    test('速度不明の保護量は齢に対して単調に増え、上限で頭打ちになる', () {
      final a = boat(boatId: 'a');
      double guardAt(int seconds) => evaluator
          .pairProtectionBudget(
            a,
            boat(
              boatId: 'b',
              speed: double.nan,
              age: Duration(seconds: seconds),
            ),
          )
          .speedUnknownMeters;
      final g1 = guardAt(1);
      final g3 = guardAt(3);
      final g6 = guardAt(6);
      expect(g3, greaterThan(g1));
      expect(g6, greaterThanOrEqualTo(g3));
      // 川幅を超えて常時警告にならないよう上限がある(原則4)。
      expect(g6, lessThanOrEqualTo(maxUnknownSpeedGuardMeters));
    });

    test('相手が停止していると分かっているときは広がらない', () {
      final a = boat(boatId: 'a');
      final stopped = boat(boatId: 'b', speed: 0.0);
      expect(
        evaluator.pairProtectionBudget(a, stopped).speedUnknownMeters,
        0,
      );
    });

    test('方位が不明なら領域が広がる', () {
      final a = boat(boatId: 'a');
      final noHeading = boat(boatId: 'b', heading: double.nan);
      expect(
        evaluator.pairProtectionBudget(a, noHeading).headingUnknownMeters,
        unknownHeadingGuardMeters,
      );
    });

    test('remote age が増えると相対合計が単調に増える', () {
      final a = boat(boatId: 'a');
      double totalAt(int seconds) => evaluator
          .pairProtectionBudget(
            a,
            boat(boatId: 'b', age: Duration(seconds: seconds)),
          )
          .relativeTotalMeters;
      expect(totalAt(3), greaterThanOrEqualTo(totalAt(0)));
      expect(totalAt(6), greaterThanOrEqualTo(totalAt(3)));
    });
  });
}
