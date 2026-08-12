// =====================================================
// 練習ログ(セッション記録)の設定値
// =====================================================

// ---------------- 警告総量の予算 ----------------
// 出典: プロセス産業の警告管理標準 EEMUA 191。定常運用で
// 「10分に1件(6件/時)が許容、12件/時が操作者の捌ける上限」とされる。
//
// 2026-08-06 実機ログの実績:
//   A(4x)  106分で123回 = **70回/時**  上限の5.8倍
//   E(8+)   75分で 52回 = 42回/時
//   D(8+)   64分で 33回 = 31回/時
//   B(8+)   43分で 29回 = 40回/時
//   C(2x)  109分で 17回 = 9.4回/時   基準内
//
// 同じ水域・同じ時間帯で **7倍の開き** があること自体が、
// 頻度が状況ではなく測位品質のばらつきで決まっていた証拠である。
//
// **この予算を単独の合否基準にしてはいけない。**
// 本物の警告を消せば達成できてしまう。見逃しと初報遅延が
// 先に失格基準として効いている前提でのみ意味を持つ、
// 辞書式の最後の比較項目である。

/// 定常運用で許容する読み上げ回数 [回/時]。
const audioAnnouncementBudgetPerHour = 6;

/// 読み上げ回数の上限 [回/時]。これを超えると警告は形骸化する。
const audioAnnouncementCeilingPerHour = 12;

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

/// 同一警告の clearing→alerting 往復を「多すぎる」とみなす観測窓。
///
/// 2026-08-05 の実機ログでは桟橋で 24回/分 の往復が起きていた。
/// 1件ずつ記録するとログが埋まるので、窓あたりの回数が
/// [alertFlappingReArmThreshold] を超えたときだけ1件残す。
const alertFlappingObservationWindow = Duration(seconds: 60);

/// 上の窓の中で何回往復したら記録するか。
///
/// 正常な接近・離脱でも数回は往復しうる。実機で問題になった水準
/// (24回/分)よりは十分低く、正常域よりは高いところに置く。
const alertFlappingReArmThreshold = 10;

