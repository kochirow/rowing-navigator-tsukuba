// =====================================================
// 練習ログ(セッション記録)の設定値
// =====================================================

/// スプリットの距離単位 [m]
const splitDistanceMeters = 500.0;

/// 距離の積算に含める最低速度 [m/s]
/// 停止中のGPSノイズによる距離の水増しを防ぐ。
const distanceAccumulationMinSpeed = 0.5;

// ---------------- 自動ピース検出 ----------------
// 速度プロファイルから「漕いでいた区間」を自動で切り出す。

/// ピースとみなす最低継続時間 [秒]
const pieceMinDurationSec = 30;

/// この秒数以下のペース低下は同一ピースとして連結する。
/// 発艇・レート調整や一時的なGNSSの揺れで、1本のピースを分断しない。
const pieceMaxGapSec = 15;

/// ピース判定に使う艇速の平滑窓。艇速は1ストローク内でも変動するため、
/// 単発の1Hz値ではなくこの窓の平均で判定する。
const pieceSpeedSmoothingWindowSec = 15;

/// 短い加速ノイズをピースにしないための最小距離 [m]。
const pieceMinDistanceMeters = 75.0;

/// 1Hz警告観測と状態遷移を端末内に保持する上限。
///
/// 通常は航行点上限(10時間)より十分大きく、複数警告が長時間重なった場合も
/// メモリを無制限に増やさない。
const maxSessionAlertDiagnosticEvents = 100000;

/// GPS棄却・ライフサイクル・画面方向などのイベント上限。
const maxSessionDiagnosticEvents = 20000;

/// events.jsonl / alerts.jsonl のイベント名・詳細フィールドの意味を識別する版。
/// 既存イベントは残したまま、因果追跡用のseq・elapsedMsを追加する。
const diagnosticEventSchemaVersion = 4;

/// 診断イベントの意味と、ログから検証する仮説のカタログ版。
const diagnosticCatalogVersion = 3;

