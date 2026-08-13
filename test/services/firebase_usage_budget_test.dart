import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/services/firebase_usage_budget.dart';

void main() {
  group('Firebase Spark使用量ガード', () {
    test('最悪送信間隔でも位置payload本体をRTDB無料枠の40%以下にする', () {
      final monthlyBytes = FirebaseUsageBudget.monthlyPositionDownloadBytes(
        intervalSeconds: sendIntervalElevatedRiskSec,
      );

      expect(sendIntervalElevatedRiskSec, greaterThanOrEqualTo(2));
      expect(
        monthlyBytes,
        lessThanOrEqualTo(
          FirebaseUsageBudget.rtdbApplicationPayloadBudgetBytes,
        ),
      );
      expect(
        monthlyBytes,
        lessThan(FirebaseUsageBudget.rtdbSparkDownloadBytes),
      );
    });

    test('12台2時間の位置payload本体は130MB以下', () {
      expect(
        FirebaseUsageBudget.positionDownloadBytesPerPractice(
          intervalSeconds: sendIntervalElevatedRiskSec,
        ),
        lessThanOrEqualTo(130 * 1000 * 1000),
      );
    });

    test('艇速波形の共有は位置payloadの5%未満に収まる', () {
      // 25spm = 2.4秒に1ストローク。監視端末が常時4隻ぶん開いている想定。
      final traceBytes = FirebaseUsageBudget.monthlyStrokeTraceDownloadBytes(
        strokeIntervalSeconds: 2,
      );
      final positionBytes = FirebaseUsageBudget.monthlyPositionDownloadBytes(
        intervalSeconds: sendIntervalElevatedRiskSec,
      );
      expect(traceBytes, lessThan(positionBytes ~/ 20));
      expect(
        traceBytes + positionBytes,
        lessThanOrEqualTo(
          FirebaseUsageBudget.rtdbApplicationPayloadBudgetBytes,
        ),
      );
    });

    test('艇速波形にはfan-outが無い(監視が開いた艇のぶんだけ)', () {
      // 位置は全12艇が全12艇ぶんを受け取る。波形は開いた艇のぶんだけ。
      // 監視艇数に対して線形であることが、無料枠を守る根拠そのもの。
      final one = FirebaseUsageBudget.monthlyStrokeTraceDownloadBytes(
        strokeIntervalSeconds: 2,
        watchedBoats: 1,
      );
      final twelve = FirebaseUsageBudget.monthlyStrokeTraceDownloadBytes(
        strokeIntervalSeconds: 2,
        watchedBoats: 12,
      );
      expect(twelve, one * 12);
      // 万一12隻ぶん常時開いても無料枠の10%以内。
      expect(
          twelve, lessThan(FirebaseUsageBudget.rtdbSparkDownloadBytes ~/ 10));
    });

    test('同時接続と危険区域100件のFirestore読取に十分な余裕がある', () {
      expect(
        FirebaseUsageBudget.boats,
        lessThanOrEqualTo(
          FirebaseUsageBudget.rtdbSparkConcurrentConnections,
        ),
      );
      expect(
        FirebaseUsageBudget.firestoreReadsPerPracticeDay() +
            FirebaseUsageBudget.sharedCalibrationReadsPerPracticeDay(),
        lessThan(FirebaseUsageBudget.firestoreDailyReads ~/ 10),
      );
    });

    test('共有校正はRules依存read込みで12台・公開4回・各20再接続でも608 read', () {
      expect(
        FirebaseUsageBudget.sharedCalibrationReadsPerPracticeDay(),
        608,
      );
      expect(
        FirebaseUsageBudget.sharedCalibrationReadsPerPracticeDay(),
        lessThan(FirebaseUsageBudget.firestoreDailyReads ~/ 50),
      );
    });

    test('無効な試算入力を拒否する', () {
      expect(
        () => FirebaseUsageBudget.monthlyPositionDownloadBytes(
          intervalSeconds: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => FirebaseUsageBudget.firestoreReadsPerPracticeDay(
          temporaryObstacleCount: 101,
        ),
        throwsArgumentError,
      );
      expect(
        () => FirebaseUsageBudget.sharedCalibrationReadsPerPracticeDay(
          devices: -1,
        ),
        throwsArgumentError,
      );
    });
  });
}
