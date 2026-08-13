/// Firebase無料枠の回帰検証に使う、運用前提に固定した純粋計算。
///
/// 2026-07-21時点の公式Spark枠:
/// - RTDB download: 10 GB/月、storage: 1 GB、同時接続: 100
/// - Firestore: read 50,000/日、write/delete各20,000/日
///
/// RTDBの実課金量にはprotocol・WebSocket・暗号化overheadも含まれるため、
/// アプリpayload本体は無料download枠の40%以下を合格条件にする。
class FirebaseUsageBudget {
  static const boats = 12;
  // 週6日×平均4.345週=26.07回を、保証側へ27回に切り上げる。
  static const practicesPerMonth = 27;
  static const practiceSeconds = 2 * 60 * 60;
  static const maxCompactPositionBytes = 250;

  static const rtdbSparkDownloadBytes = 10 * 1000 * 1000 * 1000;
  static const rtdbApplicationPayloadBudgetBytes = 4 * 1000 * 1000 * 1000;
  static const rtdbSparkConcurrentConnections = 100;

  static const firestoreDailyReads = 50000;
  static const firestoreDailyWrites = 20000;
  static const maxTemporaryObstaclesPerSync = 100;
  static const bootstrapReadsPerDevice = 4;

  static int monthlyPositionDownloadBytes({required int intervalSeconds}) {
    if (intervalSeconds <= 0) {
      throw ArgumentError.value(intervalSeconds, 'intervalSeconds');
    }
    final sendsPerBoatPerPractice = (practiceSeconds / intervalSeconds).ceil();
    // 各艇の更新を、同じチームの全12接続が受信する最悪fan-out。
    return sendsPerBoatPerPractice *
        boats *
        boats *
        practicesPerMonth *
        maxCompactPositionBytes;
  }

  static int positionDownloadBytesPerPractice({
    required int intervalSeconds,
  }) =>
      monthlyPositionDownloadBytes(intervalSeconds: intervalSeconds) ~/
      practicesPerMonth;

  /// 1ストロークの艇速波形1件ぶんの上限バイト数。
  ///
  /// base64波形64文字 + 10個ほどの整数フィールド + キー名で実測160前後。
  /// RTDBのフレーム overhead を見込んで保証側へ切り上げる。
  static const maxStrokeTraceBytes = 300;

  /// 監視端末が同時に開ける艇速変化グラフの数。
  ///
  /// シートは1枚しか開けないので実際は1。監視端末が2台ある・切替を
  /// 繰り返す運用を見込んで4倍で見積もる。
  static const concurrentWatchedStrokeTraces = 4;

  /// 艇速波形のRTDB download [バイト/月]。
  ///
  /// **位置と決定的に違うのは fan-out が無いこと。** 位置は全12艇が
  /// 全12艇ぶんを受け取るので 144倍で効くが、波形は監視端末が開いた
  /// 艇のぶんしか転送されない。ここへ 12x12 が現れたら設計を誤っている。
  static int monthlyStrokeTraceDownloadBytes({
    required int strokeIntervalSeconds,
    int watchedBoats = concurrentWatchedStrokeTraces,
  }) {
    if (strokeIntervalSeconds <= 0) {
      throw ArgumentError.value(strokeIntervalSeconds, 'strokeIntervalSeconds');
    }
    if (watchedBoats < 0) {
      throw ArgumentError.value(watchedBoats, 'watchedBoats');
    }
    final strokesPerPractice = (practiceSeconds / strokeIntervalSeconds).ceil();
    return strokesPerPractice *
        watchedBoats *
        practicesPerMonth *
        maxStrokeTraceBytes;
  }

  static int firestoreReadsPerPracticeDay({
    int temporaryObstacleCount = maxTemporaryObstaclesPerSync,
  }) {
    if (temporaryObstacleCount < 0 ||
        temporaryObstacleCount > maxTemporaryObstaclesPerSync) {
      throw ArgumentError.value(
        temporaryObstacleCount,
        'temporaryObstacleCount',
      );
    }
    return boats * (bootstrapReadsPerDevice + temporaryObstacleCount);
  }

  /// 共有校正は全障害物を1文書にまとめ、監視・航行中だけ1 listenerで読む。
  ///
  /// 変更なしの時間にはreadが増えない。ここでは1端末につき初回1回、
  /// 公開revisionごとに1回、ネットワーク再接続ごとに1回として上限化する。
  /// さらにSecurity Rulesのteam membership確認に伴う依存readと、
  /// 公開transaction自身のdocument/member readも保守的に加算する。
  static int sharedCalibrationReadsPerPracticeDay({
    int devices = boats,
    int publishedRevisions = 4,
    // 2時間で端末ごと20回（平均6分ごと）再接続する厳しい条件。
    int reconnectsPerDevice = 20,
    int securityRuleDependentReadsPerRequest = 1,
  }) {
    if (devices < 0 ||
        publishedRevisions < 0 ||
        reconnectsPerDevice < 0 ||
        securityRuleDependentReadsPerRequest < 0) {
      throw ArgumentError(
        'usage inputs must be >= 0',
      );
    }
    final listenerEventsPerDevice =
        1 + publishedRevisions + reconnectsPerDevice;
    final billedReadsPerRequest = 1 + securityRuleDependentReadsPerRequest;
    final listenerReads =
        devices * listenerEventsPerDevice * billedReadsPerRequest;
    final publishTransactionReads = publishedRevisions * billedReadsPerRequest;
    return listenerReads + publishTransactionReads;
  }
}
