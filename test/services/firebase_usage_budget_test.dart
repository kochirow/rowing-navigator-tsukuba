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