/// ZIPに同梱する、AIがイベントを解釈するための最小限のデータ辞書。
/// ログだけを別のAIへ渡しても、何を観測し、何が未観測なのかを判断できるようにする。
const diagnosticEventCatalog = <String, dynamic>{
  'catalogVersion': diagnosticCatalogVersion,
  'ordering': {
    'seq': 'alerts.jsonl と events.jsonl を横断する発生順。欠落検出にも使う。',
    't': '端末の壁時計時刻。',
    'elapsedMs': 'セッション開始からの経過時間。端末時計の変更の影響を受けにくい。',
    'track.csv.elapsed_ms': '航跡点のセッション開始からの経過時間。イベントとの位置合わせに使う。',
  },
  'hypotheses': [
    {
      'id': 'H1_AUDIO_APP_COMPETITION',
      'question': 'Buddycom等の他アプリ音声セッションが警告音を抑制・経路変更したか。',
      'requiredEvidence': [
        'audio_context_applied',
        'audio_route_snapshot',
        'audio_playback_started',
        'audio_playback_stalled',
        'app_lifecycle_changed',
      ],
      'interpretation':
          '再生開始後にroute/session変化またはstalledがあれば競合仮説を支持する。開始・進行が正常でも聞こえない場合は、端末外の聴覚事象として扱う。',
    },
    {
      'id': 'H2_FORCED_TERMINATION',
      'question': 'アプリ強制終了、OS中断、クラッシュ、電源断の直前に何が起きていたか。',
      'requiredEvidence': [
        'diagnostic_heartbeat',
        'app_lifecycle_changed',
        'navigation_stopping',
        'navigation_widget_disposed',
        'session_recovery_detected',
      ],
      'interpretation':
          '正常終了イベントがなく、次回起動で前回checkpointが未完了なら異常終了。最後のheartbeatでGPS・音声・処理・共有状態を確認する。',
    },
    {
      'id': 'H3_WARNING_TIMING_AND_POSITION',
      'question': '警告頻度と警告位置が適切で、過剰警告・警告漏れ・位置ずれがないか。',
      'requiredEvidence': [
        'alerts.jsonl',
        'track.csv',
        'warning_presentation_requested',
        'audio_directive_changed',
        'gps_dead_reckoning_prediction',
        'diagnostic_heartbeat',
      ],
      'interpretation':
          'alert episodeをalertIdでまとめ、track.csvの自艇航跡・距離・actionDeadline・currentOverlapと重ねて評価する。',
    },
    {
      'id': 'H4_BATTERY_AND_LOAD',
      'question': '電池消費や処理負荷をどの機能・システムが増やしたか。',
      'requiredEvidence': [
        'battery_level_changed',
        'position_processing_slow',
        'position_processing_sample',
        'position_processing_gap',
        'diagnostic_heartbeat',
        'audio_route_snapshot',
      ],
      'interpretation':
          'battery値だけでは原因を特定できない。処理時間、GPS品質、音声復旧、位置共有、ライフサイクル、警告頻度を同じelapsedMsで相関させる。',
    },
    {
      'id': 'H5_OTHER_BOAT_COLLISION_AUDIO',
      'question': '他艇衝突警告が、検知・優先順位・提示・音声再生の各段階で適切だったか。',
      'requiredEvidence': [
        'alerts.jsonl category=other_boat',
        'warning_presentation_requested',
        'audio_playback_started',
        'audio_playback_failed',
        'audio_directive_changed',
      ],
      'interpretation': '検知なし、visualOnly、別警告による優先順位変更、再生失敗、再生成功後の停止を分けて判定する。',
    },
    {
      'id': 'H7_IMU_FUSION_AND_STROKE_MOTION',
      'question': '固定端末の加速度・ジャイロ融合が艇速・距離・GPS短時間欠測を改善したか。',
      'requiredEvidence': [
        'stroke_motion_analyzed',
        'imu_fusion_health',
        'imu_sensor_error',
        'track.csv rawGnssSpeedMetersPerSecond/imuConfidence',
        'gps_dead_reckoning_prediction imuAssisted',
      ],
      'interpretation':
          'GNSS艇速との差、1漕距離、キャッチ減速、終盤加速、艇速保持、信頼度を同じelapsedMsで比較する。IMU不能時はGNSS単独へ縮退していることも確認する。',
    },
    {
      'id': 'H6_LOGGING_COMPLETENESS',
      'question': 'ログ自体が欠落して、誤って「起きなかった」と判断していないか。',
      'requiredEvidence': [
        'seq',
        'diagnostic_heartbeat',
        'session_summary',
        'diagnosticEventDroppedCount',
      ],
      'interpretation': 'seqの飛び、heartbeatの空白、checkpointと最終イベントの差、上限超過を確認する。',
    },
  ],
  'eventTypes': {
    'warning_presentation_requested': 'SafetyOrchestratorが選んだ警告をUI/音声層へ渡した瞬間。',
    'warning_presentation_cleared': '前回提示していた警告を画面/音声層から解除した瞬間。',
    'audio_directive_changed': '安全判定の音声対象・モードが前回から変わった瞬間。',
    'audio_play_requested': 'AudioPlayerへ再生要求を出した瞬間。',
    'audio_playback_started':
        'AudioPlayerのresume完了とplaying状態をアプリが確認した瞬間。聴感上の成功を意味しない。',
    'audio_route_snapshot': 'OSが報告する音声経路・他音声再生状態のスナップショット。',
    'position_processing_sample': 'GPS受信から警告評価・記録・位置共有までの処理時間内訳。',
    'gps_dead_reckoning_prediction':
        'GPS入力が短時間途絶した間、直前の速度・方位から不確実性を増やしつつ自艇位置と警告を予測した。航跡・位置共有には使用しない。',
    'gps_dead_reckoning_failed': '任意機能である短時間推測航法の計算または警告評価が失敗した。通常のGPS監視は継続する。',
    'stroke_motion_analyzed':
        '直近の完全な1ストロークから、融合艇速・1漕距離・キャッチ減速・終盤加速・リカバリー艇速保持を算出した。実験指標であり技術評価を断定しない。',
    'imu_fusion_health': '加速度・ジャイロのサンプル充足と融合信頼度を10秒ごとに記録する。',
    'imu_sensor_error': '加速度またはジャイロの購読失敗。GNSS単独経路へ縮退する。',
    'diagnostic_heartbeat': '定期的な生存確認と各サブシステムの状態スナップショット。',
    'safety_timer_stalled': '1秒安全監視タイマー自身の実行間隔が上限を超えた。GPS入力途絶や評価停止とは別に記録する。',
    'safety_evaluation_stalled': 'GPS入力は新しいが、衝突評価の正常完了時刻が上限より古い。',
    'session_summary': 'セッション終了時の件数・欠落数・最終状態の集計。',
    'session_recovery_detected': '前回の未完了checkpointを次回セッション開始時に検出した記録。',
  },
};