/// 診断イベントの意味と、ログから検証する仮説のカタログ版。
const diagnosticCatalogVersion = 5;

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
          'GNSS艇速との差、ストローク距離、キャッチ減速、ドライブ後半加速、リカバリー保持、信頼度を同じelapsedMsで比較する。IMU不能時はGNSS単独へ縮退していることも確認する。',
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
    'app_lifecycle_changed': 'OSが通知したアプリのライフサイクル状態が変化した。',
    'ashore_detector_loaded': '離岸・着岸判定に使う設定と領域の読み込みが完了した。',
    'ashore_manual_override': '利用者が離岸・着岸状態の自動判定を手動で上書きした。',
    'ashore_state_changed': '離岸・着岸の判定状態が変化した。',
    'audio_context_applied': '警告音に使うOSの音声コンテキスト設定を適用した。',
    'audio_cue_dropped': '単発合図キューの上限超過により古い合図を破棄した。',
    'audio_cue_failed': '単発合図の準備・再生・停止のいずれかが失敗した。',
    'audio_cue_requested': 'カーブ等の単発合図を専用プレイヤーへ要求した。',
    'audio_cue_skipped': '重複、破棄済み等の理由で単発合図を再生しなかった。',
    'audio_cue_started': '単発合図の再生開始をアプリが確認した。聴感上の成功を意味しない。',
    'audio_directive': '警告評価が選んだ音声指示のスナップショット。',
    'audio_dispose_requested': '警告音プレイヤーの破棄を開始した。',
    'audio_disposed': '警告音プレイヤーと購読の破棄が完了した。',
    'audio_initialization_failed': '警告音プレイヤーの初期設定が失敗した。',
    'audio_initialization_started': '警告音プレイヤーの初期設定を開始した。',
    'audio_initialization_succeeded': '警告音プレイヤーの初期設定が完了した。',
    'audio_loop_restarted': '持続警告音の1周終了後に次の再生を開始した。',
    'audio_output_volume_changed': 'OSが報告する出力音量の低音量判定が変化した。',
    'audio_platform_call_timeout': '音声プラグイン呼び出しが所定時間内に完了しなかった。',
    'audio_play_skipped': '破棄済み、重複等の理由で持続警告音の再生を見送った。',
    'audio_playback_failed': '持続警告音の音源設定または再生開始が失敗した。',
    'audio_playback_stalled': '再生中のはずの持続警告音で進行停止を検出した。',
    'audio_player_recreate_failed': '異常後の警告音プレイヤー再生成が失敗した。',
    'audio_player_recreated': '異常後に警告音プレイヤーを再生成した。',
    'audio_player_state_changed': '音声プラグインが報告するプレイヤー状態が変化した。',
    'audio_readiness_check_failed': '出艇前の警告音準備確認を完了できなかった。',
    'audio_readiness_check_finished': '出艇前の警告音準備確認が完了した。',
    'audio_readiness_check_started': '出艇前の警告音準備確認を開始した。',
    'audio_recovery_failed': '停止した持続警告音の自動復旧が失敗した。',
    'audio_recovery_started': '停止した持続警告音の自動復旧を開始した。',
    'audio_recovery_succeeded': '停止した持続警告音の自動復旧に成功した。',
    'audio_resume_requested': '音源設定後に音声プラグインへ再生再開を要求した。',
    'audio_source_set': '警告音プレイヤーへの音源設定が完了した。',
    'audio_stop_command': '直列キュー内で持続警告音の停止処理を開始した。',
    'audio_stop_completed': '持続警告音の停止処理が完了した。',
    'audio_stop_requested': '提示ポリシーまたは航行終了が持続警告音の停止を要求した。',
    'audio_test_finished': '利用者による警告音試験が終了した。成功可否はdetailsで区別する。',
    'audio_test_started': '利用者による警告音試験を開始した。',
    'warning_presentation_requested': 'SafetyOrchestratorが選んだ警告をUI/音声層へ渡した瞬間。',
    'warning_presentation_cleared': '前回提示していた警告を画面/音声層から解除した瞬間。',
    'audio_directive_changed': '安全判定の音声対象・モードが前回から変わった瞬間。',
    'audio_play_requested': 'AudioPlayerへ再生要求を出した瞬間。',
    'audio_playback_started':
        'AudioPlayerのresume完了とplaying状態をアプリが確認した瞬間。聴感上の成功を意味しない。',
    'audio_route_snapshot': 'OSが報告する音声経路・他音声再生状態のスナップショット。',
    'battery_level_changed': '電池残量または充電状態が前回記録から変化した。',
    'battery_read_failed': '端末の電池残量・充電状態を取得できなかった。',
    'bridge_pier_orphaned': '障害物データの橋脚がどの橋グループにも対応していない。',
    'bridge_piers_unplotted': '障害物データに地図表示できない橋脚がある。',
    'centerline_derived_fallback': '配布中心線を使えず、他データから導出した代替中心線を使用した。',
    'centerline_missing': '必要な航路中心線を読み込めなかった。',
    'channel_centerline_loaded': '航路中心線の読み込みが完了した。',
    'channel_lanes_loaded': '航路レーンデータの読み込みが完了した。',
    'channel_lanes_unavailable': '航路レーンデータを使用できない。',
    'dynamic_obstacle_records_unreadable': '動的障害物の受信レコードに変換不能なものがあった。',
    'dynamic_obstacle_stream_error': '動的障害物の購読ストリームで障害を検出した。',
    'dynamic_obstacle_stream_recovered': '動的障害物の購読が障害から回復した。',
    'dynamic_receive_access_probe_started': '他艇位置が0件でも読取り能力を確認できる最小読取りを開始した。',
    'dynamic_receive_access_probe_completed': '他艇位置バックエンドの読取り成功を確認した。',
    'dynamic_receive_access_probe_failed': '他艇位置バックエンドの読取り確認がタイムアウトまたはエラーになった。',
    'final_session_save_started': '航行終了時の最終セッション保存を開始した。',
    'gps_bootstrap_unusable': '航行開始時に使える精度のGNSS fixを確立できなかった。',
    'position_processing_sample': 'GPS受信から警告評価・記録・位置共有までの処理時間内訳。',
    'position_processing_gap': '新しいGNSS位置処理の間隔が許容値を超えた。',
    'position_processing_slow': '一回の位置処理が許容時間を超えた。',
    'gps_environment_snapshot': 'GNSS権限・サービス・端末設定の状態を取得した。',
    'gps_environment_snapshot_failed': 'GNSS権限・サービス・端末設定の状態を取得できなかった。',
    'gps_fix_envelope': '受信GNSS fixと推定器の誤差・innovation・受理判定を記録した。',
    'gps_fix_rejected': 'GNSS fixを品質フィルタが航行計算から除外した。',
    'gps_one_shot_recovery_failed': 'GNSS stream障害後の1回限り測位が失敗した。',
    'gps_one_shot_recovery_started': 'GNSS stream障害後の1回限り測位を開始した。',
    'gps_one_shot_recovery_succeeded': 'GNSS stream障害後の1回限り測位に成功した。',
    'gps_position_coalesced': '位置処理中に届いた複数fixを最新の1件へ畳み込んだ。',
    'gps_quality_changed': 'GPS品質判定がgood・degraded・unusableの間で変化した。',
    'gps_stream_error': 'OSのGNSS購読ストリームで障害を検出した。',
    'gps_stream_recovered': 'OSのGNSS購読ストリームが障害から回復した。',
    'gps_watchdog_tick_error': 'GNSS無通知監視の定期処理自体が失敗した。',
    'gps_dead_reckoning_prediction':
        'GPS入力が短時間途絶した間、直前の速度・方位から不確実性を増やしつつ自艇位置と警告を予測した。航跡・位置共有には使用しない。',
    'gps_dead_reckoning_failed': '任意機能である短時間推測航法の計算または警告評価が失敗した。通常のGPS監視は継続する。',
    'stroke_motion_analyzed':
        '直近の完全な1ストロークから、融合艇速・ストローク距離・キャッチ減速・ドライブ後半加速・リカバリー保持を算出した。実験指標であり技術評価を断定しない。',
    'imu_fusion_health': '加速度・ジャイロのサンプル充足と融合信頼度を10秒ごとに記録する。',
    'imu_sensor_error': '加速度またはジャイロの購読失敗。GNSS単独経路へ縮退する。',
    'diagnostic_heartbeat': '定期的な生存確認と各サブシステムの状態スナップショット。'
        'serverTimeOffsetUpdatedAt、acceptedFutureTimestampRecordCount、'
        'maxAcceptedFutureTimestampSkewMs は時計ずれ診断用。',
    'gps_position_poll_succeeded':
        'GNSS streamが黙っている間に getCurrentPosition で測位を取り直した。'
            'OSは測位を持っていて配信だけ絞ることがあるため、待たずに取りに行く。',
    'gps_position_poll_skipped': 'ポーリングが取れた測位がstreamの最新より古い/同じだったため流さなかった。',
    'gps_position_poll_failed': 'ポーリングが失敗した。streamと推測航法は従来どおり継続する。',
    'hazard_profile_unverified': '読み込んだ固定障害物profileの版・ハッシュを検証できなかった。',
    'mooring_areas_loaded': '係留・着岸領域データの読み込みが完了した。',
    'navigation_started': '航行セッションが開始し、初期状態を記録した。',
    'navigation_stop_step_failed': '航行終了シーケンスの個別工程が失敗またはタイムアウトした。',
    'navigation_stop_step_skipped': '航行終了の残り予算不足で個別工程を実行しなかった。',
    'navigation_stopping': '航行終了シーケンスを開始した。',
    'navigation_widget_disposed': '航行画面が破棄され、その時点の状態を記録した。',
    'orientation_changed': '端末の画面方向が変化した。',
    'other_boat_record_rejected': '受信した他艇レコードを不正・期限外等の理由で除外した。',
    'position_estimator_reset': '位置推定器を再捕捉・タイムスタンプ異常等の理由で初期化した。',
    'position_sharing_failed': '通常の自艇位置書き込みが失敗した。',
    'position_sharing_recovered': '自艇位置共有が失敗状態から回復した。',
    'position_sharing_setup_failed': '位置共有開始の初期設定が失敗した。',
    'position_sharing_setup_recovered':
        '位置共有開始のclear・onDisconnect登録が遅延または再試行後に完了した。',
    'position_sharing_clear_started': '前回の自艇位置を消去する開始工程に入った。',
    'position_sharing_clear_completed': '前回の自艇位置の消去ACKを受けた。',
    'position_sharing_clear_failed': '前回の自艇位置の消去処理がエラーで失敗した。',
    'position_sharing_disconnect_arm_started':
        '切断時に自艇位置を消すonDisconnect登録を開始した。',
    'position_sharing_disconnect_arm_completed':
        '切断時に自艇位置を消すonDisconnect登録のACKを受けた。',
    'position_sharing_disconnect_arm_failed':
        '切断時に自艇位置を消すonDisconnect登録がエラーで失敗した。',
    'position_publish_contract_rejected': 'サーバーRulesで拒否される位置payloadを送信前に除外した。',
    'position_publish_contract_recovered': '送信payloadがサーバーRulesの契約内に戻った。',
    'position_sharing_setup_retry_failed': '位置共有開始設定の再試行が失敗した。',
    'position_sharing_unavailable': '初期設定、連続送信失敗、ACK無通知のいずれかで位置共有不能と判定した。',
    'safety_contract_violation': '安全パイプラインの不変条件が満たされなかった。',
    'safety_pipeline_error': '位置から警告を計算する安全パイプラインが例外で失敗した。',
    'safety_pipeline_recovered': '安全パイプラインが失敗状態から正常評価へ回復した。',
    'alert_phase_flapping': '同一alertIdの clearing→alerting 往復が単位時間あたりの上限を超えた。'
        '測位欠測を警告解除の根拠にしていないかを疑う指標。',
    'safety_timer_stalled': '1秒安全監視タイマー自身の実行間隔が上限を超えた。GPS入力途絶や評価停止とは別に記録する。',
    'safety_evaluation_stalled': 'GPS入力は新しいが、衝突評価の正常完了時刻が上限より古い。',
    'session_summary': 'セッション終了時の件数・欠落数・最終状態の集計。',
    'session_recovery_detected': '前回の未完了checkpointを次回セッション開始時に検出した記録。',
    'session_checkpoint_queued': '航行中checkpointを保存キューへ追加した。',
    'session_checkpoint_save_failed': '航行中checkpointの保存が失敗した。',
    'session_checkpoint_saved': '航行中checkpointの保存が完了した。',
    'session_recovery_probe_failed': '起動時の未完了checkpoint検索が失敗した。',
    'session_recovery_save_failed': '検出した未完了checkpointの復旧保存が失敗した。',
    'team_membership_self_check_started': '航行開始時の位置共有用RTDB所属bridge読取り確認を開始した。',
    'team_membership_self_check_completed':
        '位置共有用RTDB所属bridgeの一致・不在・読取り拒否を区別した。',
    'setting_change_apply_failed': '航行中の設定変更を安全パイプラインへ反映できなかった。',
    'setting_changed_during_navigation': '航行中に警告・表示等の設定が変更された。',
    'shared_safety_cache_unavailable': '共有安全設定のローカルキャッシュを使用できない。',
    'shared_safety_calibration_applied': '受信した共有安全校正値を航行中の判定へ適用した。',
    'shared_safety_calibration_apply_failed': '受信した共有安全校正値を適用できなかった。',
    'shared_safety_calibration_pending': '共有安全校正値を適用待ちとして保持した。',
    'shared_safety_calibration_recovered': '共有安全校正の購読が障害から回復した。',
    'shared_safety_calibration_start_failed': '共有安全校正の購読開始が失敗した。',
    'shared_safety_calibration_stream_error': '共有安全校正の購読ストリームで障害を検出した。',
    'shared_safety_defaults_init_failed': '共有安全設定の初期値作成が失敗した。',
    'shared_safety_defaults_initialized': '共有安全設定の初期値を作成した。',
    'shared_safety_fetch_failed': '共有安全設定の取得が失敗した。',
    'shared_safety_fetch_timeout': '共有安全設定の取得が所定時間内に完了しなかった。',
    'sharing_capability_confirmed': '送信設定・受信購読・認可の組み合わせが共有可能状態に戻った。',
    'sharing_capability_unconfirmed': '送信設定・受信購読・認可のいずれかを確認できない。',
    'solution_separation': '測位フィルタの独立解が大きく乖離した。',
    'static_profile_load_failed': '固定障害物・航路・着岸領域のprofile読み込みが失敗した。',
    'stroke_trace_share': 'ストローク波形の共有試行と成功・失敗を記録した。',
    'temporary_obstacle_stream_error': '一時障害物の購読ストリームで障害を検出した。',
    'temporary_obstacle_stream_recovered': '一時障害物の購読が障害から回復した。',
    'wakelock_state_changed': '画面消灯防止の要求状態または適用結果が変化した。',
  },
};
