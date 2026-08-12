import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map_math/flutter_geo_math.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/config/alert_presentation_config.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';

import '../hooks/use_alert.dart';
import '../hooks/navigation_stop_budget.dart';
import '../hooks/use_screen_wakelock.dart';
import '../hooks/use_stroke_rate.dart';
import '../config/log_config.dart';
import '../config/build_provenance.dart';
import '../config/stroke_rate_config.dart';
import '../config/system_fault_config.dart';
import '../config/warning_audio_config.dart';
import '../models/alert_candidate.dart';
import '../models/boat_model.dart';
import '../models/danger_zone_settings.dart';
import '../models/fix_envelope.dart';
import '../models/message_model.dart';
import '../models/nav_config_model.dart';
import '../models/navigation_warning.dart';
import '../models/protection_budget.dart';
import '../models/safety_snapshot.dart';
import '../models/session_model.dart';
import '../models/shared_safety_calibration.dart';
import '../models/shared_stroke_trace.dart';
import '../models/static_obstacle_model.dart';
import '../services/ashore_detector.dart';
import '../services/collision_risk_evaluator_service.dart';
import '../services/conservative_position_estimator.dart';
import '../services/audio_route_diagnostics_service.dart';
import '../services/channel_centerline.dart';
import '../services/channel_lane_resolver.dart';
import '../services/danger_zone_settings_service.dart';
import '../services/device_runtime_diagnostics_service.dart';
import '../services/env_service.dart';
import '../services/estimator_clock.dart';
import '../services/fixed_obstacle_calibration_service.dart';
import '../services/geo_service.dart';
import '../services/fix_batch_collector.dart';
import '../services/fix_ingress_policy.dart';
import '../services/gps_position_filter.dart';
import '../services/gps_health_monitor.dart';
import '../services/latest_only_async_publisher.dart';
import '../services/message_service.dart';
import '../services/navigation_warning_service.dart';
import '../services/other_boat_track_store.dart';
import '../services/permission_service.dart';
import '../services/preset_obstacle_service.dart';
import '../services/receive_fault_debouncer.dart';
import '../services/sharing_capability_monitor.dart';
import '../services/risk_evaluator_settings_service.dart';
import '../services/resilient_stream_supervisor.dart';
import '../services/robust_position_estimator.dart';
import '../services/rowing_motion_fusion.dart';
import '../services/stroke_speed_trace.dart';
import '../services/team_service.dart';
import '../services/safety_orchestrator.dart';
import '../services/warning_presenter.dart';
import '../services/safety_evaluation_liveness.dart';
import '../services/safety_contract_monitor.dart';
import '../services/position_integrity_monitor.dart';
import '../services/send_policy.dart';
import '../services/session_analyzer_service.dart';
import '../services/session_store_service.dart';
import '../services/presentation_state_codec.dart';
import '../services/shared_calibration_sync_policy.dart';
import '../services/shared_safety_calibration_service.dart';
import '../types/collision_risk_level.dart';
import '../types/nav_mode.dart';
import '../types/safety_level.dart';
import '../utils/heading.dart';

SafetyLevel _safetyLevelFrom(CollisionRiskLevel riskLevel) {
  switch (riskLevel) {
    case CollisionRiskLevel.lv0:
      return SafetyLevel.safe;
    case CollisionRiskLevel.lv1:
      return SafetyLevel.caution;
    case CollisionRiskLevel.lv2:
      return SafetyLevel.warning;
    case CollisionRiskLevel.lv3:
      return SafetyLevel.emergency;
  }
}

const _publishingSetupAckTimeout = Duration(seconds: 5);
const _publishingCleanupAckTimeout = Duration(seconds: 3);
const _sessionCheckpointInterval = Duration(seconds: 60);

/// 途中チェックポイントで練習ログ解析をやり直す間隔。
const _checkpointSummaryRefreshInterval = Duration(minutes: 5);

/// 同じ警告が続いている間、1Hzのobservationを記録する間隔。
/// 状態遷移・音声対象の変化は間引かず、必ず記録する。
const _alertObservationSampleInterval = Duration(seconds: 5);
const _diagnosticHeartbeatInterval = Duration(seconds: 30);
const _processingTimingSampleInterval = Duration(seconds: 10);
const _platformReadTimeout = Duration(seconds: 2);

class _QueuedPosition {
  final Position position;
  final FixSource source;

  const _QueuedPosition(this.position, this.source);
}

/// 生のGNSSコース・座標差から求めた方位へ掛ける平滑化の重み。
/// これらは1測位ぶんのGPS揺れをそのまま含むため、従来どおり半分に効かせる。
const _rawHeadingBlendWeight = 0.5;

/// Kalman推定由来の方位へ掛ける重み。推定器の中で共分散による平滑化が
/// 済んでいるので、ここで二重に遅らせない。
const _estimatedHeadingBlendWeight = 1.0;

double _blendHeading(double previous, double measured, {double weight = 0.5}) {
  final previousRadians = previous * math.pi / 180;
  final measuredRadians = measured * math.pi / 180;
  final x = (1 - weight) * math.cos(previousRadians) +
      weight * math.cos(measuredRadians);
  final y = (1 - weight) * math.sin(previousRadians) +
      weight * math.sin(measuredRadians);
  if (x.abs() < 1e-9 && y.abs() < 1e-9) return measured;
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double? _finiteOrNull(double value) => value.isFinite ? value : null;

Map<String, Object?> _positionSharingErrorDetails(Object error) {
  if (error is FirebaseException) {
    final message = error.message?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return {
      'errorType': 'FirebaseException',
      'errorCode': error.code,
      'plugin': error.plugin,
      if (message != null && message.isNotEmpty)
        'message': message.length <= 240 ? message : message.substring(0, 240),
      if (error.code == 'permission-denied')
        'likelyCause':
            'rtdb_rules_payload_membership_auth_app_check_or_deployed_rules',
    };
  }
  return {'errorType': error.runtimeType.toString()};
}

/// 原因分類に使う errorCode。Firebase 以外は null。
String? _sharingErrorCode(Object error) =>
    error is FirebaseException ? error.code : null;

class _NavigationMetricsObserver with WidgetsBindingObserver {
  final VoidCallback onMetricsChanged;

  _NavigationMetricsObserver(this.onMetricsChanged);

  @override
  void didChangeMetrics() => onMetricsChanged();
}

UseNavigator useNavigator() {
  // Navigator
  final config = useState<NavConfig?>(null);
  final mode = useState<NavMode>(NavMode.observer);
  final safetyLevel = useState<SafetyLevel>(SafetyLevel.safe);
  final primaryWarningLeadTimeSeconds =
      useState<double>(primaryWarningLeadSeconds);
  // 予測地平。公開APIの名称は既存画面との互換性のため保つが、W12以降は
  // 「断続音の予告開始時間」と同じ advanceWarningLeadSeconds を入れる。
  final warningTimeSeconds = useState<double>(defaultWarningTimeSeconds);
  final myBoat = useState<Boat?>(null);
  final otherBoats = useState<List<Boat>>([]);
  final obstacles = useState<List<StaticObstacle>>([]);
  final defaultObstacles = useState<List<StaticObstacle>>([]);
  final temporaryObstacles = useRef<List<StaticObstacle>>([]);
  final isPositionSharingUnavailable = useState(false);
  // 位置共有の「能力」が確認できない状態。隻数ではなく能力を見る。
  // 0隻は正常状態でもあり得るので、それだけでは fault にしない
  // (sharing_capability_monitor.dart)。**表示のみで音は足さない。**
  final isSharingCapabilityUnconfirmed = useState(false);

  /// 端末の出力音量が低く、読み上げが聞こえない恐れがある状態。表示のみ。
  final isAudioOutputVolumeLow = useState(false);
  final sharingCapabilityMonitor = useRef(SharingCapabilityMonitor()).value;
  final publishingSetupRetryAttempt = useRef(0);
  final publishingSetupFailureKind = useRef<SharingFailureKind?>(null);
  final publishingSetupNextRetryAt = useRef<DateTime?>(null);
  final publishingSetupInFlight = useRef<Future<void>?>(null);
  final publishingSetupGeneration = useRef(0);
  final publishContractViolationField = useRef<String?>(null);
  final membershipReceiveProbeConfirmed = useRef(false);
  final membershipAuthorization = useRef(SharingAuthorization.unknown);
  // 「他艇0」でも、バックエンドから初回snapshotが届けば
  // 購読経路は確認できる。serverTimeOffsetは補助経路であり、
  // それだけの失敗で他艇受信を利用不可にしない。
  final dynamicReceiveAccessConfirmed = useRef(false);
  final receiveAccessProbeInFlight = useRef(false);
  final lastReceiveAccessProbeAt = useRef<DateTime?>(null);
  final receiveAccessProbeGeneration = useRef(0);
  final isDynamicReceiveUnavailable = useState(false);
  // 受信ストリームが報告した「生の」劣化。fault への昇格は
  // [receiveFaultDebouncer] が1秒周期で決める。実機ログでは生の値が
  // 数秒周期でフラップし、77分で315エピソードになっていた。
  final rawDynamicReceiveDegraded = useRef(false);
  final receiveFaultDebouncer = useRef(ReceiveFaultDebouncer());
  final isTemporaryObstacleReceiveUnavailable = useState(false);
  final isSharedSafetyCalibrationSyncUnavailable = useState(false);
  // 今回の航行に適用した危険区域幅の出所。共有設定が無い/古い場合も開始を
  // 止めず、計器とdiagnosticsへ明示して2台の形状差を照合可能にする(W6)。
  final dangerZoneSettingsSource = useState<DangerZoneSettingsSource?>(null);
  final sharedSafetyFetchResult =
      useState<SharedSafetyFetchResult>(SharedSafetyFetchResult.unavailable);
  final sharedSafetyCacheAge = useState<Duration?>(null);
  final sharedSafetyTeamIdHash = useState<String?>(null);
  final appliedSharedSafetyRevision = useState<int?>(null);
  final pendingSharedSafetyRevision = useState<int?>(null);
  final safetySettingsLabel = useState('安全設定: 読込中');
  final safetySettingsNeedsAttention = useState(true);
  final isStaticProfileUnavailable = useState(false);
  // 航路中心線。無い場合は従来の直線予測へ縮退する(警告は止まらない)。
  // 判定本体と開発用オーバーレイで同じ航路予測を確認できるよう、
  // 再描画可能な状態として保持する。通常の地図表示はこの値を使わない。
  final channelCenterline = useState<ChannelCenterline?>(null);
  // レーンが読めないときは null のままにして、評価は従来の cross 符号方式へ
  // 縮退する。GPS評価の周期ごとにJSONを読んだりResolverを作り直したりしない。
  final channelLaneResolver = useState<ChannelLaneResolver?>(null);
  final isWatching = useState(false);
  // 監視一括ログ専用。Boatへ警告状態を持たせず、地図・衝突評価へ渡さない。
  final receivedPracticeLogMessages = useState<List<Message>>(const []);
  final preRawPos = useState<Position?>(null);
  final preHeading = useState<double?>(0.0);
  // Streams
  // Time
  final preProcessTime = useState<DateTime>(DateTime.now());
  final postProcessTime = useState<DateTime>(DateTime.now());
  // 適応送信
  final lastQueuedTick = useRef<Duration?>(null);
  final messageSessionId = useRef<String?>(null);
  final messageSequence = useRef(0);
  final lastProcessedTick = useRef<Duration?>(null);
  final lastValidGpsAt = useRef<DateTime?>(null);
  final gpsLossAnnounced = useRef(false);
  final sharingFailureCount = useRef(0);
  final sharingFailureAnnounced = useRef(false);
  final gpsWatchdog = useRef<Timer?>(null);
  final gpsQuality = useState(GpsHealthQuality.unusable);
  // GPS精度とは別に、platform streamが無通知で再接続中かを表示する。
  // 単発測位が成功してもstream自体の復旧を確認するまではtrueを維持する。
  final isGpsStreamRecovering = useState(false);
  final gpsStreamRecoveryStartedAt = useRef<DateTime?>(null);
  final gpsRecoveryProbeAttempted = useRef(false);
  final gpsRecoveryProbeInFlight = useRef(false);
  final lastAcceptedGpsSpeedMetersPerSecond = useRef<double?>(null);
  // 無通知とみなす時間を状況で切り替えるために、直前の測位精度も覚える。
  final lastAcceptedGpsAccuracyMeters = useRef<double?>(null);
  // 受理した測位そのものの時刻。ポーリングが stream と同じ測位を
  // 二度流さないための比較に使う(受理時刻ではなく fix の時刻)。
  final lastValidGpsTimestamp = useRef<DateTime?>(null);
  // フラッピング検出。alertIdごとの clearing→alerting 発生時刻と、
  // 最後に記録した時刻(同じ窓で何度も記録しないため)。
  final alertReArmWindow = useRef<Map<String, List<DateTime>>>({});
  final lastFlappingReportAt = useRef<Map<String, DateTime>>({});
  // 測位ポーリングの状態。多重呼び出しと連打を防ぐ。
  final gpsPollInFlight = useRef(false);
  final lastGpsPollAt = useRef<DateTime?>(null);
  final gpsPollSucceededCount = useRef(0);
  final gpsPollFailedCount = useRef(0);
  // 直近60秒の測位到着時刻。実効レートを heartbeat へ残すために使う。
  final recentPositionArrivals = useRef<List<Duration>>(<Duration>[]);
  // バックグラウンド中に音声指示が出た回数と、そのうち提示層へ届いた回数。
  // 提示が描画に依存していた頃は前者だけが伸び、後者はゼロのままだった。
  // この2つの比が「背面で鳴らない」の再発を次回ログで即座に示す。
  final audioDirectiveWhilePausedCount = useRef(0);
  final audioPresentationWhilePausedCount = useRef(0);
  final isPipelineUnresponsive = useState(false);
  final pipelineRecoveryNeedsAssessment = useRef(false);
  final pipelineRecoveryTicks = useRef(0);
  // GPS入力途絶、Timer停止、GPS入力後の評価停止を混同しない。
  // GPS途絶そのものは GpsHealthMonitor が担当し、ここでは後者2つだけを
  // 単調時計で監視する(W7)。
  final safetyEvaluationLiveness = useRef(
    SafetyEvaluationLiveness(
      timerStallThreshold: const Duration(seconds: 3),
      evaluationStallThreshold:
          const Duration(seconds: safetyEvaluationStallSeconds),
    ),
  );
  final safetyTimerStalled = useRef(false);
  final safetyEvaluationStalled = useRef(false);
  // GPS更新が処理中に重なっても、最新の1件だけを順番に処理する。
  // 停止後に古い非同期結果がUIやFirebaseを復活させないよう、
  // 航行世代とドレイン完了Futureを保持する。
  final navigationGeneration = useRef(0);
  final positionBatchCollector = useMemoized(
    () => FixBatchCollector<_QueuedPosition>((item) => item.position.timestamp),
  );
  final fixIngressPolicy = useMemoized(FixIngressPolicy.new);
  final fixEnvelopeSequence = useRef(0);
  final previousFixEnvelopeTimestamp = useRef<DateTime?>(null);
  final previousFixEnvelopeArrival = useRef<Duration?>(null);
  final lastFixEnvelopeSampleAt = useRef<Duration?>(null);
  final positionDrainRunning = useRef(false);
  final positionDrainFuture = useRef<Future<void>?>(null);
  final navigationStartInProgress = useRef(false);
  final navigationStopInProgress = useRef(false);
  // `.timeout()` 後にも元Futureは動き続けるため、古い終了処理が
  // 新しい航行状態を後から消さないよう終了処理専用の世代を持つ。
  final stopGeneration = useRef(0);
  final isTransitioning = useState(false);
  final currentBatteryLevel = useState<int?>(null);
  final lastBatteryReadAt = useRef<DateTime?>(null);
  final batteryReadInFlight = useRef(false);
  final lastDiagnosticBatteryLevel = useRef<int?>(null);
  final batteryReadFailureAnnounced = useRef(false);
  final gpsFilter = useRef(GpsPositionFilter(
    maxAccuracyMeters: degradedGpsAccuracyThresholdMeters,
    maxSpeedMetersPerSecond: maxAcceptedGpsSpeedMetersPerSecond,
    maxTimestampAge: const Duration(seconds: maxGpsTimestampAgeSeconds),
    rejectMocked: kReleaseMode,
    acceptLowAccuracy: enableRobustPositionFilter,
  ));
  final positionEstimator = useMemoized(RobustPositionEstimator.new);
  final conservativePositionEstimator =
      useMemoized(ConservativePositionEstimator.new);
  final positionIntegrityMonitor = useMemoized(PositionIntegrityMonitor.new);
  final safetyContractMonitor = useMemoized(SafetyContractMonitor.new);
  final distanceIntegrator = useMemoized(RowingDistanceIntegrator.new);
  final lastDeadReckoningPredictionTick = useRef<Duration?>(null);
  final previousEstimatedPosition = useRef<LatLng?>(null);
  // Kalmanの dt はGNSSの測位時刻を基準にする。処理時刻を使うと、OSの
  // バッファリング遅延のジッタがそのまま dt 誤差になる。
  final estimatorClock = useMemoized(EstimatorClock.new);
  // 利用者向け警告の**表示**。音声はここから出さない。
  //
  // 以前はこの primary から音も鳴らしていたため、`audioAsset` が null の
  // system fault(未検証水域など)が primary になるたびに `alert.stop()` が
  // 走り、鳴っている警告音を無音の警告が消していた(実機ログで216回)。
  // 音は `SafetyOrchestrator` が独立に選ぶ `audioDirective` から出す。
  final currentWarning = useState<NavigationWarning?>(null);
  // 警告音(連続音・断続音)の指示。表示 primary とは独立に選ばれる。
  final audioDirective = useState<AudioDirective?>(null);
  // 鳴っている音のカテゴリ(診断ログ用)。表示primaryとは別になりうる。
  final audioDirectiveCategory = useState<String?>(null);
  // 陸上判定中は持続音を止める。検知・表示・記録は止めない。
  final isAshore = useState(false);
  final ashoreDetector = useRef<AshoreDetector?>(null);
  final lastAshoreState = useRef<AshoreState>(AshoreState.initial);
  // 桟橋エリア（着艇・係留の水域）。危険区域ではなく提示ポリシーだけを変える。
  final mooringAreaPolygons = useRef<List<List<LatLng>>>(const []);
  final activeWarnings = useState<List<NavigationWarning>>(const []);
  final activeWarningCount = useState(0);
  final safetyRunMode = useState<SafetyRunMode>(SafetyRunMode.stopped);
  final safetyOrchestrator = useRef<SafetyOrchestrator?>(null);
  final safetySnapshotGate = useRef(SafetySnapshotGate());
  final gpsHealth = useRef(GpsHealthMonitor());
  final safetyClockOrigin = useRef(DateTime.now());
  final safetyClock = useRef(Stopwatch()..start());
  // セッション記録
  final sessionPoints = useRef<List<TrackPoint>>([]);
  final sessionAlertEvents = useRef<List<AlertDiagnosticEvent>>([]);
  final sessionDiagnosticEvents = useRef<List<SessionDiagnosticEvent>>([]);
  final sessionDiagnosticMetadata = useRef<SessionDiagnosticMetadata?>(null);
  final diagnosticBoatAliases = useRef(<String, String>{});
  final diagnosticAlertAliases = useRef(<String, String>{});
  final diagnosticCandidates = useRef(<String, AlertCandidate>{});
  final lastDiagnosticAudioKey = useRef<String?>(null);
  final lastDiagnosticGpsQuality = useRef<String?>(null);
  final lastDiagnosticOrientation = useRef<String?>(null);
  final lastProcessedWallClock = useRef<DateTime?>(null);
  final lastDiagnosticPositionGapAt = useRef<DateTime?>(null);
  final lastDiagnosticHeartbeatTick = useRef<Duration?>(null);
  final lastProcessingTimingSampleTick = useRef<Duration?>(null);
  final lastSolutionSeparationSampleAt = useRef<Duration?>(null);
  final previousContractFixTimestamp = useRef<DateTime?>(null);
  final lastContractViolationAt = useRef<Map<String, Duration>>({});
  final positionIntegrityState = useRef(PositionIntegrityState.trusted);
  final lastProtectionBudget = useRef<ProtectionBudget?>(null);
  final diagnosticSequence = useRef(0);
  final diagnosticEventDroppedCount = useRef(0);
  final alertEventDroppedCount = useRef(0);
  final positionSharingDiagnosticState = useRef<String?>(null);
  final lastPositionPublishAckAt = useRef<DateTime?>(null);
  final pendingPreSessionDiagnostics = useRef<List<SessionDiagnosticEvent>>([]);
  final recoveryProbeDone = useRef(false);
  final sessionStartedAt = useState<DateTime?>(null);
  final totalDistance = useState<double>(0.0);
  final lastSessionCheckpointTick = useRef<Duration?>(null);
  final lastCheckpointSummary = useRef<SessionSummary?>(null);
  final lastCheckpointSummaryTick = useRef<Duration?>(null);
  final lastAlertObservationAt = useRef(<String, DateTime>{});
  final pendingSessionWrite = useRef<Session?>(null);
  final sessionWriteRunning = useRef(false);
  final sessionWriteFuture = useRef<Future<void>?>(null);

  int? diagnosticElapsedMs(DateTime at) {
    final startedAt = sessionStartedAt.value;
    if (startedAt == null) return null;
    // 航行中はStopwatchを優先し、端末の壁時計変更でイベント順序が
    // 乱れないようにする。航行開始前から引き継いだ音声試験だけは、
    // 実時間差を負の値として残す。
    if (at.isBefore(startedAt)) {
      return at.difference(startedAt).inMilliseconds;
    }
    return safetyClock.value.elapsed.inMilliseconds;
  }

  void appendDiagnosticEvent(SessionDiagnosticEvent event) {
    if (sessionDiagnosticEvents.value.length >= maxSessionDiagnosticEvents) {
      diagnosticEventDroppedCount.value += 1;
      return;
    }
    final json = event.toJson()
      ..['seq'] = ++diagnosticSequence.value
      ..['elapsedMs'] = diagnosticElapsedMs(event.t);
    sessionDiagnosticEvents.value.add(SessionDiagnosticEvent.fromJson(json));
  }

  void appendAlertEvent(AlertDiagnosticEvent event) {
    if (sessionAlertEvents.value.length >= maxSessionAlertDiagnosticEvents) {
      alertEventDroppedCount.value += 1;
      return;
    }
    final json = event.toJson()
      ..['seq'] = ++diagnosticSequence.value
      ..['elapsedMs'] = diagnosticElapsedMs(event.t);
    sessionAlertEvents.value.add(AlertDiagnosticEvent.fromJson(json));
  }

  void appendRuntimeDiagnostic(
    String type, [
    Map<String, dynamic> details = const <String, dynamic>{},
  ]) {
    if (mode.value != NavMode.navigator || sessionStartedAt.value == null) {
      return;
    }
    appendDiagnosticEvent(SessionDiagnosticEvent(
      t: DateTime.now(),
      type: type,
      details: Map<String, dynamic>.from(details),
    ));
  }

  /// 航行開始処理中のFirebase工程を、セッション開始後に
  /// 受け渡す。[appendRuntimeDiagnostic]だけでは開始前に破棄される。
  void queuePreSessionDiagnostic(
    String type, [
    Map<String, dynamic> details = const <String, dynamic>{},
  ]) {
    final event = SessionDiagnosticEvent(
      t: DateTime.now(),
      type: type,
      details: Map<String, dynamic>.from(details),
    );
    if (mode.value == NavMode.navigator && sessionStartedAt.value != null) {
      appendDiagnosticEvent(event);
    } else if (pendingPreSessionDiagnostics.value.length < 40) {
      pendingPreSessionDiagnostics.value.add(event);
    }
  }

  final audioRouteDiagnostics = AudioRouteDiagnosticsService();

  void scheduleAudioRouteSnapshot(String triggerType) {
    if (mode.value != NavMode.navigator || sessionStartedAt.value == null) {
      return;
    }
    unawaited(audioRouteDiagnostics.snapshot().then((snapshot) {
      if (mode.value != NavMode.navigator || sessionStartedAt.value == null) {
        return;
      }
      appendDiagnosticEvent(SessionDiagnosticEvent(
        t: DateTime.now(),
        type: 'audio_route_snapshot',
        details: {
          'triggerType': triggerType,
          ...snapshot,
        },
      ));
      // 端末の出力音量が小さいと、読み上げが鳴っていても聞こえない。
      //
      // 2026-08-06 実機ログ: 8+ に載せた1台が全期間 `outputVolume` 0.30
      // 固定だった(他3台は 1.00)。聞こえたかどうかはログからは判定
      // できないが、音量そのものは毎回取れている。
      //
      // **画面へ出すだけにする。** 音量が小さいことを音で知らせるのは
      // 矛盾しているうえ、本当に鳴るべき衝突警告を覆い隠す。
      final volume = snapshot['outputVolume'];
      if (volume is num) {
        final low = volume < audioLowOutputVolumeThreshold;
        if (low != isAudioOutputVolumeLow.value) {
          isAudioOutputVolumeLow.value = low;
          appendRuntimeDiagnostic('audio_output_volume_changed', {
            'outputVolume': volume.toDouble(),
            'isLow': low,
            'threshold': audioLowOutputVolumeThreshold,
          });
        }
      }
    }));
  }

  // Hooks
  final alert = useAlert(
    onDiagnosticEvent: (type, details) {
      final event = SessionDiagnosticEvent(
        t: DateTime.now(),
        type: type,
        details: Map<String, dynamic>.from(details),
      );
      if (mode.value == NavMode.navigator && sessionStartedAt.value != null) {
        appendDiagnosticEvent(event);
        if (type == 'audio_context_applied' ||
            type == 'audio_playback_started' ||
            type == 'audio_playback_stalled' ||
            type == 'audio_playback_failed' ||
            type == 'audio_test_finished') {
          scheduleAudioRouteSnapshot(type);
        }
        return;
      }
      // 航行開始前の音声試験は、次に開始したセッションへ引き継ぐ。
      // 初期化ログは除外し、実際に試験した結果だけを保持する。
      if (type == 'audio_test_started' || type == 'audio_test_finished') {
        if (pendingPreSessionDiagnostics.value.length < 20) {
          pendingPreSessionDiagnostics.value.add(event);
        }
      }
    },
  );
  // 音声指示を再生要求へ変える層。
  //
  // **ウィジェットの再構築に依存させない。** `useEffect` に置くと build の
  // 一部として走るため、iOS が `paused` にした瞬間から鳴らなくなる
  // (2026-08-05 実機ログ: 96回の指示に対し再生要求1回)。判定側から
  // 直接呼ぶ。再生・停止は従来どおり `enqueueCommand` の直列キューを通る。
  final warningPresenter = useRef(WarningPresenter(
    onPlayLoop: (asset) => unawaited(alert.play(asset)),
    onPlayOnce: (asset, eventId) =>
        unawaited(alert.playOnce(asset, eventId: eventId)),
    onStop: () => unawaited(alert.stop()),
    onDiagnostic: appendRuntimeDiagnostic,
  ));
  useScreenWakelock(
    shouldKeepAwake: shouldKeepScreenAwake(mode.value),
    onDiagnostic: appendRuntimeDiagnostic,
  );
  final strokeRate = useStrokeRate(
    active: mode.value == NavMode.navigator,
    enabled: config.value?.strokeRateEnabled ?? false,
    onDiagnosticEvent: appendRuntimeDiagnostic,
  );
  // Services
  final geoService = useMemoized(GeoService.new);
  final deviceRuntimeDiagnostics =
      useMemoized(DeviceRuntimeDiagnosticsService.new);
  final positionStreamSupervisor = useMemoized(
    () => ResilientStreamSupervisor<Position>(
      silenceTimeout: const Duration(seconds: gpsStreamSilenceRecoverySeconds),
      // **この閾値を「休憩中だから」と延ばしてはいけない。**
      //
      // 一度そうしたが、2026-08-05 の実機ログ2台が逆を示した。無通知に
      // 対する `getCurrentPosition` は 541/541 回すべて成功し、得られた測位は
      // 42〜64ms前の新しいものだった。OSは測位を持っていて配信しないだけで、
      // 待つ時間を延ばすと確実に取れる測位をその分だけ捨てる
      // (実測で欠測が21〜33%増える見積り)。
      //
      // 配信の間引きへは `gpsPositionPollAfterSilence` のポーリングで対処し、
      // この閾値は「購読そのものが死んだ」検知に限って使う。
    ),
  );
  final dynamicObstacleStreamSupervisor =
      useMemoized(() => ResilientStreamSupervisor<dynamic>());
  final temporaryObstacleStreamSupervisor =
      useMemoized(() => ResilientStreamSupervisor<dynamic>());
  final sharedCalibrationStreamSupervisor = useMemoized(
    () => ResilientStreamSupervisor<SharedSafetyCalibrationState?>(),
  );
  final sharedCalibrationSyncPolicy =
      useMemoized(SharedCalibrationSyncPolicy.new);
  final sharedCalibrationCoalesceTimer = useRef<Timer?>(null);
  final sharedCalibrationApplyRunning = useRef(false);
  final sharedCalibrationSyncGeneration = useRef(0);
  // publish中のprofile fingerprintと再接続購読を航行セッション
  // 全体で保つため、Widget rebuildごとに作り直さない。
  final messageService = useMemoized(MessageService.new);
  // 受信と送信の診断を同じinstanceで観測する。これまで
  // heartbeatは送信側instanceのserver offsetを読み、受信中でも
  // nullを記録していた。
  final envService = useMemoized(
    () => EnvService(messageService: messageService),
    [messageService],
  );
  final teamService = useMemoized(TeamService.new);
  final permissionService = useMemoized(PermissionService.new);
  final presetObstacleService = useMemoized(PresetObstacleService.new);
  final evaluatorService = useMemoized(CollisionRiskEvaluatorService.new);
  final navigationWarningService = useMemoized(NavigationWarningService.new);
  final riskEvaluatorSettingsService =
      useMemoized(RiskEvaluatorSettingsService.new);
  final dangerZoneSettingsService = useMemoized(DangerZoneSettingsService.new);
  final fixedObstacleCalibrationService =
      useMemoized(FixedObstacleCalibrationService.new);
  final sharedSafetyCalibrationService =
      useMemoized(SharedSafetyCalibrationService.new);
  final sessionStoreService = useMemoized(SessionStoreService.new);
  final battery = useMemoized(Battery.new);
  final positionPublisher = useMemoized(
    () => LatestOnlyAsyncPublisher<Message>(
      publish: messageService.sendMessage,
      // RTDB Rulesはserver timestamp間を1.9秒以上要求する。圏外writeの
      // ACK直後にも次を送らないよう、完了後2秒のpaceをpublisherで保証する。
      minPublishInterval: const Duration(seconds: 2),
      onSuccess: (_) {
        lastPositionPublishAckAt.value = DateTime.now().toUtc();
        final previousState = positionSharingDiagnosticState.value;
        // Rulesを通った実write ACKは、過去のsetup/所属診断失敗より
        // 強い「現在は利用可能」の証拠。古いdeniedを残さない。
        publishingSetupFailureKind.value = null;
        publishingSetupRetryAttempt.value = 0;
        publishingSetupNextRetryAt.value = null;
        membershipAuthorization.value = SharingAuthorization.granted;
        if (useRealtimeDatabaseForPositions) {
          membershipReceiveProbeConfirmed.value = true;
        }
        sharingFailureCount.value = 0;
        sharingFailureAnnounced.value = false;
        isPositionSharingUnavailable.value = false;
        if (previousState != 'healthy') {
          appendRuntimeDiagnostic('position_sharing_recovered', {
            'previousState': previousState,
          });
          positionSharingDiagnosticState.value = 'healthy';
        }
      },
      onFailure: (message, error, __) {
        sharingFailureCount.value += 1;
        debugPrint('Failed to share position: $error');
        if (positionSharingDiagnosticState.value != 'failed') {
          appendRuntimeDiagnostic('position_sharing_failed', {
            'failureCount': sharingFailureCount.value,
            ..._positionSharingErrorDetails(error),
            'protocolVersion': message.protocolVersion,
            'profileVersion': message.profileVersion,
            'hasWarningState': message.presentationState != null,
            'hasRunMode': message.safetyRunMode != null,
            'audioSuppressedAshore': message.audioSuppressedAshore,
          });
          positionSharingDiagnosticState.value = 'failed';
        }
        if (sharingFailureCount.value >= 3 && !sharingFailureAnnounced.value) {
          sharingFailureAnnounced.value = true;
          isPositionSharingUnavailable.value = true;
          positionSharingDiagnosticState.value = 'unavailable';
          appendRuntimeDiagnostic('position_sharing_unavailable', {
            'failureCount': sharingFailureCount.value,
            'reason': 'consecutive_publish_failures',
          });
        }
      },
      onAckTimeout: (_) {
        if (!sharingFailureAnnounced.value) {
          sharingFailureAnnounced.value = true;
          isPositionSharingUnavailable.value = true;
        }
        if (positionSharingDiagnosticState.value != 'unavailable') {
          positionSharingDiagnosticState.value = 'unavailable';
          appendRuntimeDiagnostic('position_sharing_unavailable', {
            'reason': 'ack_timeout',
          });
        }
      },
    ),
    [messageService],
  );

  Future<Position> getCurrentPosition(LocationAccuracy accuracy) async {
    return await geoService.getCurrentPosition(accuracy);
  }

  /// 監視(コーチ)モードで異常を検知したときの通知音。
  ///
  /// コーチは岸から見ていて画面を注視していない。表示だけでは沈・電池切れの
  /// 兆候を見逃すため、音でも知らせる。航行中の衝突警告とは別経路で、
  /// 単発再生に留める(監視は判断の猶予が秒単位ではない)。
  Future<void> playCoachAnomalyAlert() async {
    if (mode.value != NavMode.observer) return;
    await alert.playOnce(
      coachAnomalyAlertAudioAsset,
      eventId: 'coach-anomaly:${DateTime.now().microsecondsSinceEpoch}',
    );
  }

  /// 陸上判定を利用者の操作で解除する。
  ///
  /// 判定が外れているのに音が出ない、という状況を利用者が自分で
  /// 抜けられるようにする(原則2: 使い方は使い手が決める)。
  /// 次に水面側の測位を観測するまで陸上へ戻らない。
  void overrideAshoreToWater() {
    ashoreDetector.value?.overrideToWater();
    isAshore.value = false;
    appendRuntimeDiagnostic('ashore_manual_override', const {});
  }

  Future<bool> testAudio() async {
    return alert.test();
  }

  Future<bool> checkAudio() async {
    return alert.checkReady();
  }

  double getDistanceBetween(Position pos1, Position pos2) {
    final distance = Geolocator.distanceBetween(
      pos1.latitude,
      pos1.longitude,
      pos2.latitude,
      pos2.longitude,
    );
    return distance;
  }

  bool isOtherBoatAlert(AlertCandidate candidate) =>
      candidate.category == 'other_boat' ||
      candidate.category == 'other_boat_track_lost';

  String diagnosticAlertRef(AlertCandidate candidate) {
    if (!isOtherBoatAlert(candidate)) return candidate.alertId;
    return diagnosticAlertAliases.value.putIfAbsent(
      candidate.alertId,
      () => 'alert-${diagnosticAlertAliases.value.length + 1}',
    );
  }

  String? diagnosticTargetRef(AlertCandidate candidate) {
    final targetId = candidate.targetId;
    if (targetId == null) return null;
    if (!isOtherBoatAlert(candidate)) return targetId;
    return diagnosticBoatAliases.value.putIfAbsent(
      targetId,
      () => 'boat-${diagnosticBoatAliases.value.length + 1}',
    );
  }

  void recordSafetyDiagnostics(SafetyOrchestratorResult result) {
    final candidateById = <String, AlertCandidate>{
      for (final state in result.state.alerts)
        state.candidate.alertId: state.candidate,
    };
    diagnosticCandidates.value.addAll(candidateById);
    final directive = result.snapshot.audioDirective;
    final directiveCandidate =
        directive == null ? null : candidateById[directive.alertId];
    final audioKey = directive == null || directiveCandidate == null
        ? null
        : '${diagnosticAlertRef(directiveCandidate)}:${directive.mode.name}';
    final previousAudioKey = lastDiagnosticAudioKey.value;
    if (previousAudioKey != audioKey) {
      appendDiagnosticEvent(SessionDiagnosticEvent(
        t: result.snapshot.evaluatedAt,
        type: 'audio_directive_changed',
        details: {
          'source': 'safety_orchestrator',
          'previous': previousAudioKey,
          'next': audioKey,
          'directiveAlertId': directive?.alertId,
          'directiveCandidateFound': directiveCandidate != null,
          'directiveMode': directive?.mode.name,
          'primaryAlertId': result.snapshot.primaryAlertId,
          'activeAlertCount': result.snapshot.activeAlerts.length,
        },
      ));
    }
    if (previousAudioKey != null && previousAudioKey != audioKey) {
      appendDiagnosticEvent(SessionDiagnosticEvent(
        t: result.snapshot.evaluatedAt,
        type: 'audio_directive',
        details: {
          'source': 'safety_orchestrator',
          'action': 'stop',
          'previous': previousAudioKey,
          'next': audioKey,
        },
      ));
    }

    final observedAt = result.snapshot.evaluatedAt;
    for (final state in result.state.alerts) {
      final candidate = state.candidate;
      if (state.phase == AlertPhase.safe) continue;
      final isAudioTarget = directive?.alertId == candidate.alertId;
      // 同じ警告が続く間、1秒ごとの観測を全部残すとイベント数が爆発し、
      // 60秒ごとのチェックポイント書き込みも重くなる。音声対象・
      // 判定の変化は必ず残し、変化が無い区間だけ5秒へ間引く。
      final lastObservedAt = lastAlertObservationAt.value[candidate.alertId];
      final isNotable = isAudioTarget ||
          candidate.currentOverlap ||
          previousAudioKey != audioKey ||
          result.state.transitions
              .any((transition) => transition.alertId == candidate.alertId);
      if (!isNotable &&
          lastObservedAt != null &&
          observedAt.difference(lastObservedAt) <
              _alertObservationSampleInterval) {
        continue;
      }
      lastAlertObservationAt.value[candidate.alertId] = observedAt;
      appendAlertEvent(AlertDiagnosticEvent(
        t: result.snapshot.evaluatedAt,
        event: 'observation',
        alertId: diagnosticAlertRef(candidate),
        detectorId: candidate.detectorId,
        category: candidate.category,
        targetRef: diagnosticTargetRef(candidate),
        phase: state.phase.name,
        isPrimary: result.snapshot.primaryAlertId == candidate.alertId,
        riskLevel: candidate.internalPriority,
        currentOverlap: candidate.currentOverlap,
        confidence: candidate.confidence,
        dataQuality: candidate.dataQuality.name,
        distanceMeters: candidate.distanceMeters,
        separationMeters: candidate.separationMeters,
        actionDeadlineSec: candidate.actionDeadline == null
            ? null
            : candidate.actionDeadline!.inMilliseconds / 1000,
        reasonCodes: candidate.reasonCodes,
        audioMode: isAudioTarget ? directive?.mode.name : null,
        audioAction: isAudioTarget
            ? previousAudioKey == audioKey
                ? 'continue'
                : 'start'
            : null,
      ));
    }
    for (final transition in result.state.transitions) {
      final candidate = candidateById[transition.alertId] ??
          diagnosticCandidates.value[transition.alertId];
      if (candidate == null) continue;
      // 同一警告が clearing→alerting を短時間に何度も往復していないか。
      //
      // 往復そのものは正常な現象でもあるので、1件ずつは記録しない。
      // **単位時間あたりの回数が上限を超えたときだけ**記録する。
      // 2026-08-05 の実機ログでは、測位欠測を警告解除の根拠にしていたため
      // 岸で100回・他艇で77回の往復が起きていた(桟橋では24回/分)。
      // 再発を次回ログから自動で見つけられるようにしておく。
      if (transition.from == AlertPhase.clearing &&
          transition.to == AlertPhase.alerting) {
        final alertId = candidate.alertId;
        final window = alertReArmWindow.value.putIfAbsent(
          alertId,
          () => <DateTime>[],
        )..add(transition.occurredAt);
        final since =
            transition.occurredAt.subtract(alertFlappingObservationWindow);
        window.removeWhere((at) => at.isBefore(since));
        final lastReported = lastFlappingReportAt.value[alertId];
        if (window.length >= alertFlappingReArmThreshold &&
            (lastReported == null ||
                transition.occurredAt.difference(lastReported) >=
                    alertFlappingObservationWindow)) {
          lastFlappingReportAt.value[alertId] = transition.occurredAt;
          appendRuntimeDiagnostic('alert_phase_flapping', {
            'alertRef': diagnosticAlertRef(candidate),
            'category': candidate.category,
            'reArmCount': window.length,
            'windowSec': alertFlappingObservationWindow.inSeconds,
            'dataQuality': candidate.dataQuality.name,
          });
        }
      }
      appendAlertEvent(AlertDiagnosticEvent(
        t: transition.occurredAt,
        event: 'transition',
        alertId: diagnosticAlertRef(candidate),
        detectorId: candidate.detectorId,
        category: candidate.category,
        targetRef: diagnosticTargetRef(candidate),
        phase: transition.to.name,
        fromPhase: transition.from.name,
        toPhase: transition.to.name,
        isPrimary: result.snapshot.primaryAlertId == candidate.alertId,
        riskLevel: candidate.internalPriority,
        currentOverlap: candidate.currentOverlap,
        confidence: candidate.confidence,
        dataQuality: candidate.dataQuality.name,
        distanceMeters: candidate.distanceMeters,
        separationMeters: candidate.separationMeters,
        actionDeadlineSec: candidate.actionDeadline == null
            ? null
            : candidate.actionDeadline!.inMilliseconds / 1000,
        reasonCodes: candidate.reasonCodes,
      ));
      if (transition.to == AlertPhase.safe) {
        diagnosticCandidates.value.remove(transition.alertId);
        lastAlertObservationAt.value.remove(transition.alertId);
      }
    }
    lastDiagnosticAudioKey.value = audioKey;
  }

  /// GPSが使えない間は陸上判定を解除する。
  ///
  /// 陸上判定は測位が届いたときにしか更新されない。GPSが途絶すると
  /// 直前の判定のまま固着するため、出艇の直後に測位が落ちると
  /// 「水上なのに音が出ない」状態がGPS復帰まで続く。
  /// [AshoreDetector] 自身もGPS品質が good でなければ陸上と判定しないので、
  /// 判定できない間は音を戻す側へ倒す(データ欠損を無音の根拠にしない)。
  void clearAshoreForUnusableGps() {
    if (!isAshore.value) return;
    isAshore.value = false;
    lastAshoreState.value = AshoreState.initial;
    appendRuntimeDiagnostic('ashore_state_changed', {
      'isAshore': false,
      'reason': AshoreDecisionReason.gpsNotUsable.name,
    });
  }

  void recordGpsQualityIfChanged(
    GpsHealthSnapshot snapshot,
    DateTime at,
  ) {
    gpsQuality.value = snapshot.quality;
    final next = snapshot.quality.name;
    final previous = lastDiagnosticGpsQuality.value;
    if (previous == next) return;
    lastDiagnosticGpsQuality.value = next;
    appendDiagnosticEvent(SessionDiagnosticEvent(
      t: at,
      type: 'gps_quality_changed',
      details: {
        if (previous != null) 'from': previous,
        'to': next,
        'consecutiveRejected': snapshot.consecutiveRejected,
        if (snapshot.acceptedAge != null)
          'acceptedAgeMs': snapshot.acceptedAge!.inMilliseconds,
      },
    ));
  }

  void recordOrientationIfChanged() {
    if (mode.value != NavMode.navigator) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    if (view.devicePixelRatio <= 0) return;
    final logicalWidth = view.physicalSize.width / view.devicePixelRatio;
    final logicalHeight = view.physicalSize.height / view.devicePixelRatio;
    if (logicalWidth <= 0 || logicalHeight <= 0) return;
    final orientation = logicalWidth > logicalHeight ? 'landscape' : 'portrait';
    if (lastDiagnosticOrientation.value == orientation) return;
    lastDiagnosticOrientation.value = orientation;
    appendDiagnosticEvent(SessionDiagnosticEvent(
      t: DateTime.now(),
      type: 'orientation_changed',
      details: {
        'orientation': orientation,
        'logicalWidth': logicalWidth.round(),
        'logicalHeight': logicalHeight.round(),
      },
    ));
  }

  void recordBatteryLevelIfChanged(int? level) {
    if (level == null || level < 0 || level > 100) return;
    final previous = lastDiagnosticBatteryLevel.value;
    final crossedLowBattery =
        previous != null && ((previous < 20) != (level < 20));
    if (previous == null ||
        (previous - level).abs() >= 5 ||
        crossedLowBattery) {
      appendRuntimeDiagnostic('battery_level_changed', {
        'levelPercent': level,
        if (previous != null) 'previousLevelPercent': previous,
      });
    }
    lastDiagnosticBatteryLevel.value = level;
  }

  void updateDiagnosticMetadataCounts() {
    final metadata = sessionDiagnosticMetadata.value;
    if (metadata == null) return;
    metadata.settingsSnapshot['diagnosticEventDroppedCount'] =
        diagnosticEventDroppedCount.value;
    metadata.settingsSnapshot['alertEventDroppedCount'] =
        alertEventDroppedCount.value;
    metadata.settingsSnapshot['diagnosticEventCount'] =
        sessionDiagnosticEvents.value.length;
    metadata.settingsSnapshot['alertEventCount'] =
        sessionAlertEvents.value.length;
  }

  bool isCurrentNavigation(int generation) =>
      generation == navigationGeneration.value &&
      mode.value == NavMode.navigator &&
      config.value != null;

  void recordGpsEnvironmentSnapshot(
    String triggerType,
    int generation, {
    Map<String, Object?> details = const {},
  }) {
    unawaited(deviceRuntimeDiagnostics
        .snapshot()
        .timeout(_platformReadTimeout)
        .then((snapshot) {
      if (!isCurrentNavigation(generation)) return;
      appendRuntimeDiagnostic('gps_environment_snapshot', {
        'triggerType': triggerType,
        ...details,
        ...snapshot,
      });
    }).catchError((Object error) {
      if (!isCurrentNavigation(generation)) return;
      appendRuntimeDiagnostic('gps_environment_snapshot_failed', {
        'triggerType': triggerType,
        'errorType': error.runtimeType.toString(),
      });
    }));
  }

  String formatCacheAge(Duration? age) {
    if (age == null) return 'キャッシュ';
    if (age.inDays >= 1) return '${age.inDays}日前のキャッシュ';
    if (age.inHours >= 1) return '${age.inHours}時間前のキャッシュ';
    return '${age.inMinutes}分前のキャッシュ';
  }

  /// 共有/端末/既定値の選択結果をUIと航行ログへ共通の意味で残す。
  ///
  /// この関数は表示だけを変え、障害物・警告候補・runModeを落とさない。
  void updateSafetySettingsStatus() {
    final source = dangerZoneSettingsSource.value;
    final fetch = sharedSafetyFetchResult.value;
    final revision = appliedSharedSafetyRevision.value;
    switch (source) {
      case DangerZoneSettingsSource.shared:
        final suffix = fetch == SharedSafetyFetchResult.cache
            ? '(${formatCacheAge(sharedSafetyCacheAge.value)})'
            : fetch == SharedSafetyFetchResult.unavailable
                ? '(取得不可)'
                : '';
        safetySettingsLabel.value = '安全設定: 共有 rev.${revision ?? "?"}$suffix';
        safetySettingsNeedsAttention.value =
            fetch != SharedSafetyFetchResult.fresh;
      case DangerZoneSettingsSource.local:
        safetySettingsLabel.value = '安全設定: この端末のみ';
        safetySettingsNeedsAttention.value = true;
      case DangerZoneSettingsSource.codeDefault:
      case null:
        safetySettingsLabel.value = '安全設定: 既定値';
        safetySettingsNeedsAttention.value = true;
    }
  }

  void captureAppliedDangerZoneSettings() {
    final resolution = presetObstacleService.lastDangerZoneSettingsResolution;
    if (resolution == null) return;
    dangerZoneSettingsSource.value = resolution.source;
    if (resolution.source == DangerZoneSettingsSource.shared) {
      appliedSharedSafetyRevision.value = resolution.sharedSafetyRevision;
    } else {
      appliedSharedSafetyRevision.value = null;
    }
    updateSafetySettingsStatus();
  }

  Map<String, dynamic> effectiveDangerZoneDiagnosticFields() {
    final settings =
        presetObstacleService.lastDangerZoneSettingsResolution?.settings;
    if (settings == null) return const <String, dynamic>{};
    return {
      for (final kind in DangerZoneKind.values) ...{
        'effective${kind.name[0].toUpperCase()}${kind.name.substring(1)}WaterSideMeters':
            settings[kind].waterSideMeters,
        'effective${kind.name[0].toUpperCase()}${kind.name.substring(1)}LandSideMeters':
            settings[kind].landSideMeters,
      },
    };
  }

  /// 直近60秒の測位到着から実効レートを求める。
  ///
  /// **平均だけでは判断できない。** 2026-08-05 の実機ログでは、間隔の
  /// 中央値が2000ms(過去は1000ms)で、そこへ8秒級の停止が262回混ざって
  /// いた。この2つは原因が違う(配信の間引きと、無通知停止)ので、
  /// 中央値と最大を別々に残す。
  Map<String, dynamic> positionRateSnapshot(Duration tick) {
    const window = Duration(seconds: 60);
    final arrivals = recentPositionArrivals.value;
    arrivals.removeWhere((at) => tick - at > window);
    if (arrivals.length < 2) {
      return {
        'positionCount60s': arrivals.length,
        'positionIntervalMedianMs': null,
        'positionIntervalMaxMs': null,
      };
    }
    final intervals = <int>[
      for (var index = 1; index < arrivals.length; index++)
        (arrivals[index] - arrivals[index - 1]).inMilliseconds,
    ]..sort();
    return {
      'positionCount60s': arrivals.length,
      'positionIntervalMedianMs': intervals[intervals.length ~/ 2],
      'positionIntervalMaxMs': intervals.last,
    };
  }

  void recordDiagnosticHeartbeatIfDue(int generation) {
    if (!isCurrentNavigation(generation)) return;
    final tick = safetyClock.value.elapsed;
    final previous = lastDiagnosticHeartbeatTick.value;
    if (previous != null && tick - previous < _diagnosticHeartbeatInterval) {
      return;
    }
    lastDiagnosticHeartbeatTick.value = tick;
    final now = DateTime.now();
    final lastGps = lastValidGpsAt.value;
    final lastSafetyEvaluationAge =
        safetyEvaluationLiveness.value.lastSafetyEvaluationAgeAt(tick);
    appendRuntimeDiagnostic('diagnostic_heartbeat', {
      'elapsedMs': tick.inMilliseconds,
      'pointCount': sessionPoints.value.length,
      'alertEventCount': sessionAlertEvents.value.length,
      'diagnosticEventCount': sessionDiagnosticEvents.value.length,
      'diagnosticEventDroppedCount': diagnosticEventDroppedCount.value,
      'alertEventDroppedCount': alertEventDroppedCount.value,
      'currentWarningCategory': currentWarning.value?.category,
      'audioIsPlaying': alert.isPlaying,
      'audioError': alert.error.value,
      'gpsQuality': gpsHealth.value.snapshot(now).quality.name,
      'gpsStreamRecovering': isGpsStreamRecovering.value,
      'imuFusionQuality': strokeRate.motion.value?.quality.name,
      'imuFusionConfidence': strokeRate.motion.value?.confidence,
      'distancePerStrokeMeters':
          strokeRate.motion.value?.distancePerStrokeMeters,
      'lastGpsAgeMs':
          lastGps == null ? null : now.difference(lastGps).inMilliseconds,
      'lastSafetyEvaluationAgeMs': lastSafetyEvaluationAge?.inMilliseconds,
      'ashoreLandSideDistanceMeters':
          lastAshoreState.value.landSideDistanceMeters,
      'ashoreReason': lastAshoreState.value.reason.name,
      'positionSharingState': positionSharingDiagnosticState.value,
      'pipelineUnresponsive': isPipelineUnresponsive.value,
      'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
      // 位置更新の実効レート。lifecycle・速度と同じ行で読めるようにする。
      ...positionRateSnapshot(tick),
      // 測位ポーリングの実績。stream の配信間引きをどれだけ埋められたか。
      'gpsPollSucceededCount': gpsPollSucceededCount.value,
      'gpsPollFailedCount': gpsPollFailedCount.value,
      // サーバー時計とのずれ。他艇の受理・棄却の判断根拠そのもの。
      'serverTimeOffsetMs': messageService.serverTimeOffsetMillis,
      'serverTimeOffsetUpdatedAt':
          messageService.serverTimeOffsetUpdatedAt?.toUtc().toIso8601String(),
      'serverTimeOffsetStatus': messageService.serverTimeOffsetUpdatedAt == null
          ? 'unavailable'
          : 'acquired',
      'receiveBackendType': messageService.receiveBackendType,
      'teamIdHash': sharedSafetyTeamIdHash.value,
      'localBoatIdHash': messageService.localBoatIdHash,
      'receivedPositionRecordCount': messageService.receivedPositionRecordCount,
      'acceptedPositionRecordCount': messageService.acceptedPositionRecordCount,
      'rejectedPositionRecordCount': messageService.rejectedPositionRecordCount,
      'lastPositionRecordReceivedAt': messageService
          .lastPositionRecordReceivedAt
          ?.toUtc()
          .toIso8601String(),
      'acceptedFutureTimestampRecordCount':
          messageService.acceptedFutureTimestampRecordCount,
      'maxAcceptedFutureTimestampSkewMs':
          messageService.maxAcceptedFutureTimestampSkewMillis,
      // バックグラウンド中に音声指示が出ていたか。提示層が描画に依存して
      // いた頃は、ここが伸び続けて再生要求がゼロのままだった。
      'audioDirectiveWhilePausedCount': audioDirectiveWhilePausedCount.value,
      'audioPresentationWhilePausedCount':
          audioPresentationWhilePausedCount.value,
    });
    scheduleAudioRouteSnapshot('diagnostic_heartbeat');
    recordGpsEnvironmentSnapshot('diagnostic_heartbeat', generation);
  }

  Future<SessionDiagnosticMetadata> loadSessionDiagnosticMetadata(
    NavConfig navConfig,
  ) async {
    var settingsSnapshot = <String, dynamic>{
      'diagnosticEventSchemaVersion': diagnosticEventSchemaVersion,
      'buildMode': kReleaseMode
          ? 'release'
          : kProfileMode
              ? 'profile'
              : 'debug',
      'warningTimeSeconds': warningTimeSeconds.value,
      'primaryWarningLeadSeconds': primaryWarningLeadTimeSeconds.value,
      'advanceWarningLeadSeconds': warningTimeSeconds.value,
      'strokeRateEnabled': navConfig.strokeRateEnabled,
      'imuFusion': {
        'enabled': navConfig.strokeRateEnabled,
        'navigationFusionEnabled': enableInertialNavigationFusion,
        'samplingHz': 1000 / spmSamplingMs,
        'navigationMinimumConfidence': imuNavigationMinimumConfidence,
        'navigationMaximumAgeMs': imuNavigationMaximumAge.inMilliseconds,
        'sensors': [
          'userAccelerometer',
          'accelerometerGravity',
          'gyroscope',
        ],
        'absolutePositionFromImuOnly': false,
      },
      'boatType': navConfig.boatType.name,
      'seatPosition': navConfig.seatPos.label,
      'locationAccuracy': navConfig.accuracy.name,
      'robustPositionFilterEnabled': enableRobustPositionFilter,
      'audioSessionPolicy': {
        'focus': 'mixWithOthers',
        'respectSilence': false,
        'stayAwake': true,
        'playerMode': 'mediaPlayer',
        'assets': warningAudioAssets,
      },
      'diagnosticCatalogVersion': diagnosticCatalogVersion,
      'diagnosticEventLimit': maxSessionDiagnosticEvents,
      'alertEventLimit': maxSessionAlertDiagnosticEvents,
      'diagnosticOrdering':
          'seq is shared across alerts.jsonl and events.jsonl',
    };
    try {
      // loadDefaultObstaclesで実際に採った値を使う。ここで端末内設定を
      // 再読込すると、共有値で生成した形状とmanifestの記録がずれてしまう。
      final resolvedDangerSettings =
          presetObstacleService.lastDangerZoneSettingsResolution;
      final dangerSettings = resolvedDangerSettings?.settings ??
          await dangerZoneSettingsService.load();
      final calibrations = await fixedObstacleCalibrationService.loadAll();
      final calibrationTargets =
          await presetObstacleService.loadCalibrationTargets();
      final rawProfile = Map<String, dynamic>.from(
        jsonDecode(
          await rootBundle.loadString(PresetObstacleService.presetAssetPath),
        ) as Map,
      );
      final calibrationSnapshot = [
        for (final entry in calibrations.entries)
          {
            'sourceId': entry.key,
            'northMeters': entry.value.northMeters,
            'eastMeters': entry.value.eastMeters,
          },
      ];
      final sourceSnapshot = [
        for (final target in calibrationTargets)
          {
            'sourceId': target.sourceId,
            'name': target.name,
            'kind': target.kind.name,
            'sourcePoints': [
              for (final point in target.sourcePoints)
                {
                  'lat': point.latitude,
                  'lng': point.longitude,
                },
            ],
          },
      ];
      settingsSnapshot = {
        ...settingsSnapshot,
        'dangerZoneOffsets': {
          for (final kind in DangerZoneKind.values)
            kind.name: {
              'waterSideMeters': dangerSettings[kind].waterSideMeters,
              'landSideMeters': dangerSettings[kind].landSideMeters,
            },
        },
        'dangerZoneSettingsSource':
            dangerZoneSettingsSource.value?.name ?? 'codeDefault',
        'sharedSafetyRevision': appliedSharedSafetyRevision.value,
        'sharedSafetyUpdatedAt': resolvedDangerSettings?.sharedSafetyUpdatedAt
            ?.toUtc()
            .toIso8601String(),
        'sharedSafetyCacheAgeMs': sharedSafetyCacheAge.value?.inMilliseconds,
        'sharedSafetyFetchResult': sharedSafetyFetchResult.value.name,
        'teamIdHash': sharedSafetyTeamIdHash.value,
        for (final kind in DangerZoneKind.values) ...{
          'effective${kind.name[0].toUpperCase()}${kind.name.substring(1)}WaterSideMeters':
              dangerSettings[kind].waterSideMeters,
          'effective${kind.name[0].toUpperCase()}${kind.name.substring(1)}LandSideMeters':
              dangerSettings[kind].landSideMeters,
        },
        'fixedObstacleCalibrations': calibrationSnapshot,
        'fixedObstacleCalibrationSources': sourceSnapshot,
        // ZIPのmanifestだけで、同梱元座標と実際に安全判定へ渡した
        // 補正・幅適用後ポリゴンの両方を再現できるよう航行開始時に固定する。
        'fixedObstacleProfile': {
          'assetPath': PresetObstacleService.presetAssetPath,
          'version': PresetObstacleService.expectedProfileVersion,
          'sha256': PresetObstacleService.expectedProfileSha256,
          'sourceProfile': rawProfile,
          'calibrations': calibrationSnapshot,
          'calibrationSources': sourceSnapshot,
          'effectiveObstacles': [
            for (final obstacle
                in defaultObstacles.value.where((item) => item.isDefault))
              {
                'id': obstacle.id,
                if (obstacle.sourceId != null) 'sourceId': obstacle.sourceId,
                if (obstacle.name != null) 'name': obstacle.name,
                'kind': obstacle.kind.name,
                'isManaged': obstacle.isManaged,
                if (obstacle.proximityCautionDistanceMeters != null)
                  'proximityCautionDistanceMeters':
                      obstacle.proximityCautionDistanceMeters,
                if (obstacle.warningAudioAsset != null)
                  'warningAudioAsset': obstacle.warningAudioAsset,
                'points': [
                  for (final point in obstacle.points)
                    {
                      'lat': point.latitude,
                      'lng': point.longitude,
                    },
                ],
              },
          ],
        },
      };
    } catch (error) {
      // 診断用スナップショットの失敗で航行開始を止めない。
      debugPrint('Failed to capture diagnostic settings: $error');
    }
    var appVersion = const String.fromEnvironment(
      'FLUTTER_BUILD_NAME',
      defaultValue: 'unknown',
    );
    var buildNumber = const String.fromEnvironment(
      'FLUTTER_BUILD_NUMBER',
      defaultValue: 'unknown',
    );
    try {
      final packageInfo =
          await PackageInfo.fromPlatform().timeout(_platformReadTimeout);
      if (packageInfo.version.isNotEmpty) appVersion = packageInfo.version;
      if (packageInfo.buildNumber.isNotEmpty) {
        buildNumber = packageInfo.buildNumber;
      }
    } catch (error) {
      // package infoが読めない場合も、compile-timeの値を使って航行は継続する。
      debugPrint('Failed to capture runtime app version: $error');
    }
    var operatingSystemVersion = 'unknown';
    try {
      final device = await deviceRuntimeDiagnostics
          .snapshot()
          .timeout(_platformReadTimeout);
      final systemName = device['systemName']?.toString();
      final systemVersion = device['systemVersion']?.toString();
      if (systemVersion != null && systemVersion.isNotEmpty) {
        operatingSystemVersion = systemName == null || systemName.isEmpty
            ? systemVersion
            : '$systemName $systemVersion';
      }
    } catch (error) {
      // OS取得は診断用。失敗しても航行開始を止めない。
      debugPrint('Failed to capture operating system version: $error');
    }
    return SessionDiagnosticMetadata(
      appVersion: appVersion,
      buildNumber: buildNumber,
      gitCommitSha: BuildProvenance.gitCommitSha,
      buildTimestampUtc: BuildProvenance.buildTimestampUtc,
      buildFlavor: BuildProvenance.configuredFlavor == 'unknown'
          ? BuildProvenance.buildMode
          : BuildProvenance.configuredFlavor,
      operatingSystemVersion: operatingSystemVersion,
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      hazardProfileVersion: PresetObstacleService.expectedProfileVersion,
      hazardProfileSha256: PresetObstacleService.expectedProfileSha256,
      settingsSnapshot: settingsSnapshot,
    );
  }

  Future<void> loadDefaultObstacles({
    bool refreshManagedHazards = false,
  }) async {
    try {
      final defaults = await presetObstacleService.loadPresets(
        refreshManagedHazards: refreshManagedHazards,
      );
      defaultObstacles.value = defaults;
      obstacles.value = [...defaults, ...temporaryObstacles.value];
      isStaticProfileUnavailable.value = defaults.isEmpty;
      appendRuntimeDiagnostic('bridge_piers_unplotted', {
        // 橋脚の未プロットは段階移行の進捗であり、航行faultではない。
        'bridgeIds': presetObstacleService.lastUnplottedBridgeIds,
      });
      for (final orphan in presetObstacleService.lastOrphanedBridgePiers) {
        // 孤児橋脚は有効にしつつ、親の桁も縮退警告として残す。
        appendRuntimeDiagnostic('bridge_pier_orphaned', orphan);
      }
      captureAppliedDangerZoneSettings();
      final centerlines = await presetObstacleService.loadChannelCenterlines();
      // 単一中心線だけは旧来の全体フォールバックにも使える。複数時は、
      // レーンのcenterlineIdを通さず適当な1本を選ぶと別水域へ誤投影する。
      final centerline =
          centerlines.length == 1 ? centerlines.values.single : null;
      channelCenterline.value = centerline;
      try {
        final lanes = await presetObstacleService.loadChannelLanes();
        final resolver = ChannelLaneResolver(
          lanes,
          centerlines: centerlines,
        );
        channelLaneResolver.value = resolver;
        appendRuntimeDiagnostic('channel_lanes_loaded', {
          'count': lanes.length,
          'mode': resolver.hasCompleteLaneSet
              ? (resolver.hasLinkedCenterlines
                  ? 'linked_centerline_polygon_containment'
                  : 'legacy_polygon_containment')
              : 'cross_sign_fallback',
        });
      } catch (error) {
        // レーン読込失敗で中心線・通常の安全評価まで失わない。
        channelLaneResolver.value = null;
        appendRuntimeDiagnostic('channel_lanes_unavailable', {
          'fallback': 'cross_sign',
          'error': error.toString(),
        });
      }
      final centerlineDerived =
          presetObstacleService.isChannelCenterlineDerivedFromShores;
      appendRuntimeDiagnostic('channel_centerline_loaded', {
        'available': centerlines.isNotEmpty,
        'count': centerlines.length,
        'ids': centerlines.keys.toList(growable: false),
        // 明示プロットか、岸からの暫定導出か。導出のままなら中州を貫通しうる。
        'source': centerlines.isEmpty
            ? 'none'
            : (centerlineDerived ? 'derived_from_shores' : 'explicit'),
        if (centerlines.isNotEmpty)
          'totalLengthMeters': centerlines.values
              .fold<double>(0, (sum, line) => sum + line.lengthMeters),
        if (centerlines.isNotEmpty)
          'totalPointCount': centerlines.values
              .fold<int>(0, (sum, line) => sum + line.pointCount),
      });
      if (centerlines.isEmpty) {
        appendRuntimeDiagnostic('centerline_missing', {
          'fallback': 'straight_line_prediction',
        });
      } else if (centerlineDerived) {
        appendRuntimeDiagnostic('centerline_derived_fallback', const {
          'reason': 'channelCenterline is not plotted in the bundled profile',
        });
      }
      // 陸上判定は明示プロットした陸上エリアだけを参照する。空でも起動し、
      // その場合は安全側として音を止めない（岸の向き・航路は参照しない）。
      final ashoreAreas = await presetObstacleService.loadAshoreAreas();
      ashoreDetector.value = AshoreDetector(
        ashoreAreas: ashoreAreas.map((area) => area.points).toList(),
      );
      isAshore.value = false;
      appendRuntimeDiagnostic('ashore_detector_loaded', {
        'areaCount': ashoreAreas.length,
        'segmentCount': ashoreDetector.value?.segmentCount ?? 0,
      });
      // 桟橋エリアは危険区域ではない。着艇で艇が並ぶ間、双方が低速のときの
      // 他艇警告の音だけを落とす。空でも全機能が従来どおり動く（原則1）。
      final mooringAreas = await presetObstacleService.loadMooringAreas();
      mooringAreaPolygons.value =
          mooringAreas.map((area) => area.points).toList(growable: false);
      appendRuntimeDiagnostic('mooring_areas_loaded', {
        'areaCount': mooringAreas.length,
      });
      final integrity = presetObstacleService.lastProfileIntegrity;
      if (integrity != null && !integrity.isFullyVerified) {
        // 形状は使い続けるが、検証状態は必ず記録する。versionの不一致は
        // 校正値を落とすため、共有安全設定の異常として画面へも出す。
        appendRuntimeDiagnostic(
          'hazard_profile_unverified',
          integrity.toJson(),
        );
        if (!integrity.mayApplyCalibrations) {
          isSharedSafetyCalibrationSyncUnavailable.value = true;
        }
      }
    } catch (e) {
      // 固定危険区域が読み込めない場合も、画面を落とさず明示的に記録する。
      debugPrint('Failed to load default obstacles: $e');
      isStaticProfileUnavailable.value = true;
      appendRuntimeDiagnostic('static_profile_load_failed', {
        'errorType': e.runtimeType.toString(),
      });
    }
  }

  /// 通常マップでも、追加済みの臨時危険区域を固定区域へ重ねて表示する。
  ///
  /// 航行・監視中は既存のlistenerが更新を反映しているため、余分なFirestore
  /// readを発生させない。通常時だけ、初回表示と編集画面からの復帰時に1回取得する。
  Future<void> refreshTemporaryObstaclesForMap() async {
    if (isWatching.value) return;
    try {
      final snapshot = await EnvService().getCurrentTemporaryObstacles();
      final temporary = List<StaticObstacle>.from(snapshot['obstacles'] ?? []);
      temporaryObstacles.value = temporary;
      obstacles.value = [...defaultObstacles.value, ...temporary];
      isTemporaryObstacleReceiveUnavailable.value = false;
    } catch (error) {
      // 通信失敗時も、直前の区域と固定危険区域を残して通常地図を継続する。
      isTemporaryObstacleReceiveUnavailable.value = true;
      debugPrint('Temporary obstacles refresh for map failed: $error');
    }
  }

  Future<void> reloadDefaultObstaclesForMap() async {
    await loadDefaultObstacles();
    await refreshTemporaryObstaclesForMap();
  }

  /// 航行中の明示確認済みの安全設定だけに使う、固定区域の原子的な更新。
  ///
  /// 新形状を最後まで作れなかった場合は [obstacles] を触らない。途中まで
  /// 生成した区域と旧区域を混ぜると、同じ設定変更の直後に警告境界が不連続に
  /// なってしまうためである。
  Future<bool> applyNavigationObstacleSettings({
    required String key,
    required Object? from,
    required Object? to,
    int? sharedRevision,
  }) async {
    if (mode.value != NavMode.navigator) return false;
    try {
      final nextDefaults = await presetObstacleService.loadPresets();
      final nextObstacles = <StaticObstacle>[
        ...nextDefaults,
        ...temporaryObstacles.value,
      ];

      // awaitの後に一度だけ差し替える。1Hzの安全評価が見るのは常に旧一式か
      // 新一式のどちらかで、部分的な固定区域集合にはならない。
      defaultObstacles.value = nextDefaults;
      obstacles.value = nextObstacles;
      isStaticProfileUnavailable.value = nextDefaults.isEmpty;
      captureAppliedDangerZoneSettings();
      if (sharedRevision != null) {
        // 自端末が公開したrevisionも、生成済みなら次のlistener通知で
        // 「未反映」と表示しないよう適用済みにする。
        sharedCalibrationSyncPolicy.markApplied(sharedRevision);
        pendingSharedSafetyRevision.value = null;
      }
      appendRuntimeDiagnostic('setting_changed_during_navigation', {
        'key': key,
        'from': from,
        'to': to,
      });
      return true;
    } catch (error) {
      // 直前の検証済み形状を残し、警告・記録・位置共有を止めない。
      debugPrint('Failed to apply navigation safety settings: $error');
      appendRuntimeDiagnostic('setting_change_apply_failed', {
        'key': key,
        'errorType': error.runtimeType.toString(),
      });
      return false;
    }
  }

  void scheduleSharedCalibrationApply(int generation) {
    sharedCalibrationCoalesceTimer.value?.cancel();
    sharedCalibrationCoalesceTimer.value = Timer(
      SharedCalibrationSyncPolicy.coalesceWindow,
      () async {
        if (generation != sharedCalibrationSyncGeneration.value ||
            !sharedCalibrationSyncPolicy.listenerAttached) {
          return;
        }
        if (sharedCalibrationApplyRunning.value) {
          scheduleSharedCalibrationApply(generation);
          return;
        }
        final revision = sharedCalibrationSyncPolicy.takePendingRevision();
        if (revision == null) return;
        if (mode.value == NavMode.navigator) {
          // 航行中に形状が黙って変わると、足元の危険境界と警告の意味が
          // 予告なしに変わる。新revisionは保持・表示し、明示操作だけで
          // 一括適用する(W6/W13)。
          pendingSharedSafetyRevision.value = revision;
          appendRuntimeDiagnostic('shared_safety_calibration_pending', {
            'revision': revision,
          });
          return;
        }
        sharedCalibrationApplyRunning.value = true;
        try {
          // 共有文書はwatchLatest受信時に端末cacheへ保存済み。
          // ここではFirebaseを再読込せず、cacheから全固定障害物を再構築する。
          final defaults = await presetObstacleService.loadPresets();
          final shared = await sharedSafetyCalibrationService.loadCached();
          if (generation != sharedCalibrationSyncGeneration.value ||
              !sharedCalibrationSyncPolicy.listenerAttached) {
            return;
          }
          defaultObstacles.value = defaults;
          obstacles.value = [...defaults, ...temporaryObstacles.value];
          isStaticProfileUnavailable.value = defaults.isEmpty;
          sharedCalibrationSyncPolicy.markApplied(revision);
          captureAppliedDangerZoneSettings();
          if (shared != null) {
            primaryWarningLeadTimeSeconds.value =
                shared.primaryWarningLeadSeconds;
            warningTimeSeconds.value = shared.advanceWarningLeadSeconds;
            safetyOrchestrator.value?.updatePresentationConfig(
              AlertPresentationConfig(
                continuousAudioDeadline: Duration(
                  milliseconds:
                      (shared.primaryWarningLeadSeconds * 1000).round(),
                ),
                intermittentAudioDeadline: Duration(
                  milliseconds:
                      (shared.advanceWarningLeadSeconds * 1000).round(),
                ),
              ),
            );
          }
          isSharedSafetyCalibrationSyncUnavailable.value = false;
          if (mode.value == NavMode.navigator) {
            appendDiagnosticEvent(SessionDiagnosticEvent(
              t: DateTime.now(),
              type: 'shared_safety_calibration_applied',
              details: {'revision': revision},
            ));
          }
        } catch (error) {
          // 直前の検証済み固定区域を残し、航行と1Hz安全評価は止めない。
          isSharedSafetyCalibrationSyncUnavailable.value = true;
          debugPrint(
            'Failed to apply shared safety calibration; '
            'keeping last-known obstacles: $error',
          );
          appendRuntimeDiagnostic('shared_safety_calibration_apply_failed', {
            'errorType': error.runtimeType.toString(),
            'revision': revision,
          });
        } finally {
          sharedCalibrationApplyRunning.value = false;
          if (generation == sharedCalibrationSyncGeneration.value &&
              sharedCalibrationSyncPolicy.pendingRevision != null) {
            scheduleSharedCalibrationApply(generation);
          }
        }
      },
    );
  }

  /// 航行中に通知された共有安全設定を、利用者の明示操作で一括反映する。
  ///
  /// 新旧のポリゴンを混ぜないため、全固定障害物の生成が成功してから一度に
  /// 差し替える。失敗時は直前の検証済み形状を保ち、航行・警告・記録・共有は
  /// 継続する。
  Future<void> applyPendingSharedSafetySettings() async {
    final revision = sharedCalibrationSyncPolicy.takePendingRevision() ??
        pendingSharedSafetyRevision.value;
    if (revision == null || sharedCalibrationApplyRunning.value) return;
    sharedCalibrationApplyRunning.value = true;
    try {
      final applied = await applyNavigationObstacleSettings(
        key: 'sharedSafetyRevision',
        from: appliedSharedSafetyRevision.value,
        to: revision,
      );
      if (!applied) {
        // takePendingRevision済みでも、次の明示操作で再試行できるよう戻す。
        sharedCalibrationSyncPolicy.observeRevision(revision);
        pendingSharedSafetyRevision.value = revision;
        return;
      }
      final shared = await sharedSafetyCalibrationService.loadCached();
      if (shared != null) {
        primaryWarningLeadTimeSeconds.value = shared.primaryWarningLeadSeconds;
        warningTimeSeconds.value = shared.advanceWarningLeadSeconds;
        safetyOrchestrator.value?.updatePresentationConfig(
          AlertPresentationConfig(
            continuousAudioDeadline: Duration(
              milliseconds: (shared.primaryWarningLeadSeconds * 1000).round(),
            ),
            intermittentAudioDeadline: Duration(
              milliseconds: (shared.advanceWarningLeadSeconds * 1000).round(),
            ),
          ),
        );
      }
      sharedCalibrationSyncPolicy.markApplied(revision);
      pendingSharedSafetyRevision.value = null;
      isSharedSafetyCalibrationSyncUnavailable.value = false;
      if (mode.value == NavMode.navigator) {
        appendDiagnosticEvent(SessionDiagnosticEvent(
          t: DateTime.now(),
          type: 'shared_safety_calibration_applied',
          details: {'revision': revision, 'explicit': true},
        ));
      }
    } catch (error) {
      // takePendingRevision済みでも再試行できるよう保持し直す。
      sharedCalibrationSyncPolicy.observeRevision(revision);
      pendingSharedSafetyRevision.value = revision;
      isSharedSafetyCalibrationSyncUnavailable.value = true;
      appendRuntimeDiagnostic('shared_safety_calibration_apply_failed', {
        'errorType': error.runtimeType.toString(),
        'revision': revision,
        'explicit': true,
      });
    } finally {
      sharedCalibrationApplyRunning.value = false;
    }
  }

  Future<void> startSharedCalibrationWatch() async {
    if (!sharedCalibrationSyncPolicy.beginListening()) return;
    final generation = ++sharedCalibrationSyncGeneration.value;
    try {
      await sharedCalibrationStreamSupervisor.start(
        streamFactory: sharedSafetyCalibrationService.watchLatest,
        onData: (state) {
          if (generation != sharedCalibrationSyncGeneration.value) return;
          final wasUnavailable = isSharedSafetyCalibrationSyncUnavailable.value;
          isSharedSafetyCalibrationSyncUnavailable.value = false;
          if (wasUnavailable) {
            appendRuntimeDiagnostic('shared_safety_calibration_recovered');
          }
          if (state == null ||
              !sharedCalibrationSyncPolicy.observeRevision(state.revision)) {
            return;
          }
          if (mode.value == NavMode.navigator) {
            pendingSharedSafetyRevision.value = state.revision;
            appendRuntimeDiagnostic('shared_safety_calibration_pending', {
              'revision': state.revision,
            });
            return;
          }
          // 5秒内に連続公開されても、最新revisionを一度だけ再構築する。
          scheduleSharedCalibrationApply(generation);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (generation != sharedCalibrationSyncGeneration.value) return;
          isSharedSafetyCalibrationSyncUnavailable.value = true;
          debugPrint(
            'Shared safety calibration listener failed; reconnecting: $error',
          );
          appendRuntimeDiagnostic('shared_safety_calibration_stream_error', {
            'errorType': error.runtimeType.toString(),
          });
        },
      );
    } catch (error) {
      if (generation == sharedCalibrationSyncGeneration.value) {
        sharedCalibrationSyncPolicy.endListening();
        isSharedSafetyCalibrationSyncUnavailable.value = true;
      }
      debugPrint('Failed to start shared safety calibration listener: $error');
      appendRuntimeDiagnostic('shared_safety_calibration_start_failed', {
        'errorType': error.runtimeType.toString(),
      });
    }
  }

  Future<void> stopSharedCalibrationWatch() async {
    sharedCalibrationSyncGeneration.value += 1;
    sharedCalibrationCoalesceTimer.value?.cancel();
    sharedCalibrationCoalesceTimer.value = null;
    sharedCalibrationSyncPolicy.endListening();
    await sharedCalibrationStreamSupervisor.stop();
    isSharedSafetyCalibrationSyncUnavailable.value = false;
  }

  Future<void> loadWarningTime({
    SharedSafetyCalibrationState? sharedSafety,
  }) async {
    try {
      final leadTimes = sharedSafety == null
          ? await riskEvaluatorSettingsService.loadWarningLeadTimes()
          : WarningLeadTimes(
              primaryWarningLeadSeconds: sharedSafety.primaryWarningLeadSeconds,
              advanceWarningLeadSeconds: sharedSafety.advanceWarningLeadSeconds,
            );
      primaryWarningLeadTimeSeconds.value = leadTimes.primaryWarningLeadSeconds;
      warningTimeSeconds.value = leadTimes.advanceWarningLeadSeconds;
    } catch (e) {
      // 設定を読み込めない場合も安全側のコード上のデフォルトで継続する。
      primaryWarningLeadTimeSeconds.value = primaryWarningLeadSeconds;
      warningTimeSeconds.value = defaultWarningTimeSeconds;
      debugPrint('Failed to load warning time setting: $e');
    }
    // `SafetyOrchestrator` は航行開始時のFSMを維持する。ここでFSMを
    // 作り直すと表示中の警告を消してしまうため、提示時間だけを更新する。
    safetyOrchestrator.value?.updatePresentationConfig(
      AlertPresentationConfig(
        continuousAudioDeadline: Duration(
          milliseconds: (primaryWarningLeadTimeSeconds.value * 1000).round(),
        ),
        intermittentAudioDeadline: Duration(
          milliseconds: (warningTimeSeconds.value * 1000).round(),
        ),
      ),
    );
  }

  /// 本警告・予告の保存後に、航行中の評価と提示へ即時反映する。
  Future<void> applyWarningLeadTimesDuringNavigation(
    WarningLeadTimes previous,
    int? sharedRevision,
  ) async {
    if (mode.value != NavMode.navigator) return;
    final shared = sharedRevision == null
        ? null
        : await sharedSafetyCalibrationService.loadCached();
    await loadWarningTime(sharedSafety: shared);
    if (sharedRevision != null) {
      sharedCalibrationSyncPolicy.markApplied(sharedRevision);
      pendingSharedSafetyRevision.value = null;
    }
    appendRuntimeDiagnostic('setting_changed_during_navigation', {
      'key': 'warningLeadTimes',
      'from': {
        'primaryWarningLeadSeconds': previous.primaryWarningLeadSeconds,
        'advanceWarningLeadSeconds': previous.advanceWarningLeadSeconds,
      },
      'to': {
        'primaryWarningLeadSeconds': primaryWarningLeadTimeSeconds.value,
        'advanceWarningLeadSeconds': warningTimeSeconds.value,
      },
      if (sharedRevision != null) 'sharedRevision': sharedRevision,
    });
  }

  Session? buildSessionSnapshot({
    required bool isComplete,
    DateTime? endedAt,
    SessionSummary? reuseSummary,
  }) {
    final startedAt = sessionStartedAt.value;
    if (startedAt == null || sessionPoints.value.isEmpty) return null;
    updateDiagnosticMetadataCounts();
    // JSON変換前のawait中に1Hz記録が追記されても、保存対象の
    // Listは変化しないようスナップショットを渡す。
    final points = List<TrackPoint>.unmodifiable(sessionPoints.value);
    return Session(
      id: startedAt.millisecondsSinceEpoch.toString(),
      startedAt: startedAt,
      endedAt: endedAt ?? DateTime.now(),
      boatTypeName: config.value?.boatType.name ?? '',
      seatPosLabel: config.value?.seatPos.label ?? '',
      points: points,
      // 途中チェックポイントでは解析をやり直さない。2時間の練習では
      // 7,000点の再解析が60秒ごとに走り、後半ほどCPUと電池を食う。
      // 完成版の保存時にだけ全点を解析する。
      summary: reuseSummary ??
          SessionAnalyzerService().analyze(
            points,
            boatTypeName: config.value?.boatType.name ?? '',
          ),
      isComplete: isComplete,
      diagnosticMetadata: sessionDiagnosticMetadata.value,
      alertEvents:
          List<AlertDiagnosticEvent>.unmodifiable(sessionAlertEvents.value),
      diagnosticEvents: List<SessionDiagnosticEvent>.unmodifiable(
          sessionDiagnosticEvents.value),
    );
  }

  late void Function() startSessionWriteDrain;
  startSessionWriteDrain = () {
    if (sessionWriteRunning.value || pendingSessionWrite.value == null) return;
    sessionWriteRunning.value = true;
    final future = Future<void>(() async {
      while (pendingSessionWrite.value != null) {
        final session = pendingSessionWrite.value!;
        pendingSessionWrite.value = null;
        try {
          await sessionStoreService.saveSession(session);
          appendRuntimeDiagnostic('session_checkpoint_saved', {
            'sessionId': session.id,
            'isComplete': session.isComplete,
            'pointCount': session.points.length,
            'diagnosticEventCount': session.diagnosticEvents.length,
          });
        } catch (error) {
          // GPS・警告処理を停めない。次のチェックポイントで
          // 同じIDのより新しいスナップショットを再保存する。
          debugPrint('Failed to checkpoint navigation session: $error');
          appendRuntimeDiagnostic('session_checkpoint_save_failed', {
            'sessionId': session.id,
            'errorType': error.runtimeType.toString(),
          });
        }
      }
    }).whenComplete(() {
      sessionWriteRunning.value = false;
      if (pendingSessionWrite.value != null) startSessionWriteDrain();
    });
    sessionWriteFuture.value = future;
  };

  void queueSessionWrite(Session session) {
    // 保存中に次の期限が来た場合は待ち行列を最新1件だけにする。
    pendingSessionWrite.value = session;
    startSessionWriteDrain();
  }

  Future<void> waitForSessionWrites() async {
    while (sessionWriteRunning.value || pendingSessionWrite.value != null) {
      startSessionWriteDrain();
      await sessionWriteFuture.value;
    }
  }

  void checkpointSessionIfDue(int generation) {
    if (!isCurrentNavigation(generation)) return;
    final tick = safetyClock.value.elapsed;
    final previous = lastSessionCheckpointTick.value;
    if (previous != null && tick - previous < _sessionCheckpointInterval) {
      return;
    }
    // 途中チェックポイントは異常終了からの復旧用。全点の再解析を毎分
    // やり直すと後半ほど重くなるため、要約は5分ごとにだけ作り直し、
    // 間は直前の要約を使い回す。完成版の保存では必ず解析する。
    final summaryTick = lastCheckpointSummaryTick.value;
    final reuseSummary = summaryTick != null &&
            tick - summaryTick < _checkpointSummaryRefreshInterval
        ? lastCheckpointSummary.value
        : null;
    // スナップショット生成は1回だけ(以前は同じものを2回作っていた)。
    final session = buildSessionSnapshot(
      isComplete: false,
      reuseSummary: reuseSummary,
    );
    if (session == null) return;
    if (reuseSummary == null) {
      lastCheckpointSummary.value = session.summary;
      lastCheckpointSummaryTick.value = tick;
    }
    lastSessionCheckpointTick.value = tick;
    appendRuntimeDiagnostic('session_checkpoint_queued', {
      'pointCount': session.points.length,
      'elapsedSec': tick.inMilliseconds / 1000,
      'summaryReused': reuseSummary != null,
    });
    queueSessionWrite(session);
  }

  void scheduleReceiveAccessProbe(int generation, {bool force = false}) {
    if (generation != navigationGeneration.value ||
        config.value == null ||
        navigationStopInProgress.value) {
      return;
    }
    if (dynamicReceiveAccessConfirmed.value ||
        receiveAccessProbeInFlight.value) {
      return;
    }
    final now = DateTime.now();
    final previous = lastReceiveAccessProbeAt.value;
    if (!force &&
        previous != null &&
        now.difference(previous) < const Duration(seconds: 30)) {
      return;
    }
    lastReceiveAccessProbeAt.value = now;
    receiveAccessProbeInFlight.value = true;
    final probeGeneration = ++receiveAccessProbeGeneration.value;
    queuePreSessionDiagnostic('dynamic_receive_access_probe_started');
    final probe = messageService.probeReceiveAccess();
    var failureLogged = false;
    // Future.timeoutはnativeのget()自体をcancelできない。時間切れは
    // 診断にだけ残し、元Futureの完了までin-flightを保って
    // 圏外の長時間航行で未完了getを30秒ごとに積まない。
    final timeoutTimer = Timer(const Duration(seconds: 3), () {
      if (probeGeneration != receiveAccessProbeGeneration.value ||
          generation != navigationGeneration.value ||
          config.value == null ||
          navigationStopInProgress.value) {
        return;
      }
      failureLogged = true;
      queuePreSessionDiagnostic('dynamic_receive_access_probe_failed', {
        'backendType': messageService.receiveBackendType,
        'errorType': 'TimeoutException',
      });
    });
    unawaited(probe.then<void>((_) {
      if (generation != navigationGeneration.value ||
          config.value == null ||
          navigationStopInProgress.value) {
        return;
      }
      dynamicReceiveAccessConfirmed.value = true;
      membershipReceiveProbeConfirmed.value = true;
      membershipAuthorization.value = SharingAuthorization.granted;
      queuePreSessionDiagnostic('dynamic_receive_access_probe_completed', {
        'backendType': messageService.receiveBackendType,
      });
    }, onError: (Object error, StackTrace _) {
      if (generation != navigationGeneration.value ||
          config.value == null ||
          navigationStopInProgress.value) {
        return;
      }
      // probeの失敗はストリーム再接続と端末内安全機能を
      // 止めない。timeout済みなら同じ失敗を二重記録しない。
      if (!failureLogged) {
        failureLogged = true;
        queuePreSessionDiagnostic('dynamic_receive_access_probe_failed', {
          'backendType': messageService.receiveBackendType,
          ..._positionSharingErrorDetails(error),
        });
      }
    }).whenComplete(() {
      timeoutTimer.cancel();
      if (probeGeneration == receiveAccessProbeGeneration.value) {
        receiveAccessProbeInFlight.value = false;
      }
    }));
  }

  /// Firebaseを使う位置共有・臨時危険区域の受信を開始する。
  /// 固定危険区域はこの前に端末内データから読み込まれている。
  Future<void> watchEnv() async {
    await Future.wait([
      dynamicObstacleStreamSupervisor.start(
        streamFactory: envService.getDynamicObstaclesStream,
        onData: (obstacles) {
          // FirestoreのonDataは空snapshotもサーバー読取りの証拠。
          // RTDBの空onDataには2秒fallbackによる合成イベントが
          // 含まれるため、明示probe成功または実レコード受信で確定する。
          if (!useRealtimeDatabaseForPositions ||
              (obstacles['receivedRecordCount'] as int? ?? 0) > 0) {
            dynamicReceiveAccessConfirmed.value = true;
            membershipReceiveProbeConfirmed.value = true;
            membershipAuthorization.value = SharingAuthorization.granted;
          } else {
            scheduleReceiveAccessProbe(navigationGeneration.value);
          }
          // 生の劣化フラグを保持するだけ。fault への昇格は1秒周期の
          // watchdog がデバウンスして決める(数秒のフラップで鳴らさない)。
          rawDynamicReceiveDegraded.value =
              obstacles['receiveDegraded'] as bool? ?? false;
          // 読めなかったレコードは fault の根拠にしない。件数だけ残す。
          final unreadable = obstacles['unreadableRecordCount'] as int? ?? 0;
          if (unreadable > 0) {
            appendRuntimeDiagnostic('dynamic_obstacle_records_unreadable', {
              'unreadable': unreadable,
              'received': obstacles['receivedRecordCount'] as int? ?? 0,
            });
          }
          // 個別レコードの拒否は通信経路の障害にしない。ただし次回の
          // 実機ログで原因を切り分けられるよう、匿名化済みの理由を残す。
          for (final fault in obstacles['recordFaults'] as List? ?? const []) {
            if (fault is RecordFault) {
              appendRuntimeDiagnostic(
                'other_boat_record_rejected',
                fault.toDiagnosticDetails(),
              );
            }
          }
          final List<Boat> boats = obstacles['boats'];
          final List<Message> logMessages =
              List<Message>.from(obstacles['logMessages'] ?? const []);
          receivedPracticeLogMessages.value = logMessages
              .where((message) => config.value != null
                  ? message.boatId != config.value!.boatId
                  : true)
              .toList(growable: false);
          otherBoats.value = boats
              .where((boat) => config.value != null
                  ? (boat.boatId != config.value!.boatId)
                  : true)
              .toList();
        },
        onError: (Object error, StackTrace stackTrace) {
          rawDynamicReceiveDegraded.value = true;
          debugPrint('Dynamic obstacle stream error; reconnecting: $error');
          appendRuntimeDiagnostic('dynamic_obstacle_stream_error', {
            'errorType': error.runtimeType.toString(),
          });
        },
      ),
      temporaryObstacleStreamSupervisor.start(
        streamFactory: () => EnvService().getTemporaryObstaclesStream(),
        onData: (obstacles_) {
          final wasUnavailable = isTemporaryObstacleReceiveUnavailable.value;
          isTemporaryObstacleReceiveUnavailable.value = false;
          if (wasUnavailable) {
            appendRuntimeDiagnostic('temporary_obstacle_stream_recovered');
          }
          final List<StaticObstacle> temporaryObs =
              obstacles_['obstacles'] ?? [];
          temporaryObstacles.value = temporaryObs;
          obstacles.value = [...defaultObstacles.value, ...temporaryObs];
        },
        onError: (Object error, StackTrace stackTrace) {
          isTemporaryObstacleReceiveUnavailable.value = true;
          debugPrint('Static obstacle stream error; reconnecting: $error');
          appendRuntimeDiagnostic('temporary_obstacle_stream_error', {
            'errorType': error.runtimeType.toString(),
          });
        },
      ),
    ]);
  }

  Future<void> stopRealtimeWatch() async {
    await dynamicObstacleStreamSupervisor.stop();
    await temporaryObstacleStreamSupervisor.stop();
    await stopSharedCalibrationWatch();
    otherBoats.value = [];
    receivedPracticeLogMessages.value = const [];
    temporaryObstacles.value = [];
    obstacles.value = defaultObstacles.value;
    isDynamicReceiveUnavailable.value = false;
    rawDynamicReceiveDegraded.value = false;
    dynamicReceiveAccessConfirmed.value = false;
    receiveAccessProbeInFlight.value = false;
    lastReceiveAccessProbeAt.value = null;
    receiveAccessProbeGeneration.value += 1;
    receiveFaultDebouncer.value.reset();
    isTemporaryObstacleReceiveUnavailable.value = false;
    pendingSharedSafetyRevision.value = null;
    isWatching.value = false;
  }

  Future<void> startWatching({
    bool refreshManagedHazards = true,
    bool navigationOwned = false,
  }) async {
    if (!navigationOwned &&
        (navigationStartInProgress.value || navigationStopInProgress.value)) {
      throw StateError('航行の開始・終了処理中です。完了後に再試行してください。');
    }
    if (isWatching.value) return;
    if (refreshManagedHazards || defaultObstacles.value.isEmpty) {
      await loadDefaultObstacles(
        refreshManagedHazards: refreshManagedHazards,
      );
    }
    await watchEnv();
    await startSharedCalibrationWatch();
    isWatching.value = true;
  }

  late void Function(
    RiskAssessment assessment,
    DateTime evaluatedAt,
    AlertDataQuality dataQuality,
  ) applySafetyAssessment;

  // 1秒ウォッチドッグの測位ポーリングから使う。実体は下で定義する
  // `enqueuePosition` と同じで、宣言順の都合で前方参照にしている。
  late void Function(Position position, int generation) enqueuePositionFromPoll;

  // 1秒ウォッチドッグの共有再試行から使う。同じく宣言順の都合。
  late Future<void> Function(int generation) retryPublishingSetupFromWatchdog;

  void applyCompletedSafetyAssessment(
    RiskAssessment assessment,
    DateTime evaluatedAt,
    AlertDataQuality dataQuality,
  ) {
    applySafetyAssessment(assessment, evaluatedAt, dataQuality);
    // watchdog用の空の評価はここを通さない。更新すると「GPSは来たが
    // 本来の衝突評価が終わらない」状態を自分で隠してしまう。
    safetyEvaluationLiveness.value.recordSafetyEvaluationCompleted(
      safetyClock.value.elapsed,
    );
  }

  void runGpsWatchdogTick() {
    final now = DateTime.now();
    // 他艇受信のfaultは、受信コールバックではなくこの1秒周期で確定させる。
    // ストリームが完全に沈黙すると onData が来ないため、イベント駆動の
    // デバウンスでは永久に確定しない。
    {
      final wasUnavailable = isDynamicReceiveUnavailable.value;
      isDynamicReceiveUnavailable.value = receiveFaultDebouncer.value.update(
        degradedNow: rawDynamicReceiveDegraded.value,
        at: now,
      );
      // 復旧の記録も、生の値ではなく確定後の遷移で出す。生の値で出すと
      // 実機ログのように数秒周期で315回記録されてしまう。
      if (wasUnavailable && !isDynamicReceiveUnavailable.value) {
        appendRuntimeDiagnostic('dynamic_obstacle_stream_recovered');
      }
    }
    if (mode.value == NavMode.navigator) {
      // 位置共有の「能力」を1秒周期で見る。
      //
      // 隻数は見ない。0隻は正常状態でもあり得る(最初に出艇した艇、
      // 他艇が全部上がった後)。「他艇がいない」と「他艇を受信できる状態を
      // 確認できない」を区別する(原則6)。
      //
      // 2026-08-06 実機ログ: 1台が2セッション118分ずっと unavailable の
      // まま走り、他艇を1隻も受信しなかったのに何も表示されなかった。
      final now_ = DateTime.now();
      final authorization = switch (publishingSetupFailureKind.value) {
        SharingFailureKind.permissionDenied => SharingAuthorization.denied,
        null => membershipAuthorization.value,
        _ => SharingAuthorization.unknown,
      };
      final capability = SharingCapability(
        // clear/onDisconnectだけでは他端末へ届く証拠にならない。
        // 初回の位置write ACK後に初めてpublish能力確認とする。
        publishSetupComplete: lastPositionPublishAckAt.value != null &&
            !isPositionSharingUnavailable.value,
        sinceLastPublishAck: lastPositionPublishAckAt.value == null
            ? null
            : now_.toUtc().difference(lastPositionPublishAckAt.value!),
        subscriptionConnected: dynamicReceiveAccessConfirmed.value &&
            !isDynamicReceiveUnavailable.value &&
            !rawDynamicReceiveDegraded.value,
        authorization: authorization,
        serverTimeOffsetAge: messageService.serverTimeOffsetUpdatedAt == null
            ? null
            : now_
                .toUtc()
                .difference(messageService.serverTimeOffsetUpdatedAt!),
        sinceLastRemoteUpdate:
            messageService.lastPositionRecordReceivedAt == null
                ? null
                : now_.toUtc().difference(
                      messageService.lastPositionRecordReceivedAt!,
                    ),
        rosterAvailable: membershipReceiveProbeConfirmed.value,
      );
      final wasUnconfirmed = isSharingCapabilityUnconfirmed.value;
      final unconfirmed = sharingCapabilityMonitor.update(capability, at: now_);
      isSharingCapabilityUnconfirmed.value = unconfirmed;
      if (unconfirmed != wasUnconfirmed) {
        appendRuntimeDiagnostic(
          unconfirmed
              ? 'sharing_capability_unconfirmed'
              : 'sharing_capability_confirmed',
          capability.toDiagnosticDetails(),
        );
      }

      // 送信の初期設定が失敗したままなら、原因に応じて再試行する。
      // permission-deniedは起動過渡状態も同じcodeになるため、
      // 連続3回で打ち切る有限確認だけ行う。
      final retryKind = publishingSetupFailureKind.value;
      if (retryKind != null &&
          retryKind.shouldRetry(publishingSetupRetryAttempt.value)) {
        final dueAt = publishingSetupNextRetryAt.value;
        if (dueAt == null) {
          publishingSetupNextRetryAt.value = now_.add(
            retryKind.backoffFor(publishingSetupRetryAttempt.value),
          );
        } else if (!now_.isBefore(dueAt)) {
          publishingSetupNextRetryAt.value = null;
          retryPublishingSetupFromWatchdog(navigationGeneration.value);
        }
      }
    }
    {
      final monotonicNow = safetyClock.value.elapsed;
      final liveness = safetyEvaluationLiveness.value.tick(monotonicNow);
      if (mode.value == NavMode.navigator) {
        if (liveness.timerStalled) {
          if (!safetyTimerStalled.value) {
            appendRuntimeDiagnostic('safety_timer_stalled', {
              'gapMs': liveness.timerGap!.inMilliseconds,
            });
          }
          safetyTimerStalled.value = true;
        } else {
          safetyTimerStalled.value = false;
        }
        if (liveness.evaluationStalled) {
          if (!safetyEvaluationStalled.value) {
            appendRuntimeDiagnostic('safety_evaluation_stalled', {
              'lastSafetyEvaluationAgeMs':
                  liveness.lastSafetyEvaluationAge?.inMilliseconds,
              // 閾値が測位間隔に追随して広がったのか、固定下限のままかを
              // 後から切り分けられるようにする。閾値だけ上げて R1(測位が
              // 0.4Hz しか出ていない問題)を隠さないための記録である。
              'effectiveThresholdMs':
                  liveness.effectiveEvaluationStallThreshold.inMilliseconds,
              'smoothedInputIntervalMs':
                  liveness.smoothedInputInterval?.inMilliseconds,
            });
          }
          safetyEvaluationStalled.value = true;
        } else {
          safetyEvaluationStalled.value = false;
        }

        if (liveness.timerStalled || liveness.evaluationStalled) {
          isPipelineUnresponsive.value = true;
          pipelineRecoveryTicks.value = 0;
          // Timer空白だけなら復帰後の数tickで既存どおり解除できる。
          // GPS入力がある評価停止は、実際に評価が完了するまで解除しない。
          pipelineRecoveryNeedsAssessment.value = liveness.evaluationStalled;
          applySafetyAssessment(
            RiskAssessment(level: CollisionRiskLevel.lv0),
            now,
            AlertDataQuality.unusable,
          );
        } else if (isPipelineUnresponsive.value) {
          // 評価処理の例外は、Timerが動いただけでは回復扱いにしない。
          // 少なくとも1回の正常な衝突評価を確認してから解除確認へ進む。
          if (!pipelineRecoveryNeedsAssessment.value) {
            pipelineRecoveryTicks.value += 1;
            if (pipelineRecoveryTicks.value >= 3) {
              isPipelineUnresponsive.value = false;
              appendRuntimeDiagnostic('safety_pipeline_recovered', {
                'recoveryTicks': pipelineRecoveryTicks.value,
              });
            }
          }
          // 異常警告を維持しつつ、古い物理警告の3秒切替も進める。
          applySafetyAssessment(
            RiskAssessment(level: CollisionRiskLevel.lv0),
            now,
            AlertDataQuality.unusable,
          );
        }
      }
      final health = gpsHealth.value.tick(now);
      recordGpsQualityIfChanged(health, now);
      final lastFix = lastValidGpsAt.value;
      if (mode.value != NavMode.navigator || lastFix == null) return;
      final gpsAge = now.difference(lastFix);
      // 契約は本番挙動を変更しないshadowである。fixがない間も保護集合が
      // 小さくならないことを1秒ウォッチドッグで観測し、違反だけを60秒ごと
      // に記録する。
      final staleSolution = conservativePositionEstimator.predict(
          elapsed: safetyClock.value.elapsed);
      final contractViolations = safetyContractMonitor.observe(
        ContractObservation(
          elapsed: safetyClock.value.elapsed,
          at: now,
          protectionRadiusMeters: staleSolution?.safetySet.boundingRadiusMeters,
          integrityState: positionIntegrityState.value.name,
          budget: staleSolution?.budget,
          previousBudget: lastProtectionBudget.value,
        ),
      );
      if (staleSolution != null) {
        lastProtectionBudget.value = staleSolution.budget;
      }
      for (final violation in contractViolations) {
        final lastAt = lastContractViolationAt.value[violation.contractId];
        if (lastAt == null ||
            safetyClock.value.elapsed - lastAt >= const Duration(seconds: 60)) {
          lastContractViolationAt.value = {
            ...lastContractViolationAt.value,
            violation.contractId: safetyClock.value.elapsed,
          };
          appendRuntimeDiagnostic('safety_contract_violation', {
            'contractId': violation.contractId,
            'severity': violation.severity.name,
            'detail': violation.detail,
          });
        }
      }

      // **stream が黙っていても、OS は測位を持っている。取りに行く。**
      //
      // 2026-08-05 の実機ログ2台で、無通知に対する `getCurrentPosition` は
      // 541回すべて成功し、得られた測位は 42〜64ms前の新しいものだった
      // (所要 2〜4ms)。推測航法で埋める前に、まず本物を取りに行く。
      // 根拠と閾値は `gpsPositionPollAfterSilence` のコメント。
      final pollAccuracy = config.value?.accuracy;
      if (pollAccuracy != null &&
          gpsAge >= gpsPositionPollAfterSilence &&
          !gpsPollInFlight.value) {
        final lastPoll = lastGpsPollAt.value;
        if (lastPoll == null ||
            now.difference(lastPoll) >= gpsPositionPollMinimumInterval) {
          lastGpsPollAt.value = now;
          gpsPollInFlight.value = true;
          final pollGeneration = navigationGeneration.value;
          unawaited(geoService
              .getCurrentPosition(pollAccuracy)
              .timeout(gpsPositionPollTimeout)
              .then((position) {
            if (!isCurrentNavigation(pollGeneration)) return;
            // stream が先に届けた測位より古い/同じものは流さない。
            // 同じ測位を二度通すと、速度飛び判定と記録が二重になる。
            final latest = lastValidGpsTimestamp.value;
            if (latest != null && !position.timestamp.isAfter(latest)) {
              appendRuntimeDiagnostic('gps_position_poll_skipped', {
                'reason': 'not_newer',
                'fixAgeMs': DateTime.now()
                    .difference(position.timestamp)
                    .inMilliseconds,
              });
              return;
            }
            gpsPollSucceededCount.value += 1;
            appendRuntimeDiagnostic('gps_position_poll_succeeded', {
              'gpsAgeMs': gpsAge.inMilliseconds,
              'accuracyMeters': _finiteOrNull(position.accuracy),
              'fixAgeMs':
                  DateTime.now().difference(position.timestamp).inMilliseconds,
            });
            enqueuePositionFromPoll(position, pollGeneration);
          }).catchError((Object error) {
            if (!isCurrentNavigation(pollGeneration)) return;
            gpsPollFailedCount.value += 1;
            // ポーリングの失敗は縮退経路の失敗であり、streamも推測航法も
            // 従来どおり続く。ここで警告経路を止めない(原則1)。
            appendRuntimeDiagnostic('gps_position_poll_failed', {
              'errorType': error.runtimeType.toString(),
              'gpsAgeMs': gpsAge.inMilliseconds,
            });
          }).whenComplete(() {
            gpsPollInFlight.value = false;
          }));
        }
      }

      // このティックで推測航法による評価を適用したか。
      //
      // **1ティックにつき安全評価は1回だけ適用する。** 推測航法の評価には
      // 脅威候補が入っており、GPS断の空評価には入っていない。両方を同じ
      // ティックで流すと、同じ警告が alerting→clearing を毎秒往復し、
      // 解除まで進むたびに音声エピソードが再武装して単発音が鳴り直す。
      // 2026-08-05 の実機ログでは、この往復が岸で100回・他艇で77回
      // 記録されていた(同一ミリ秒で alerting と clearing が並ぶ)。
      //
      // 推測航法の推定は「入力が無い」ではなく「劣化した入力がある」である。
      // 直後に空評価で「入力なし」と宣言するのは自己矛盾であり、
      // データ欠損を警告解除の根拠にしてはいけない(原則6)。
      // GPS断そのものは `buildSystemCandidates` の `gps_unavailable` と
      // `capabilities.gpsUsable` が従来どおり表現する(不変条件3)。
      var appliedAssessmentThisTick = false;
      if (enableRobustPositionFilter &&
          gpsAge >= gpsDeadReckoningStartAfter &&
          gpsAge <= gpsDeadReckoningMaximumDuration) {
        final predictionTick = safetyClock.value.elapsed;
        final previousPredictionTick = lastDeadReckoningPredictionTick.value;
        if (previousPredictionTick == null ||
            predictionTick - previousPredictionTick >=
                const Duration(milliseconds: 900)) {
          lastDeadReckoningPredictionTick.value = predictionTick;
          try {
            final motion = strokeRate.motion.value;
            final motionIsUsable = enableInertialNavigationFusion &&
                motion != null &&
                motion.confidence >= imuNavigationMinimumConfidence &&
                now.difference(motion.calculatedAt).abs() <=
                    imuNavigationMaximumAge;
            final conservativePrediction = primarySolution ==
                    PrimarySolution.conservative
                ? conservativePositionEstimator.predict(elapsed: predictionTick)
                : null;
            final estimate = primarySolution == PrimarySolution.advanced
                ? positionEstimator.predict(
                    elapsed: estimatorClock.resolvePrediction(predictionTick),
                    maxPredictionGap: gpsDeadReckoningMaximumDuration,
                    strokeRateSpm: strokeRate.spm.value,
                    motionSpeedMetersPerSecond: motionIsUsable
                        ? motion.fusedSpeedMetersPerSecond
                        : null,
                    motionHeadingDegrees:
                        motionIsUsable ? motion.fusedHeadingDegrees : null,
                    motionSpeedAccuracyMetersPerSecond: motionIsUsable
                        ? motion.fusedSpeedAccuracyMetersPerSecond
                        : null,
                  )
                : null;
            final previousBoat = myBoat.value;
            if ((estimate != null || conservativePrediction != null) &&
                previousBoat != null) {
              final predictedBoat = Boat(
                boatId: previousBoat.boatId,
                displayName: previousBoat.displayName,
                boatType: previousBoat.boatType,
                lat: conservativePrediction?.representativePoint.latitude ??
                    estimate!.latitude,
                lng: conservativePrediction?.representativePoint.longitude ??
                    estimate!.longitude,
                heading: conservativePrediction?.headingDegrees ??
                    estimate!.headingDegrees,
                speed: conservativePrediction?.speedMetersPerSecond ??
                    estimate!.speedMetersPerSecond,
                timestamp: now,
                battery: previousBoat.battery,
                accuracy: conservativePrediction?.uncertaintyMeters ??
                    estimate!.uncertaintyMeters,
                sessionId: previousBoat.sessionId,
                serverUpdatedAt: previousBoat.serverUpdatedAt,
              );
              final predictedOthers = otherBoats.value
                  .where((boat) {
                    final updatedAt = boat.serverUpdatedAt ?? boat.timestamp;
                    return now.difference(updatedAt).inMilliseconds <
                        boatPredictionTimeoutSeconds * 1000;
                  })
                  .map((boat) =>
                      evaluatorService.extrapolateToNow(boat, now: now))
                  .toList(growable: false);
              final predictionAssessment = evaluatorService.assessRisk(
                predictedBoat,
                predictedOthers,
                obstacles.value,
                warningTimeSeconds: warningTimeSeconds.value,
                centerline: channelCenterline.value,
                laneResolver: channelLaneResolver.value,
                ownPositionSet: conservativePrediction?.safetySet,
              );
              myBoat.value = predictedBoat;
              applySafetyAssessment(
                predictionAssessment,
                now,
                AlertDataQuality.degraded,
              );
              appliedAssessmentThisTick = true;
              appendRuntimeDiagnostic('gps_dead_reckoning_prediction', {
                'gpsAgeMs': gpsAge.inMilliseconds,
                'uncertaintyMeters':
                    conservativePrediction?.uncertaintyMeters ??
                        estimate!.uncertaintyMeters,
                'speedMetersPerSecond':
                    conservativePrediction?.speedMetersPerSecond ??
                        estimate!.speedMetersPerSecond,
                'imuAssisted': motionIsUsable,
                if (motionIsUsable) 'imuConfidence': motion.confidence,
                'otherBoatCount': predictedOthers.length,
              });
            }
          } catch (error) {
            // 任意の縮退経路の失敗で、GPS購読や通常警告を止めない。
            appendRuntimeDiagnostic('gps_dead_reckoning_failed', {
              'errorType': error.runtimeType.toString(),
            });
          }
        }
      }
      if (health.quality == GpsHealthQuality.unusable) {
        gpsLossAnnounced.value = true;
        clearAshoreForUnusableGps();
        // GPS断の間もFSMを1秒ごとに進める。物理警告は
        // 3秒でGPS異常警告へ切り替わり、無限に残らない。
        //
        // 推測航法がこのティックで評価済みなら、ここは流さない
        // (上のコメントの理由)。推測航法が続く上限は
        // `gpsDeadReckoningMaximumDuration`(5秒)なので、そこを過ぎれば
        // 必ずこの経路へ来て3秒の上限が働く。
        if (!appliedAssessmentThisTick) {
          applySafetyAssessment(
            RiskAssessment(level: CollisionRiskLevel.lv0),
            now,
            AlertDataQuality.unusable,
          );
        }
      }
    }
  }

  void startGpsWatchdog() {
    gpsWatchdog.value?.cancel();
    gpsWatchdog.value = Timer.periodic(const Duration(seconds: 1), (_) {
      // Timer.periodic はcallbackが例外を投げても次回以降も発火するため
      // 警告が永久停止することはないが、原因調査のために必ず記録する。
      try {
        runGpsWatchdogTick();
      } catch (error, stackTrace) {
        debugPrint('GPS watchdog tick failed: $error\n$stackTrace');
        try {
          appendRuntimeDiagnostic('gps_watchdog_tick_error', {
            'errorType': error.runtimeType.toString(),
          });
        } catch (_) {
          // 診断の記録失敗でwatchdogを止めない。
        }
      }
    });
  }

  List<AlertCandidate> buildSystemCandidates(DateTime now) {
    final observationId = 'system:${now.toUtc().microsecondsSinceEpoch}';
    // system fault はすべて画面表示だけ。候補・banner・runModeは即時に
    // 維持し、GPS・通信・評価停止が物理的な衝突警告の音声を妨げない。
    AlertCandidate fault({
      required String detectorId,
      required String category,
      String? audioAsset,
      AlertDataQuality dataQuality = AlertDataQuality.good,
      int internalPriority = 0,
    }) =>
        AlertCandidate.stable(
          detectorId: detectorId,
          category: category,
          behavior: AlertBehavior.persistentSystemFault,
          evaluatedAt: now,
          observationId: observationId,
          actionDeadline: Duration.zero,
          dataQuality: dataQuality,
          internalPriority: internalPriority,
          audioAsset: audioAsset,
        );

    final gpsUnusableNow =
        gpsHealth.value.snapshot(now).quality == GpsHealthQuality.unusable;
    final pipelineUnresponsiveNow = isPipelineUnresponsive.value;

    return [
      if (gpsUnusableNow)
        fault(
          detectorId: 'gps_health',
          category: 'gps_unavailable',
          audioAsset: null,
        ),
      // 以下の通信・データ系は表示のみ。漕ぎながら対処できない情報を
      // 読み上げても集中を削るだけで、本当に鳴るべき衝突警告を
      // 覆い隠す(原則4)。表示・バナー・runMode は従来どおり残る(原則1)。
      if (isPositionSharingUnavailable.value)
        fault(
          detectorId: 'position_sharing',
          category: 'position_sharing_unavailable',
          audioAsset: null,
        ),
      if (isDynamicReceiveUnavailable.value)
        fault(
          detectorId: 'other_boat_receive',
          category: 'other_boat_receive_unavailable',
          audioAsset: null,
        ),
      if (isStaticProfileUnavailable.value)
        fault(
          detectorId: 'static_profile',
          category: 'static_profile_unavailable',
          audioAsset: null,
        ),
      if (alert.error.value != null)
        fault(
          detectorId: 'audio_health',
          category: 'audio_unavailable',
          audioAsset: null,
        ),
      if (pipelineUnresponsiveNow)
        fault(
          detectorId: 'pipeline_watchdog',
          category: 'pipeline_unresponsive',
          audioAsset: null,
        ),
    ];
  }

  applySafetyAssessment = (
    RiskAssessment assessment,
    DateTime wallClockNow,
    AlertDataQuality dataQuality,
  ) {
    final orchestrator = safetyOrchestrator.value;
    if (orchestrator == null || mode.value != NavMode.navigator) return;
    // FSMの時間判定は端末時計の補正・逆行の影響を受けない。
    final evaluatedAt = safetyClockOrigin.value.add(safetyClock.value.elapsed);
    final result = orchestrator.processAssessment(
      assessment: assessment,
      evaluatedAt: evaluatedAt,
      dataQuality: dataQuality,
      ownSpeedMetersPerSecond: myBoat.value?.speed,
      ownPosition: myBoat.value == null
          ? null
          : LatLng(myBoat.value!.lat, myBoat.value!.lng),
      // 桟橋での静音は「双方が低速」でだけ成立する。速度が取れない艇は
      // 抑制対象にしない(原則6)ため、取れたものだけを渡す。
      otherBoatSpeedById: {
        for (final boat in otherBoats.value) boat.boatId: boat.speed,
      },
      capabilities: CapabilitySnapshot(
        gpsUsable: gpsHealth.value.snapshot(wallClockNow).quality !=
            GpsHealthQuality.unusable,
        staticProfileUsable: !isStaticProfileUnavailable.value,
        audioUsable: alert.error.value == null,
        dynamicReceiveUsable: !isDynamicReceiveUnavailable.value,
        positionSharingUsable: !isPositionSharingUnavailable.value,
        pipelineResponsive: !isPipelineUnresponsive.value,
      ),
      systemCandidates: buildSystemCandidates(evaluatedAt),
      detectorHealth: [
        DetectorHealth(
          detectorId: 'gps_health',
          quality: dataQuality,
          lastSuccessAt: lastValidGpsAt.value,
        ),
      ],
      unknownBoatIds: otherBoats.value
          .where((boat) {
            final updatedAt = boat.serverUpdatedAt ?? boat.timestamp;
            final age = wallClockNow.difference(updatedAt);
            return age >=
                    const Duration(seconds: boatPredictionTimeoutSeconds) &&
                age <= const Duration(seconds: boatStaleTimeoutSeconds);
          })
          .map((boat) => boat.boatId)
          .toSet(),
      healthyBoatIds: otherBoats.value
          .where((boat) {
            final updatedAt = boat.serverUpdatedAt ?? boat.timestamp;
            return wallClockNow.difference(updatedAt) <
                const Duration(seconds: boatPredictionTimeoutSeconds);
          })
          .map((boat) => boat.boatId)
          .toSet(),
      boatDataQualityById: {
        for (final boat in otherBoats.value)
          boat.boatId: () {
            final updatedAt = boat.serverUpdatedAt ?? boat.timestamp;
            final age = wallClockNow.difference(updatedAt);
            if (age >= const Duration(seconds: boatPredictionTimeoutSeconds)) {
              return AlertDataQuality.unusable;
            }
            return age >= OtherBoatTrackStore.freshUntil
                ? AlertDataQuality.degraded
                : AlertDataQuality.good;
          }(),
      },
    );
    if (!safetySnapshotGate.value.accept(result.snapshot)) return;
    recordSafetyDiagnostics(result);
    safetyRunMode.value = result.snapshot.runMode;
    activeWarningCount.value = result.snapshot.activeAlerts.length;
    activeWarnings.value = navigationWarningService.fromCandidates(
      result.snapshot.activeAlerts.map((alert) => alert.candidate),
    );
    final primary = result.state.primaryAlert?.candidate;
    currentWarning.value = navigationWarningService.fromCandidate(primary);
    final directive = result.snapshot.audioDirective;
    audioDirective.value = directive;
    // 診断ログのカテゴリは、表示primaryではなく**鳴っている音**のものにする。
    // 音声チャンネルを表示から分離した以上、両者は別の警告になりうる。
    audioDirectiveCategory.value = directive == null
        ? null
        : result.snapshot.activeAlerts
            .map((alert) => alert.candidate)
            .where((candidate) => candidate.alertId == directive.alertId)
            .map((candidate) => candidate.category)
            .firstOrNull;

    // **音の提示はここで直接行う。ウィジェットの再構築を待たない。**
    //
    // 以前は `useEffect` に置いていたが、`useEffect` は build の一部として
    // 走る。iOS はアプリが `paused` の間フレームを回さないため、
    // 判定が「鳴らせ」を出しても実行されなかった(2026-08-05 実機ログ:
    // 96回の指示に対し再生要求1回)。詳細は `WarningPresenter`。
    final paused =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden;
    if (paused && directive != null) {
      audioDirectiveWhilePausedCount.value += 1;
    }
    final playbackRequested = warningPresenter.value.apply(
      directive,
      ashore: isAshore.value,
      category: audioDirectiveCategory.value,
    );
    if (paused && directive != null && playbackRequested) {
      audioPresentationWhilePausedCount.value += 1;
    }

    // 単発の合図(橋・カーブ・逆走・視覚優先のsystem fault)は、
    // 持続音とは別チャンネルで即座に鳴らす。orchestrator が eventId を
    // 一度しか発行しないため、毎ティック呼んでも重複しない
    // (`playCue` 側でも eventId で重複排除する二重防御)。
    // 陸上判定中は鳴らさない。
    if (!isAshore.value) {
      for (final cue in result.snapshot.oneShotAudioCues) {
        unawaited(alert.playCue(cue.asset, eventId: cue.eventId));
      }
    }

    final internalLevel = primary?.internalPriority ?? 0;
    safetyLevel.value = _safetyLevelFrom(
      CollisionRiskLevel.values[
          internalLevel.clamp(0, CollisionRiskLevel.values.length - 1).toInt()],
    );
  };

  void reportPipelineFailure(Object error, int generation) {
    if (!isCurrentNavigation(generation)) return;
    final now = DateTime.now();
    isPipelineUnresponsive.value = true;
    pipelineRecoveryNeedsAssessment.value = true;
    pipelineRecoveryTicks.value = 0;
    debugPrint('Safety pipeline processing error: $error');
    appendDiagnosticEvent(SessionDiagnosticEvent(
      t: now,
      type: 'safety_pipeline_error',
      details: {'errorType': error.runtimeType.toString()},
    ));
    try {
      applySafetyAssessment(
        RiskAssessment(level: CollisionRiskLevel.lv0),
        now,
        AlertDataQuality.unusable,
      );
    } catch (secondaryError) {
      // 単一writer自体の例外は握り潰さず診断へ残す。ただし、GPS購読を
      // 終了させて以後の復旧機会まで失うことは避ける。
      debugPrint('Failed to publish pipeline fault: $secondaryError');
    }
  }

  /// 品質確認済みのGNSSとKalman推定から自艇を構築する。
  /// 低速時も端末の向き（磁北）は使わず、最後の進行方位を保持する。
  /// 推定失敗時は [estimate] がnullとなり、従来のGNSS経路へ戻る。
  Boat buildMyBoat(
    Position rawPos,
    RobustPositionEstimate? estimate,
    RowingMotionMetrics? motion,
  ) {
    final previous = preRawPos.value;
    final elapsedSeconds = previous == null
        ? 0.0
        : rawPos.timestamp.difference(previous.timestamp).inMilliseconds / 1000;
    final movedMeters =
        previous == null ? 0.0 : getDistanceBetween(previous, rawPos);

    final rawSpeed = rawPos.speed.isFinite && rawPos.speed >= 0
        ? rawPos.speed
        : elapsedSeconds > 0
            ? movedMeters / elapsedSeconds
            : 0.0;
    // 速度は入口で有限性を保証する。[Boat] は位置共有・練習ログ・UIの全経路へ
    // 流れ、消費側には `500 ~/ speed`(home_map_screen の残り距離表示)のように
    // 非有限値で例外になるものがある。そこで落ちると航行画面のbuildごと失敗し、
    // 地図・警告バナー・計器・終了ボタンがまとめて消える(原則1: 機能を止めない)。
    // 消費側ごとに防ぐのではなく、生成点で潰す。rawPos.speed / accuracy の扱いや
    // `_usableBoat` / `normalizeBearing` と流儀を揃える。
    final speedCandidate = estimate?.speedMetersPerSecond ?? rawSpeed;
    final speed_ = speedCandidate.isFinite ? speedCandidate : 0.0;

    var heading_ = preHeading.value ?? 0.0;
    double? measuredHeading;
    // Kalman推定の方位は共分散で平滑化済み。さらに0.5でブレンドすると
    // 1Hzの一次遅れが二重にかかり、定常旋回で「1ステップぶんの旋回角」が
    // そのまま遅れになる(10°/sの旋回で約10°、5m/s・10秒先の予測で終端8.7m)。
    // 推定器由来のときは追加の平滑化を掛けない。
    var headingBlendWeight = _rawHeadingBlendWeight;
    // accuracy全量を閾値にすると低速艇で永遠に更新できないため、
    // 1.5〜3mの範囲でGPS揺れより明確な移動だけを採用する。
    final courseDistanceThreshold =
        (rawPos.accuracy * 0.5).clamp(1.5, 3.0).toDouble();
    if (estimate != null &&
        speed_ >= stoppedSpeedThreshold &&
        estimate.headingDegrees.isFinite) {
      measuredHeading = estimate.headingDegrees;
      headingBlendWeight = _estimatedHeadingBlendWeight;
    } else if (previous != null &&
        elapsedSeconds > 0 &&
        movedMeters >= courseDistanceThreshold) {
      measuredHeading = getHeading(
        LatLng(previous.latitude, previous.longitude),
        LatLng(rawPos.latitude, rawPos.longitude),
      );
    } else if (rawSpeed >= stoppedSpeedThreshold &&
        rawPos.heading.isFinite &&
        rawPos.heading >= 0 &&
        rawPos.heading < 360) {
      measuredHeading = rawPos.heading;
    }
    if (measuredHeading != null) {
      heading_ = _blendHeading(
        heading_,
        measuredHeading,
        weight: headingBlendWeight,
      );
    }
    final sourcePosition = estimate == null
        ? LatLng(rawPos.latitude, rawPos.longitude)
        : LatLng(estimate.latitude, estimate.longitude);
    final offset = Boat.getSeatOffset(
      config.value!.boatType,
      config.value!.seatPos,
    );
    final position = FlutterMapMath.destinationPoint(
      sourcePosition.latitude,
      sourcePosition.longitude,
      -offset,
      heading_,
    );
    // 移動距離も推定軌跡から積算し、停止中のGPS揺れを抑える。
    final previousPosition = previousEstimatedPosition.value;
    if (previousPosition != null && speed_ >= stoppedSpeedThreshold) {
      final coordinateDistance = Geolocator.distanceBetween(
        previousPosition.latitude,
        previousPosition.longitude,
        sourcePosition.latitude,
        sourcePosition.longitude,
      );
      totalDistance.value += distanceIntegrator.add(
        timestamp: rawPos.timestamp,
        coordinateDistanceMeters: coordinateDistance,
        speedMetersPerSecond: speed_,
        motionConfidence: motion?.confidence,
        moving: true,
      );
    } else {
      distanceIntegrator.add(
        timestamp: rawPos.timestamp,
        coordinateDistanceMeters: 0,
        speedMetersPerSecond: speed_,
        motionConfidence: motion?.confidence,
        moving: false,
      );
    }
    previousEstimatedPosition.value = sourcePosition;
    preRawPos.value = rawPos; // 地理座標から方位角を算出する場合に使用するため保存
    preHeading.value = heading_; // 艇情報として使用する方位角を保存
    // 安全マージンの根拠になる値。フィルタが収束したぶんは反映するが、
    // 無制限に楽観的にはならない: `uncertaintyMeters` は推定器側で
    // 「報告accuracyの0.5倍」と「絶対下限3m」の大きい方で床が入っている
    // (`RobustPositionEstimator.minimumUncertaintyFractionOfReported` /
    // `uncertaintyFloorMeters`)。推定が無い場合だけ生accuracyへ戻る。
    final accuracy_ = estimate?.uncertaintyMeters ??
        ((rawPos.accuracy.isFinite && rawPos.accuracy > 0)
            ? rawPos.accuracy
            : null);
    return Boat(
      boatId: config.value!.boatId, // 自艇のID
      displayName: config.value!.displayName,
      boatType: config.value!.boatType, // 自艇のtype
      lat: position.latitude,
      lng: position.longitude,
      heading: heading_,
      speed: speed_,
      timestamp: rawPos.timestamp,
      accuracy: accuracy_,
    );
  }

  /// 位置情報が更新されるたびに呼ばれるメイン処理。
  /// リスク評価と記録は毎回(≒毎秒)行い、送信だけを適応的に間引く。
  Future<void> processPosition(
    Position rawPos,
    int generation, {
    GpsHealthQuality? acceptedFixQuality,
  }) async {
    if (!isCurrentNavigation(generation)) return;
    final now = DateTime.now();
    final processingStopwatch = Stopwatch()..start();
    final processTick = safetyClock.value.elapsed;
    // 安全評価は、入口のfix時刻ポリシーで採用された全fixについて実行する。
    // 到着時刻での900msゲートは、OSのまとめ配信時に新しいfixを捨てるため禁止。
    lastProcessedTick.value = processTick;
    final previousProcessedAt = lastProcessedWallClock.value;
    if (previousProcessedAt != null) {
      final processingGap = now.difference(previousProcessedAt);
      final lastGapDiagnostic = lastDiagnosticPositionGapAt.value;
      if (processingGap >= const Duration(milliseconds: 2500) &&
          (lastGapDiagnostic == null ||
              now.difference(lastGapDiagnostic) >=
                  const Duration(seconds: 5))) {
        appendRuntimeDiagnostic('position_processing_gap', {
          'gapMs': processingGap.inMilliseconds,
          'expectedIntervalMs': positionUpdateInterval * 1000,
        });
        lastDiagnosticPositionGapAt.value = now;
      }
    }
    lastProcessedWallClock.value = now;

    // ######## Update MyBoat Status ########
    preProcessTime.value = now;
    RobustPositionEstimate? estimate;
    var estimatorDurationMs = 0;
    if (enableRobustPositionFilter) {
      final estimatorStartedAt = processingStopwatch.elapsed;
      try {
        final rawSpeed =
            rawPos.speed.isFinite && rawPos.speed >= 0 ? rawPos.speed : null;
        // 停止速度は方位に依存しないため0度として速度0の観測を活かす。
        // 低速移動中の不安定なcourse-over-groundは速度更新に混ぜない。
        final rawHeading = rawSpeed != null && rawSpeed <= 0.05
            ? 0.0
            : rawPos.heading.isFinite &&
                    rawPos.heading >= 0 &&
                    rawPos.heading < 360 &&
                    (rawSpeed ?? 0) >= stoppedSpeedThreshold
                ? rawPos.heading
                : null;
        if (rawSpeed != null) {
          strokeRate.observeGnss(
            timestamp: rawPos.timestamp,
            speedMetersPerSecond: rawSpeed,
            accuracyMeters: rawPos.accuracy,
            headingDegrees: rawHeading,
          );
        }
        final motion = strokeRate.motion.value;
        final motionIsUsable = enableInertialNavigationFusion &&
            motion != null &&
            motion.quality != RowingMotionQuality.unavailable &&
            motion.confidence >= imuNavigationMinimumConfidence &&
            now.difference(motion.calculatedAt).abs() <=
                imuNavigationMaximumAge;
        final observedSpeed =
            motionIsUsable ? motion.fusedSpeedMetersPerSecond : rawSpeed;
        final observedHeading = motionIsUsable
            ? motion.fusedHeadingDegrees ?? rawHeading
            : rawHeading;
        final candidate = positionEstimator.update(
          latitude: rawPos.latitude,
          longitude: rawPos.longitude,
          accuracyMeters: rawPos.accuracy,
          elapsed: estimatorClock.resolve(
            fixTimestamp: rawPos.timestamp,
            processElapsed: processTick,
          ),
          speedMetersPerSecond: observedSpeed,
          headingDegrees: observedHeading,
          speedAccuracyMetersPerSecond: motionIsUsable
              ? motion.fusedSpeedAccuracyMetersPerSecond
              : rawPos.speedAccuracy.isFinite && rawPos.speedAccuracy > 0
                  ? rawPos.speedAccuracy
                  : null,
          headingAccuracyDegrees:
              rawPos.headingAccuracy.isFinite && rawPos.headingAccuracy > 0
                  ? rawPos.headingAccuracy
                  : null,
          // ストローク内の艇速振動は1Hzでは分解できない未モデル化外乱。
          // SPMが取れているときだけ、その周波数をノイズ設計へ反映する。
          strokeRateSpm: strokeRate.spm.value,
        );
        // 従来はフィルタ後の不確実性が生accuracyを下回ることを禁じていたが、
        // それでは収束の利得が安全マージンへ一切反映されない。代わりに
        // 「推定位置が生fixから極端に離れていない」ことを発散検出として使う。
        final divergenceLimit = math.max(
          minEstimateDivergenceLimitMeters,
          (rawPos.accuracy.isFinite ? rawPos.accuracy : 0) * 5,
        );
        final divergenceMeters = candidate == null
            ? 0.0
            : Geolocator.distanceBetween(
                rawPos.latitude,
                rawPos.longitude,
                candidate.latitude,
                candidate.longitude,
              );
        if (candidate != null &&
            candidate.latitude.isFinite &&
            candidate.longitude.isFinite &&
            candidate.speedMetersPerSecond.isFinite &&
            candidate.headingDegrees.isFinite &&
            candidate.uncertaintyMeters.isFinite &&
            candidate.uncertaintyMeters > 0 &&
            divergenceMeters.isFinite &&
            divergenceMeters <= divergenceLimit) {
          estimate = candidate;
        } else if (candidate != null) {
          positionEstimator.reset();
          conservativePositionEstimator.reset();
          estimatorClock.reset();
          lastDeadReckoningPredictionTick.value = null;
          debugPrint('Position estimator produced an unusable result; reset.');
          appendRuntimeDiagnostic('position_estimator_reset', {
            'reason': divergenceMeters > divergenceLimit
                ? 'divergence'
                : 'unusable_estimate',
            'divergenceMeters': divergenceMeters,
            'divergenceLimitMeters': divergenceLimit,
            'uncertaintyMeters': candidate.uncertaintyMeters,
          });
        }
      } catch (error) {
        // 推定器の問題で警告処理全体を止めず、このfixだけGNSS値へ戻す。
        positionEstimator.reset();
        conservativePositionEstimator.reset();
        estimatorClock.reset();
        lastDeadReckoningPredictionTick.value = null;
        debugPrint('Position estimator failed and was reset: $error');
        appendRuntimeDiagnostic('position_estimator_reset', {
          'reason': 'exception',
          'errorType': error.runtimeType.toString(),
        });
      }
      estimatorDurationMs =
          (processingStopwatch.elapsed - estimatorStartedAt).inMilliseconds;
    }
    final conservativeResult = conservativePositionEstimator.update(
      fix: ConservativeFix(
        position: LatLng(rawPos.latitude, rawPos.longitude),
        timestamp: rawPos.timestamp,
        elapsed: processTick,
        accuracyMeters: rawPos.accuracy,
        speedMetersPerSecond: _finiteOrNull(rawPos.speed),
        headingDegrees: _finiteOrNull(rawPos.heading),
      ),
    );
    final conservative = conservativeResult.output;
    final selectedEstimate =
        primarySolution == PrimarySolution.conservative && conservative != null
            ? RobustPositionEstimate(
                latitude: conservative.representativePoint.latitude,
                longitude: conservative.representativePoint.longitude,
                speedMetersPerSecond: conservative.speedMetersPerSecond,
                headingDegrees: conservative.headingDegrees,
                reportedAccuracyMeters: rawPos.accuracy,
                covarianceUncertaintyMeters: conservative.uncertaintyMeters,
                uncertaintyMeters: conservative.uncertaintyMeters,
                innovationMeters: 0,
                disposition: PositionEstimateDisposition.accepted,
              )
            : estimate;
    final boatBuildStartedAt = processingStopwatch.elapsed;
    final latestMyBoat = buildMyBoat(
      rawPos,
      selectedEstimate,
      enableInertialNavigationFusion ? strokeRate.motion.value : null,
    );
    final boatBuildDurationMs =
        (processingStopwatch.elapsed - boatBuildStartedAt).inMilliseconds;
    if (!isCurrentNavigation(generation)) return;
    postProcessTime.value = DateTime.now();
    myBoat.value = latestMyBoat;

    // S0(raw) / S1(advanced) / S2(conservative) を並列に残す。S2の
    // 代表点は生fixなので、位置を前方へ外挿しない。
    final advancedLatitude = estimate?.latitude ?? rawPos.latitude;
    final advancedLongitude = estimate?.longitude ?? rawPos.longitude;
    final rawToAdvancedMeters = Geolocator.distanceBetween(
      rawPos.latitude,
      rawPos.longitude,
      advancedLatitude,
      advancedLongitude,
    );
    final rawToConservativeMeters = conservative == null
        ? 0.0
        : Geolocator.distanceBetween(
            rawPos.latitude,
            rawPos.longitude,
            conservative.representativePoint.latitude,
            conservative.representativePoint.longitude,
          );
    final advancedToConservativeMeters = conservative == null
        ? 0.0
        : Geolocator.distanceBetween(
            advancedLatitude,
            advancedLongitude,
            conservative.representativePoint.latitude,
            conservative.representativePoint.longitude,
          );
    final integrityState = positionIntegrityMonitor.observe(
      PositionIntegrityObservation(
        elapsed: processTick,
        separationMeters: advancedToConservativeMeters,
        protectionS1Meters: estimate?.uncertaintyMeters ?? rawPos.accuracy,
        protectionConsensusMeters:
            conservative?.uncertaintyMeters ?? rawPos.accuracy,
        motionAllowanceMeters: math.max(0, rawPos.speed) * .7,
        rawAndConservativeAgree: rawToConservativeMeters <= 1,
        fixIsFresh: now.difference(rawPos.timestamp).abs() <=
            const Duration(seconds: maxGpsTimestampAgeSeconds),
      ),
    );
    positionIntegrityState.value = integrityState;
    final protectionBudget = ProtectionBudget(
      gnssMeasurementMeters:
          rawPos.accuracy.isFinite && rawPos.accuracy > 0 ? rawPos.accuracy : 0,
      solutionDisagreementMeters: advancedToConservativeMeters,
      fixAgeMotionMeters: math.max(
        0,
        now.difference(rawPos.timestamp).inMilliseconds /
            1000 *
            math.max(0, rawPos.speed),
      ),
    );
    final contractViolations =
        safetyContractMonitor.observe(ContractObservation(
      elapsed: processTick,
      at: now,
      acceptedFixTimestamp: rawPos.timestamp,
      previousAcceptedFixTimestamp: previousContractFixTimestamp.value,
      protectionRadiusMeters: conservative?.safetySet.boundingRadiusMeters,
      fixUpdatedThisTick: true,
      separationScore: PositionIntegrityObservation(
        elapsed: processTick,
        separationMeters: advancedToConservativeMeters,
        protectionS1Meters: estimate?.uncertaintyMeters ?? rawPos.accuracy,
        protectionConsensusMeters:
            conservative?.uncertaintyMeters ?? rawPos.accuracy,
        motionAllowanceMeters: math.max(0, rawPos.speed) * .7,
        rawAndConservativeAgree: rawToConservativeMeters <= 1,
        fixIsFresh: true,
      ).separationScore,
      integrityState: integrityState.name,
      budget: protectionBudget,
    ));
    previousContractFixTimestamp.value = rawPos.timestamp;
    lastProtectionBudget.value = protectionBudget;
    for (final violation in contractViolations) {
      final lastAt = lastContractViolationAt.value[violation.contractId];
      if (lastAt == null ||
          processTick - lastAt >= const Duration(seconds: 60)) {
        lastContractViolationAt.value = {
          ...lastContractViolationAt.value,
          violation.contractId: processTick,
        };
        appendRuntimeDiagnostic('safety_contract_violation', {
          'contractId': violation.contractId,
          'severity': violation.severity.name,
          'detail': violation.detail,
        });
      }
    }
    final lastSeparation = lastSolutionSeparationSampleAt.value;
    if (lastSeparation == null ||
        processTick - lastSeparation >= const Duration(seconds: 10) ||
        advancedToConservativeMeters > 8) {
      lastSolutionSeparationSampleAt.value = processTick;
      appendRuntimeDiagnostic('solution_separation', {
        'rawToAdvancedMeters': rawToAdvancedMeters,
        'rawToConservativeMeters': rawToConservativeMeters,
        'advancedToConservativeMeters': advancedToConservativeMeters,
        'fixAgeMs': now.difference(rawPos.timestamp).inMilliseconds,
        'integrityHint': integrityState.name,
        'protectionBudget': protectionBudget.toDiagnosticDetails(),
      });
    }

    // ######## 陸上判定 ########
    // 艇庫での準備・艇の運搬中は岸の危険区域の中にいるため、
    // 従来は連続音が鳴っていた(実機ログ t=172s)。
    //
    // **止めるのは音だけ**。リスク評価・画面表示・セッション記録・
    // 位置共有はこの判定に一切影響されない(原則1)。
    // 陸上になるのは遅く(陸側12m超が30秒継続)、水上へ戻るのは
    // 水面側の測位1点で即座、という非対称にしてある。
    final detector = ashoreDetector.value;
    if (detector != null) {
      final ashoreState = detector.update(AshoreObservation(
        position: LatLng(latestMyBoat.lat, latestMyBoat.lng),
        // 端末時計ではなくGNSS測位時刻を使う。時計補正で継続時間が飛ぶと
        // 30秒の確定が一瞬で成立しうる。
        at: latestMyBoat.timestamp,
        accuracyMeters: _finiteOrNull(rawPos.accuracy),
        gpsQualityUsable:
            gpsHealth.value.snapshot(now).quality == GpsHealthQuality.good,
      ));
      final previousAshoreState = lastAshoreState.value;
      isAshore.value = ashoreState.isAshore;
      // 距離は毎秒変わるためState全体の比較ではログが洪水になる。
      // 音の抑制状態またはその判断理由が変化したときだけイベント化し、
      // 距離の推移は30秒のheartbeatに載せる。
      lastAshoreState.value = ashoreState;
      if (ashoreState.isAshore != previousAshoreState.isAshore ||
          ashoreState.reason != previousAshoreState.reason) {
        appendRuntimeDiagnostic('ashore_state_changed', {
          'isAshore': ashoreState.isAshore,
          'reason': ashoreState.reason.name,
          'landSideDistanceMeters': ashoreState.landSideDistanceMeters,
        });
      }
    }

    // ######## 他艇を現在時刻まで外挿(推測航法) ########
    // 適応送信で他艇の受信間隔が空いても、最新の推定位置で評価する。
    // 受信ストリームが止まった場合に古い艇情報で評価し続けないよう、
    // 評価直前にも鮮度フィルタを適用する(受信時のフィルタと二重の防御)
    final extrapolationStartedAt = processingStopwatch.elapsed;
    final extrapolatedOthers = otherBoats.value
        .where((boat) {
          final updatedAt = boat.serverUpdatedAt ?? boat.timestamp;
          return now.difference(updatedAt).inMilliseconds <
              boatPredictionTimeoutSeconds * 1000;
        })
        .map((boat) => evaluatorService.extrapolateToNow(boat, now: now))
        .toList();
    final extrapolationDurationMs =
        (processingStopwatch.elapsed - extrapolationStartedAt).inMilliseconds;

    // ######## Evaluate Collision Risk ########
    // 通信や電池残量の取得を待つと警告が遅れるため、
    // 純粋な衝突判定とUI更新を必ず先に完了させる。
    final collisionAssessmentStartedAt = processingStopwatch.elapsed;
    final assessment = evaluatorService.assessRisk(
      latestMyBoat,
      extrapolatedOthers,
      obstacles.value,
      warningTimeSeconds: warningTimeSeconds.value,
      centerline: channelCenterline.value,
      laneResolver: channelLaneResolver.value,
      ownPositionSet: primarySolution == PrimarySolution.conservative
          ? conservative?.safetySet
          : null,
    );
    final collisionAssessmentDurationMs =
        (processingStopwatch.elapsed - collisionAssessmentStartedAt)
            .inMilliseconds;
    if (!isCurrentNavigation(generation)) return;
    // unusableからの復旧確認中でも、フィルタを通った新鮮なfixは
    // 低品質として最大限利用する。GPS capability自体は3観測・2秒の
    // 回復確認までunusableのままで、表示を楽観的に戻さない。
    final ownGpsQuality =
        acceptedFixQuality ?? gpsHealth.value.snapshot(now).quality;
    final assessmentDataQuality = switch (ownGpsQuality) {
      GpsHealthQuality.good => AlertDataQuality.good,
      GpsHealthQuality.degraded => AlertDataQuality.degraded,
      GpsHealthQuality.unusable => AlertDataQuality.unusable,
    };
    final safetyApplyStartedAt = processingStopwatch.elapsed;
    applyCompletedSafetyAssessment(
      assessment,
      now,
      assessmentDataQuality,
    );
    final safetyApplyDurationMs =
        (processingStopwatch.elapsed - safetyApplyStartedAt).inMilliseconds;
    pipelineRecoveryNeedsAssessment.value = false;

    // ######## Record Navigation Log ########
    final recordingStartedAt = processingStopwatch.elapsed;
    if (sessionPoints.value.length < maxSessionTrackPoints) {
      final health = gpsHealth.value.snapshot(now);
      final motion = strokeRate.motion.value;
      sessionPoints.value.add(TrackPoint(
        t: latestMyBoat.timestamp,
        elapsedMs: processTick.inMilliseconds,
        lat: latestMyBoat.lat,
        lng: latestMyBoat.lng,
        speed: latestMyBoat.speed,
        heading: latestMyBoat.heading,
        spm: strokeRate.spm.value,
        safetyLevel: safetyLevel.value.name,
        rawLat: rawPos.latitude,
        rawLng: rawPos.longitude,
        gnssAccuracyMeters: _finiteOrNull(rawPos.accuracy),
        speedAccuracyMetersPerSecond: _finiteOrNull(rawPos.speedAccuracy),
        headingAccuracyDegrees: _finiteOrNull(rawPos.headingAccuracy),
        gnssQuality: health.quality.name,
        positionFilterResult: 'accepted',
        estimateUncertaintyMeters: estimate?.uncertaintyMeters,
        estimateInnovationMeters: estimate?.innovationMeters,
        estimateDisposition: estimate?.disposition.name,
        estimateNormalizedInnovationSquared:
            estimate?.normalizedInnovationSquared,
        rawGnssSpeedMetersPerSecond: _finiteOrNull(rawPos.speed),
        imuConfidence: motion?.confidence,
        imuQuality: motion?.quality.name,
        distancePerStrokeMeters: motion?.distancePerStrokeMeters,
        catchSpeedLossMetersPerSecond: motion?.catchSpeedLossMetersPerSecond,
        lateDriveSpeedGainMetersPerSecond:
            motion?.lateDriveSpeedGainMetersPerSecond,
        recoverySpeedRetention: motion?.recoverySpeedRetention,
      ));
      // 初回fixはすぐ、以後は60秒ごとに保存。ファイルI/Oは
      // awaitせず、衝突判定と次のGPS fixをブロックしない。
      checkpointSessionIfDue(generation);
    }
    final recordingDurationMs =
        (processingStopwatch.elapsed - recordingStartedAt).inMilliseconds;

    // ######## Send Message(適応送信) ########
    final sharingStartedAt = processingStopwatch.elapsed;
    final hasNearbyBoat = extrapolatedOthers.any((boat) =>
        Geolocator.distanceBetween(
            latestMyBoat.lat, latestMyBoat.lng, boat.lat, boat.lng) <=
        nearbyBoatRadius);
    final elevatedRisk = safetyLevel.value != SafetyLevel.safe;
    final intervalSec = sendIntervalSecondsFor(
      speed: latestMyBoat.speed,
      otherBoatNearby: hasNearbyBoat,
      elevatedRisk: elevatedRisk,
      // 受信が落ちている間は「他艇なし」と区別できない。自艇が他艇から
      // 見えなくなる時間帯を作らないよう、近傍時と同じ間隔で送り続ける。
      //
      // **ここはデバウンス後ではなく生の劣化を見る。** デバウンス(15秒)は
      // 「system faultとして鳴らす」までの猶予であって、送信間隔を
      // 遅らせてよい根拠ではない。確定を待つ間に10秒送信を続けると、
      // 他艇側の予測TTL(6秒)を超えて自艇が相手の評価から消える。
      // 落ちていないのに短い間隔で送るのは安全側(通信量だけの問題)。
      receiveUnavailable:
          rawDynamicReceiveDegraded.value || isDynamicReceiveUnavailable.value,
    );
    final sendTick = safetyClock.value.elapsed;
    if (lastQueuedTick.value == null ||
        sendTick - lastQueuedTick.value! >=
            Duration(milliseconds: intervalSec * 1000 - 100)) {
      final batteryReadAt = lastBatteryReadAt.value;
      if ((batteryReadAt == null ||
              now.difference(batteryReadAt) >=
                  const Duration(seconds: batteryLevelCacheSeconds)) &&
          !batteryReadInFlight.value) {
        // 電池残量はplatform channel越しで、端末によっては応答に数百ms〜
        // タイムアウトの2秒かかる。ここでawaitすると位置処理のdrainループが
        // 止まり、次のfixの衝突評価が最大2秒遅れる。残量は送信メタデータで
        // あって安全判定には使わないため、取得は待たずに走らせ、値は
        // 次回の送信に反映されれば十分とする。
        batteryReadInFlight.value = true;
        unawaited(
            battery.batteryLevel.timeout(_platformReadTimeout).then((level) {
          if (!isCurrentNavigation(generation)) return;
          currentBatteryLevel.value = level;
          lastBatteryReadAt.value = DateTime.now();
          batteryReadFailureAnnounced.value = false;
        }).catchError((Object error) {
          // 一時的な取得失敗時は直前値を使い、警告評価を止めない。
          if (!isCurrentNavigation(generation)) return;
          if (!batteryReadFailureAnnounced.value) {
            batteryReadFailureAnnounced.value = true;
            appendRuntimeDiagnostic('battery_read_failed', {
              'errorType': error.runtimeType.toString(),
            });
          }
        }).whenComplete(() => batteryReadInFlight.value = false));
      }
      final batteryLevel = currentBatteryLevel.value;
      recordBatteryLevelIfChanged(batteryLevel);
      if (!isCurrentNavigation(generation)) return;
      final message = Message(
        sessionId: messageSessionId.value ?? 'unavailable-session',
        sequence: messageSequence.value++,
        boatId: latestMyBoat.boatId,
        displayName: latestMyBoat.displayName,
        boatType: latestMyBoat.boatType,
        lat: latestMyBoat.lat,
        lng: latestMyBoat.lng,
        heading: latestMyBoat.heading,
        speed: latestMyBoat.speed,
        timestamp: latestMyBoat.timestamp,
        battery: batteryLevel,
        accuracy: latestMyBoat.accuracy, // 受信側の不確実性マージン計算用
        presentationState:
            PresentationStateCodec.warningFor(safetySnapshotGate.value.latest),
        safetyRunMode:
            PresentationStateCodec.runModeFor(safetySnapshotGate.value.latest),
        audioSuppressedAshore: isAshore.value,
      );
      final contractViolation = message.compactRtdbContractViolation;
      if (contractViolation != null) {
        // Rulesでpermission-deniedに変わる前に、payloadの契約違反と
        // 特定する。精度を1000mへ切り下げると他艇の予測保護
        // 領域を過小評価するため、このfixは送らない。
        if (publishContractViolationField.value != contractViolation) {
          appendRuntimeDiagnostic('position_publish_contract_rejected', {
            'stage': 'periodic_write',
            'field': contractViolation,
            if (message.accuracy != null)
              'reportedAccuracyMeters': message.accuracy,
          });
          publishContractViolationField.value = contractViolation;
        }
      } else {
        if (publishContractViolationField.value != null) {
          appendRuntimeDiagnostic('position_publish_contract_recovered', {
            'previousField': publishContractViolationField.value,
          });
          publishContractViolationField.value = null;
        }
        // Firebase writeは圏外中にACK待ちとなり得る。GPS処理から
        // awaitせず、同時1件・待機は最新1件の送信mailboxへ渡す。
        // これにより通信断中も端末内の危険判定と記録は1Hzで続く。
        positionPublisher.add(message);
        lastQueuedTick.value = safetyClock.value.elapsed;
      }
    }
    final sharingDurationMs =
        (processingStopwatch.elapsed - sharingStartedAt).inMilliseconds;
    final processingDuration = DateTime.now().difference(now);
    final timingSampleTick = safetyClock.value.elapsed;
    final previousTimingSampleTick = lastProcessingTimingSampleTick.value;
    if (previousTimingSampleTick == null ||
        timingSampleTick - previousTimingSampleTick >=
            _processingTimingSampleInterval) {
      lastProcessingTimingSampleTick.value = timingSampleTick;
      appendRuntimeDiagnostic('position_processing_sample', {
        'totalDurationMs': processingStopwatch.elapsed.inMilliseconds,
        'estimatorDurationMs': estimatorDurationMs,
        'boatBuildDurationMs': boatBuildDurationMs,
        'otherBoatExtrapolationDurationMs': extrapolationDurationMs,
        'collisionAssessmentDurationMs': collisionAssessmentDurationMs,
        'safetyApplyDurationMs': safetyApplyDurationMs,
        'recordingDurationMs': recordingDurationMs,
        'sharingAndBatteryDurationMs': sharingDurationMs,
        'otherBoatCount': extrapolatedOthers.length,
        'obstacleCount': obstacles.value.length,
        'activeWarningCount': activeWarningCount.value,
        'positionSharingState': positionSharingDiagnosticState.value,
      });
    }
    if (processingDuration >= const Duration(milliseconds: 500)) {
      appendRuntimeDiagnostic('position_processing_slow', {
        'durationMs': processingDuration.inMilliseconds,
        'safetyLevel': safetyLevel.value.name,
        'otherBoatCount': extrapolatedOthers.length,
        'obstacleCount': obstacles.value.length,
        'timingSampleIncluded': previousTimingSampleTick == null ||
            timingSampleTick - previousTimingSampleTick >=
                _processingTimingSampleInterval,
      });
    }
    recordDiagnosticHeartbeatIfDue(generation);
  }

  /// 送信の初期設定(clear + onDisconnect 登録)をやり直す。
  ///
  /// 航行開始時に5秒でACKされないと degraded 起動するが、
  /// **従来はそこから復帰する経路が無かった**。2026-08-06 実機ログでは
  /// それが2セッション118分続いた。degraded 起動を続ける方針(原則1)は
  /// 変えず、復帰経路だけを足す。
  void startPublishingSetupInBackground(int generation, String boatId) {
    if (!isCurrentNavigation(generation) ||
        publishingSetupInFlight.value != null) {
      return;
    }

    appendRuntimeDiagnostic('position_sharing_clear_started');
    appendRuntimeDiagnostic('position_sharing_disconnect_arm_started');
    final clear = messageService.clearMessage(boatId);
    final arm = messageService.registerOnDisconnect(boatId);
    unawaited(clear.then<void>((_) {
      if (isCurrentNavigation(generation)) {
        appendRuntimeDiagnostic('position_sharing_clear_completed');
      }
    }, onError: (Object error, StackTrace _) {
      if (isCurrentNavigation(generation)) {
        appendRuntimeDiagnostic('position_sharing_clear_failed', {
          ..._positionSharingErrorDetails(error),
        });
      }
    }));
    unawaited(arm.then<void>((_) {
      if (isCurrentNavigation(generation)) {
        appendRuntimeDiagnostic('position_sharing_disconnect_arm_completed');
      }
    }, onError: (Object error, StackTrace _) {
      if (isCurrentNavigation(generation)) {
        appendRuntimeDiagnostic('position_sharing_disconnect_arm_failed', {
          ..._positionSharingErrorDetails(error),
        });
      }
    }));

    final setup = Future.wait([clear, arm]);
    final setupGeneration = ++publishingSetupGeneration.value;
    publishingSetupInFlight.value = setup;
    var settled = false;
    final timeoutTimer = Timer(_publishingSetupAckTimeout, () {
      if (settled || !isCurrentNavigation(generation)) return;
      // FirebaseのFutureはtimeoutでcancelできない。管理参照だけ
      // 解放し、後続registerが旧世代callbackを無効化する。
      final error = TimeoutException(
        '位置共有の初期設定ACKが時間内に返りませんでした。',
        _publishingSetupAckTimeout,
      );
      final kind = classifySharingFailure(
        errorCode: _sharingErrorCode(error),
        errorType: error.runtimeType.toString(),
      );
      publishingSetupFailureKind.value = kind;
      publishingSetupRetryAttempt.value = 1;
      if (identical(publishingSetupInFlight.value, setup)) {
        // 保留した元Futureはcancelできないが、次のregisterが
        // MessageServiceの旧世代を無効化できるため再試行を許可する。
        publishingSetupInFlight.value = null;
      }
      sharingFailureCount.value = 3;
      sharingFailureAnnounced.value = true;
      isPositionSharingUnavailable.value = true;
      positionSharingDiagnosticState.value = 'unavailable';
      appendRuntimeDiagnostic('position_sharing_setup_failed', {
        'failureKind': kind.name,
        'retryable': kind.shouldRetry(1),
        ..._positionSharingErrorDetails(error),
      });
    });

    unawaited(setup.then<void>((_) {
      settled = true;
      timeoutTimer.cancel();
      if (identical(publishingSetupInFlight.value, setup)) {
        publishingSetupInFlight.value = null;
      }
      if (!isCurrentNavigation(generation) ||
          setupGeneration != publishingSetupGeneration.value) {
        return;
      }
      final recovered = publishingSetupFailureKind.value != null;
      publishingSetupFailureKind.value = null;
      publishingSetupRetryAttempt.value = 0;
      publishingSetupNextRetryAt.value = null;
      sharingFailureCount.value = 0;
      sharingFailureAnnounced.value = false;
      isPositionSharingUnavailable.value = false;
      // setupだけでは他端末へ届く証拠にならない。実write
      // ACKまではhealthyと判定しない。
      positionSharingDiagnosticState.value = 'pending_write_ack';
      if (recovered) {
        appendRuntimeDiagnostic('position_sharing_setup_recovered', {
          'retryAttempt': 0,
          'lateCompletion': true,
        });
      }
    }, onError: (Object error, StackTrace _) {
      settled = true;
      timeoutTimer.cancel();
      if (identical(publishingSetupInFlight.value, setup)) {
        publishingSetupInFlight.value = null;
      }
      if (!isCurrentNavigation(generation) ||
          setupGeneration != publishingSetupGeneration.value) {
        return;
      }
      final kind = classifySharingFailure(
        errorCode: _sharingErrorCode(error),
        errorType: error.runtimeType.toString(),
      );
      publishingSetupFailureKind.value = kind;
      publishingSetupRetryAttempt.value = 1;
      sharingFailureCount.value = 3;
      sharingFailureAnnounced.value = true;
      isPositionSharingUnavailable.value = true;
      positionSharingDiagnosticState.value = 'unavailable';
      appendRuntimeDiagnostic('position_sharing_setup_failed', {
        'failureKind': kind.name,
        'retryable': kind.shouldRetry(1),
        ..._positionSharingErrorDetails(error),
      });
      debugPrint('Position publishing setup is unavailable: $error');
    }));
  }

  Future<void> retryPublishingSetup(int generation) async {
    if (!isCurrentNavigation(generation)) return;
    // Future.timeoutはFirebase処理自体をcancelしない。遅延した
    // onDisconnect登録に上書きする再登録を重ねない。
    if (publishingSetupInFlight.value != null) return;
    final config_ = config.value;
    if (config_ == null) return;
    final attempt = publishingSetupRetryAttempt.value;
    try {
      final setup = Future.wait([
        messageService.clearMessage(config_.boatId),
        messageService.registerOnDisconnect(config_.boatId),
      ]);
      final setupGeneration = ++publishingSetupGeneration.value;
      publishingSetupInFlight.value = setup;
      unawaited(setup.then<void>((_) {
        if (identical(publishingSetupInFlight.value, setup)) {
          publishingSetupInFlight.value = null;
        }
        if (!isCurrentNavigation(generation) ||
            setupGeneration != publishingSetupGeneration.value) {
          return;
        }
        final recovered = publishingSetupFailureKind.value != null;
        publishingSetupFailureKind.value = null;
        publishingSetupRetryAttempt.value = 0;
        sharingFailureCount.value = 0;
        sharingFailureAnnounced.value = false;
        isPositionSharingUnavailable.value = false;
        positionSharingDiagnosticState.value = 'pending_write_ack';
        if (recovered) {
          appendRuntimeDiagnostic('position_sharing_setup_recovered', {
            'retryAttempt': attempt,
          });
        }
      }, onError: (Object _, StackTrace __) {
        if (identical(publishingSetupInFlight.value, setup)) {
          publishingSetupInFlight.value = null;
        }
      }));
      await setup.timeout(_publishingSetupAckTimeout);
      if (!isCurrentNavigation(generation) ||
          setupGeneration != publishingSetupGeneration.value) {
        return;
      }
      publishingSetupFailureKind.value = null;
      publishingSetupRetryAttempt.value = 0;
      sharingFailureCount.value = 0;
      sharingFailureAnnounced.value = false;
      isPositionSharingUnavailable.value = false;
      // まだ位置writeのACKは得ていない。publisherの
      // onSuccessでだけhealthyへ上げる。
      positionSharingDiagnosticState.value = 'pending_write_ack';
    } catch (error) {
      if (!isCurrentNavigation(generation)) return;
      if (error is TimeoutException) {
        // 永続pendingでwatchdogが永久に閉じるのを防ぐ。
        publishingSetupInFlight.value = null;
      }
      final kind = classifySharingFailure(
        errorCode: _sharingErrorCode(error),
        errorType: error.runtimeType.toString(),
      );
      publishingSetupFailureKind.value = kind;
      // 再試行しない種類へ変わったら、そこで打ち切る。
      final nextFailureCount = attempt + 1;
      publishingSetupRetryAttempt.value = nextFailureCount;
      appendRuntimeDiagnostic('position_sharing_setup_retry_failed', {
        'failureKind': kind.name,
        'retryable': kind.shouldRetry(nextFailureCount),
        'retryAttempt': attempt,
        ..._positionSharingErrorDetails(error),
      });
    }
  }

  Future<void> handlePosition(
    Position position,
    int generation, {
    FixSource source = FixSource.stream,
    FixRejectionReason? forcedRejectionReason,
  }) async {
    if (!isCurrentNavigation(generation)) return;
    final receivedAt = DateTime.now();
    final receivedElapsed = safetyClock.value.elapsed;
    final previousTimestamp = previousFixEnvelopeTimestamp.value;
    final previousArrival = previousFixEnvelopeArrival.value;
    final envelopeBase = (
      sequence: ++fixEnvelopeSequence.value,
      source: source,
      arrivedAtMonotonic: receivedElapsed,
      fixTimestamp: position.timestamp,
      ageAtArrivalMs: receivedAt.difference(position.timestamp).inMilliseconds,
      deltaFromPreviousFixMs: previousTimestamp == null
          ? null
          : position.timestamp.difference(previousTimestamp).inMilliseconds,
      deltaFromPreviousArrivalMs: previousArrival == null
          ? null
          : (receivedElapsed - previousArrival).inMilliseconds,
      accuracyMeters: position.accuracy,
    );
    previousFixEnvelopeTimestamp.value = position.timestamp;
    previousFixEnvelopeArrival.value = receivedElapsed;
    void recordEnvelope(
      FixEnvelope envelope, {
      bool force = false,
      Map<String, dynamic> extraDetails = const {},
    }) {
      final sampledAt = lastFixEnvelopeSampleAt.value;
      if (!force &&
          sampledAt != null &&
          envelope.arrivedAtMonotonic - sampledAt <
              const Duration(seconds: 10)) {
        return;
      }
      lastFixEnvelopeSampleAt.value = envelope.arrivedAtMonotonic;
      appendRuntimeDiagnostic('gps_fix_envelope', {
        ...envelope.toDiagnosticDetails(),
        ...extraDetails,
      });
    }

    if (forcedRejectionReason != null) {
      recordEnvelope(
        FixEnvelope(
          sequence: envelopeBase.sequence,
          source: envelopeBase.source,
          arrivedAtMonotonic: envelopeBase.arrivedAtMonotonic,
          fixTimestamp: envelopeBase.fixTimestamp,
          ageAtArrivalMs: envelopeBase.ageAtArrivalMs,
          deltaFromPreviousFixMs: envelopeBase.deltaFromPreviousFixMs,
          deltaFromPreviousArrivalMs: envelopeBase.deltaFromPreviousArrivalMs,
          accuracyMeters: envelopeBase.accuracyMeters,
          accepted: false,
          rejectionReason: forcedRejectionReason,
        ),
        force: true,
      );
      return;
    }

    final filterResult = gpsFilter.value.evaluate(
      position,
      receivedAt: receivedAt,
      receivedElapsed: receivedElapsed,
    );
    final filterDetails = <String, dynamic>{
      'filterReason': filterResult.reason.name,
      'speedAnchorReacquired': filterResult.speedAnchorReacquired,
      'currentAccuracyMeters': position.accuracy,
      if (filterResult.previousAccuracyMeters != null)
        'previousAccuracyMeters': filterResult.previousAccuracyMeters,
      if (filterResult.distanceMeters != null)
        'distanceMeters': filterResult.distanceMeters,
      if (filterResult.elapsedSeconds != null)
        'filterElapsedMs': (filterResult.elapsedSeconds! * 1000).round(),
    };
    final filterRejectionReason = switch (filterResult.reason) {
      GpsPositionFilterReason.mocked => FixRejectionReason.mocked,
      GpsPositionFilterReason.invalidCoordinate =>
        FixRejectionReason.invalidCoordinate,
      GpsPositionFilterReason.invalidAccuracy =>
        FixRejectionReason.invalidAccuracy,
      GpsPositionFilterReason.lowAccuracy => FixRejectionReason.lowAccuracy,
      GpsPositionFilterReason.staleTimestamp =>
        FixRejectionReason.staleTimestamp,
      GpsPositionFilterReason.nonMonotonic => FixRejectionReason.nonMonotonic,
      GpsPositionFilterReason.implausibleSpeed =>
        FixRejectionReason.implausibleSpeed,
      GpsPositionFilterReason.accepted ||
      GpsPositionFilterReason.lowAccuracyMeasurementBypassed ||
      GpsPositionFilterReason.lowAccuracyAnchorBypassed =>
        null,
    };
    if (!filterResult.accepted) {
      recordEnvelope(
          FixEnvelope(
            sequence: envelopeBase.sequence,
            source: envelopeBase.source,
            arrivedAtMonotonic: envelopeBase.arrivedAtMonotonic,
            fixTimestamp: envelopeBase.fixTimestamp,
            ageAtArrivalMs: envelopeBase.ageAtArrivalMs,
            deltaFromPreviousFixMs: envelopeBase.deltaFromPreviousFixMs,
            deltaFromPreviousArrivalMs: envelopeBase.deltaFromPreviousArrivalMs,
            accuracyMeters: envelopeBase.accuracyMeters,
            accepted: false,
            rejectionReason: filterRejectionReason!,
          ),
          force: true,
          extraDetails: filterDetails);
      final health = gpsHealth.value.recordRejected(receivedAt);
      recordGpsQualityIfChanged(health, receivedAt);
      appendDiagnosticEvent(SessionDiagnosticEvent(
        t: receivedAt,
        type: 'gps_fix_rejected',
        details: {
          'filterResult': 'rejected',
          'timestamp': position.timestamp.toUtc().toIso8601String(),
          if (position.latitude.isFinite) 'rawLat': position.latitude,
          if (position.longitude.isFinite) 'rawLng': position.longitude,
          if (position.accuracy.isFinite) 'accuracyMeters': position.accuracy,
          if (position.speed.isFinite) 'speedMetersPerSecond': position.speed,
          ...filterDetails,
          'healthQuality': health.quality.name,
          'consecutiveRejected': health.consecutiveRejected,
        },
      ));
      if (kDebugMode) {
        debugPrint('GPS position ignored because its quality is insufficient.');
      }
      if (health.quality == GpsHealthQuality.unusable) {
        gpsLossAnnounced.value = true;
        clearAshoreForUnusableGps();
        applySafetyAssessment(
          RiskAssessment(level: CollisionRiskLevel.lv0),
          DateTime.now(),
          AlertDataQuality.unusable,
        );
      }
      return;
    }
    final ingress = fixIngressPolicy.decide(
      fixTimestamp: position.timestamp,
      arrivalMonotonic: receivedElapsed,
    );
    if (!ingress.accepted) {
      recordEnvelope(
        FixEnvelope(
          sequence: envelopeBase.sequence,
          source: envelopeBase.source,
          arrivedAtMonotonic: envelopeBase.arrivedAtMonotonic,
          fixTimestamp: envelopeBase.fixTimestamp,
          ageAtArrivalMs: envelopeBase.ageAtArrivalMs,
          deltaFromPreviousFixMs: envelopeBase.deltaFromPreviousFixMs,
          deltaFromPreviousArrivalMs: envelopeBase.deltaFromPreviousArrivalMs,
          accuracyMeters: envelopeBase.accuracyMeters,
          accepted: false,
          rejectionReason: ingress.rejectionReason!,
        ),
        force: true,
        extraDetails: filterDetails,
      );
      appendRuntimeDiagnostic('gps_position_coalesced', {
        'arrivalDeltaMs': envelopeBase.deltaFromPreviousArrivalMs,
        'fixTimestampDeltaMs': envelopeBase.deltaFromPreviousFixMs,
        'droppedFixAgeMs': envelopeBase.ageAtArrivalMs,
        'reason': ingress.rejectionReason!.name,
      });
      return;
    }
    recordEnvelope(
      FixEnvelope(
        sequence: envelopeBase.sequence,
        source: envelopeBase.source,
        arrivedAtMonotonic: envelopeBase.arrivedAtMonotonic,
        fixTimestamp: envelopeBase.fixTimestamp,
        ageAtArrivalMs: envelopeBase.ageAtArrivalMs,
        deltaFromPreviousFixMs: envelopeBase.deltaFromPreviousFixMs,
        deltaFromPreviousArrivalMs: envelopeBase.deltaFromPreviousArrivalMs,
        accuracyMeters: envelopeBase.accuracyMeters,
        accepted: true,
      ),
      // 通常の受理は10秒サンプルのままだが、再捕捉の入口は
      // 次回の実機ログで必ず確認できるよう全件残す。
      // 良好だが古いanchorからの有限再捕捉は、通常受理と
      // 同じreasonでも次回の実機ログに必ず残す。
      force: filterResult.reason != GpsPositionFilterReason.accepted ||
          filterResult.speedAnchorReacquired,
      extraDetails: filterDetails,
    );
    if (!isCurrentNavigation(generation)) return;
    final acceptedAt = receivedAt;
    final lowAccuracy = gpsFilter.value.isLowAccuracy(position);
    lastAcceptedGpsSpeedMetersPerSecond.value =
        position.speed.isFinite && position.speed >= 0 ? position.speed : null;
    lastAcceptedGpsAccuracyMeters.value =
        position.accuracy.isFinite && position.accuracy > 0
            ? position.accuracy
            : null;
    // 実効レートは heartbeat で60秒窓に切り出す。ここでは到着だけ積む。
    recentPositionArrivals.value.add(safetyClock.value.elapsed);
    final health = gpsHealth.value.recordAccepted(
      acceptedAt,
      degraded: lowAccuracy,
    );
    recordGpsQualityIfChanged(health, acceptedAt);
    lastValidGpsAt.value = acceptedAt;
    lastValidGpsTimestamp.value = position.timestamp;
    lastDeadReckoningPredictionTick.value = null;
    final recoveryFixQuality = evaluationQualityForAcceptedFix(health.quality);
    if (health.quality == GpsHealthQuality.unusable) {
      clearAshoreForUnusableGps();
    } else {
      gpsLossAnnounced.value = false;
    }
    // ここから先のGPS入力だけが衝突評価の完了を期待する対象。品質不足で
    // 早期returnしたfixを数えると、GPS fault を評価停止と誤分類する。
    safetyEvaluationLiveness.value.recordSafetyInput(
      safetyClock.value.elapsed,
    );
    await processPosition(
      position,
      generation,
      acceptedFixQuality: recoveryFixQuality,
    );
  }

  /// 高頻度のGPSストリームを有界メールボックスに集約する。
  /// 処理中の測位より古い待ち行列は捨て、次に最新の1件を使う。
  void enqueuePosition(
    Position position,
    int generation, {
    FixSource source = FixSource.stream,
  }) {
    if (!isCurrentNavigation(generation)) return;
    positionBatchCollector.add(_QueuedPosition(position, source));
    if (positionDrainRunning.value) return;

    positionDrainRunning.value = true;
    final drain = Future<void>(() async {
      try {
        // 同じイベントループで届いたfixを一度集め、時刻の最も新しいものを
        // 安全評価へ渡す。古いものはFixEnvelopeとして明示的に残す。
        await Future<void>.delayed(Duration.zero);
        while (isCurrentNavigation(generation)) {
          final batch = positionBatchCollector.takeBatch();
          if (batch == null) break;
          try {
            for (final superseded in batch.superseded) {
              await handlePosition(
                superseded.position,
                generation,
                source: superseded.source,
                forcedRejectionReason: FixRejectionReason.supersededInBatch,
              );
            }
            await handlePosition(
              batch.latest.position,
              generation,
              source: batch.latest.source,
            );
          } catch (e) {
            reportPipelineFailure(e, generation);
          }
        }
      } finally {
        positionDrainRunning.value = false;
      }
    });
    positionDrainFuture.value = drain;
  }

  enqueuePositionFromPoll = (position, generation) =>
      enqueuePosition(position, generation, source: FixSource.polling);

  retryPublishingSetupFromWatchdog = retryPublishingSetup;

  Future<void> startNavigation(NavConfig config_) async {
    if (navigationStopInProgress.value) {
      throw StateError('航行終了処理中です。完了後に再試行してください。');
    }
    if (navigationStartInProgress.value) {
      throw StateError('航行開始処理はすでに実行中です。');
    }
    if (mode.value == NavMode.navigator) return;
    navigationStartInProgress.value = true;
    isTransitioning.value = true;
    final generation = ++navigationGeneration.value;
    positionBatchCollector.clear();
    void ensureStartIsCurrent() {
      if (generation != navigationGeneration.value) {
        throw StateError('航行開始処理は中断されました。');
      }
    }

    try {
      await loadWarningTime();
      ensureStartIsCurrent();
      // 警告音を準備できない場合も航行は開始する。ここで止めると地図・
      // 他艇表示・画面バナー警告・航行記録まで同時に失う。音が出せない事実は
      // alert.error → 'audio_unavailable' の system fault と
      // runMode=unavailable として利用者へ継続的に提示される。
      final audioReady = await alert.checkReady();
      ensureStartIsCurrent();
      // 次回の航行では同一チームの公開設定を揃えるため、開始前だけ1文書を
      // 最新化する。圏外・未ログイン・Rules未反映でも開始を止めず、直前の
      // cacheまたは端末設定へ縮退して、その事実を計器とログへ残す。
      SharedSafetyCalibrationState? cachedSafety;
      try {
        cachedSafety = await sharedSafetyCalibrationService.loadCached();
      } catch (error) {
        appendRuntimeDiagnostic('shared_safety_cache_unavailable', {
          'errorType': error.runtimeType.toString(),
        });
      }
      SharedSafetyCalibrationFetch safetyFetch;
      try {
        safetyFetch = await sharedSafetyCalibrationService
            .fetchLatestWithStatus(forceServer: true)
            .timeout(sharedSafetyFetchTimeout);
      } on TimeoutException {
        safetyFetch = SharedSafetyCalibrationFetch(
          result: cachedSafety == null
              ? SharedSafetyFetchResult.unavailable
              : SharedSafetyFetchResult.cache,
          state: cachedSafety,
          teamIdHash: sharedSafetyCalibrationService.activeTeamIdHash,
        );
        appendRuntimeDiagnostic('shared_safety_fetch_timeout', {
          'timeoutMs': sharedSafetyFetchTimeout.inMilliseconds,
          'usedCache': cachedSafety != null,
        });
      } catch (error) {
        // fetchLatestWithStatusは通常cacheへ縮退するが、SharedPreferencesの破損
        // など初期取得自体が失敗しても航行を止めない。
        safetyFetch = SharedSafetyCalibrationFetch(
          result: cachedSafety == null
              ? SharedSafetyFetchResult.unavailable
              : SharedSafetyFetchResult.cache,
          state: cachedSafety,
          teamIdHash: sharedSafetyCalibrationService.activeTeamIdHash,
        );
        appendRuntimeDiagnostic('shared_safety_fetch_failed', {
          'errorType': error.runtimeType.toString(),
          'usedCache': cachedSafety != null,
        });
      }
      // 新しいv5文書が無いチームでは、最初に更新した端末がコード既定値を
      // revision 1として一度だけ作る。同時起動はFirestore transactionで
      // 同じ文書へ収束する。通信できなければローカル既定値で航行を続ける。
      if (safetyFetch.state == null &&
          sharedSafetyCalibrationService.optionalActiveTeamId != null) {
        try {
          final defaults = await sharedSafetyCalibrationService
              .ensureTeamDefaults()
              .timeout(sharedSafetyFetchTimeout);
          safetyFetch = SharedSafetyCalibrationFetch(
            result: SharedSafetyFetchResult.fresh,
            state: defaults,
            teamIdHash: sharedSafetyCalibrationService.activeTeamIdHash,
          );
          appendRuntimeDiagnostic('shared_safety_defaults_initialized', {
            'revision': defaults.revision,
          });
        } catch (error) {
          appendRuntimeDiagnostic('shared_safety_defaults_init_failed', {
            'errorType': error.runtimeType.toString(),
          });
        }
      }
      sharedSafetyFetchResult.value = safetyFetch.result;
      sharedSafetyCacheAge.value = safetyFetch.cacheAge;
      sharedSafetyTeamIdHash.value = safetyFetch.teamIdHash;
      await loadWarningTime(sharedSafety: safetyFetch.state);
      // 固定流木を更新し、上で最新化した共有安全設定(またはcache)を使って
      // 危険形状を一括生成する。航行開始後はlistenerが差分を通知するだけで、
      // 利用者の確認なしに足元の形状を差し替えない。
      await loadDefaultObstacles(refreshManagedHazards: true);
      // 固定危険区域が1枚も読めない場合も、他艇との衝突警告は完全に機能する。
      // 開始を止めず 'static_profile_unavailable' として警告し続ける。
      final staticProfileUsable = !isStaticProfileUnavailable.value &&
          defaultObstacles.value.isNotEmpty;
      if (!staticProfileUsable) {
        isStaticProfileUnavailable.value = true;
      }
      // 前面にいるうちに確認する。Android 12以降はバックグラウンドから
      // 位置情報フォアグラウンドサービスを開始できないため、開始後に要求しない。
      await permissionService.requireBackgroundLocationPermission();
      ensureStartIsCurrent();
      // 新しいfixを優先するが、タイムアウト時は画面表示で取得済みの位置を
      // 足掛かりにしてGPS streamを開始する。精度不良は開始を塞がず、
      // 航行中のGPS品質警告として扱う。
      final initialPos =
          await geoService.getNavigationBootstrapPosition(config_.accuracy);
      ensureStartIsCurrent();
      gpsFilter.value.reset();
      positionEstimator.reset();
      conservativePositionEstimator.reset();
      positionIntegrityMonitor.reset();
      safetyContractMonitor.reset();
      fixIngressPolicy.reset();
      fixEnvelopeSequence.value = 0;
      previousFixEnvelopeTimestamp.value = null;
      previousFixEnvelopeArrival.value = null;
      lastFixEnvelopeSampleAt.value = null;
      lastSolutionSeparationSampleAt.value = null;
      previousContractFixTimestamp.value = null;
      lastContractViolationAt.value = {};
      positionIntegrityState.value = PositionIntegrityState.trusted;
      lastProtectionBudget.value = null;
      estimatorClock.reset();
      lastDeadReckoningPredictionTick.value = null;
      previousEstimatedPosition.value = null;
      distanceIntegrator.reset();
      preRawPos.value = null;
      preHeading.value = 0;
      if (!gpsFilter.value.hasValidCoordinates(initialPos)) {
        throw StateError('現在地の座標が不正です。位置情報設定を確認してください。');
      }
      final initialGpsUsable = gpsFilter.value.accepts(
        initialPos,
        receivedAt: DateTime.now(),
        receivedElapsed: safetyClock.value.elapsed,
      );
      final initialGpsDegraded =
          initialGpsUsable && gpsFilter.value.isLowAccuracy(initialPos);
      config.value = config_;
      // 開始前に生成済みのrevisionは「適用済み」としてlistenerへ知らせる。
      // 初回cacheイベントを航行中の未確認更新と誤認して再生成しない。
      final appliedRevision = appliedSharedSafetyRevision.value;
      if (appliedRevision != null) {
        sharedCalibrationSyncPolicy.markApplied(appliedRevision);
      }
      // 固定流木は直前に取得済みのため、ここでは再取得しない。
      messageService.resetClockSkewDiagnostics(localBoatId: config_.boatId);
      lastPositionPublishAckAt.value = null;
      membershipReceiveProbeConfirmed.value = false;
      membershipAuthorization.value = SharingAuthorization.unknown;
      dynamicReceiveAccessConfirmed.value = false;
      receiveAccessProbeInFlight.value = false;
      lastReceiveAccessProbeAt.value = null;
      receiveAccessProbeGeneration.value += 1;
      // 所属bridgeは診断であり、GPS・警告・記録の開始条件では
      // ない。圏外のget()をawaitして航行開始を遅らせない。
      // Firestore切り戻し時はRTDB membershipが受信条件ではないため
      // セルフチェック自体を行わない。
      if (useRealtimeDatabaseForPositions) {
        queuePreSessionDiagnostic('team_membership_self_check_started');
        unawaited(teamService
            .diagnoseActiveRtdbMembership()
            .timeout(const Duration(seconds: 3), onTimeout: () {
          return const TeamMembershipDiagnostic(
            authenticated: true,
            failureCode: 'timeout',
          );
        }).then((membershipDiagnostic) {
          if (generation != navigationGeneration.value ||
              config.value == null ||
              navigationStopInProgress.value) {
            return;
          }
          queuePreSessionDiagnostic(
            'team_membership_self_check_completed',
            membershipDiagnostic.toDiagnosticDetails(),
          );
          membershipReceiveProbeConfirmed.value =
              membershipDiagnostic.teamUserMatchesActiveTeam == true &&
                  membershipDiagnostic.memberRecordExists == true;
          if (membershipReceiveProbeConfirmed.value) {
            // live_positionsのread Rulesと同じmembership predicateが
            // 自分の読取りで確認できた。
            dynamicReceiveAccessConfirmed.value = true;
          }
          if (membershipReceiveProbeConfirmed.value) {
            membershipAuthorization.value = SharingAuthorization.granted;
          } else if (lastPositionPublishAckAt.value == null &&
              !dynamicReceiveAccessConfirmed.value) {
            // 診断開始後の実write/read成功を、遅く返った古い
            // self-check結果でdeniedへ戻さない。
            membershipAuthorization.value = membershipDiagnostic.readDenied ||
                    membershipDiagnostic.teamUserMatchesActiveTeam == false ||
                    membershipDiagnostic.memberRecordExists == false
                ? SharingAuthorization.denied
                : SharingAuthorization.unknown;
          }
        }, onError: (Object error, StackTrace _) {
          // TeamServiceは通常診断結果へ変換するが、想定外例外も
          // 航行本体に波及させない。
          if (generation != navigationGeneration.value ||
              config.value == null ||
              navigationStopInProgress.value) {
            return;
          }
          queuePreSessionDiagnostic('team_membership_self_check_completed', {
            'authenticated': false,
            'readDenied': false,
            'failureCode': error.runtimeType.toString(),
          });
        }));
      } else {
        membershipReceiveProbeConfirmed.value = true;
      }
      await startWatching(
        refreshManagedHazards: false,
        navigationOwned: true,
      );
      scheduleReceiveAccessProbe(generation, force: true);
      ensureStartIsCurrent();
      safetyLevel.value = SafetyLevel.safe;
      currentWarning.value = null;
      audioDirective.value = null;
      audioDirectiveCategory.value = null;
      isAshore.value = false;
      ashoreDetector.value?.reset();
      lastAshoreState.value = AshoreState.initial;
      activeWarnings.value = const [];
      lastQueuedTick.value = null;
      // boatIdはRTDB pathで識別できる。sessionIdを短いbase36にし、
      // 1Hz位置配信の転送量と無線時間を減らす。
      messageSessionId.value =
          '${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}-'
          '${generation.toRadixString(36)}';
      messageSequence.value = 0;
      publishContractViolationField.value = null;
      lastProcessedTick.value = null;
      lastProcessedWallClock.value = null;
      lastDiagnosticPositionGapAt.value = null;
      lastProcessingTimingSampleTick.value = null;
      lastValidGpsAt.value = initialGpsUsable ? DateTime.now() : null;
      gpsHealth.value.reset(
        acceptedAt: lastValidGpsAt.value,
        degraded: initialGpsDegraded,
      );
      gpsLossAnnounced.value = !initialGpsUsable;
      // Firebase setupは航行開始後に非同期で行う。圏外やACK停止が
      // GPS・記録・警告の開始を1秒も待たせない。
      sharingFailureCount.value = 0;
      sharingFailureAnnounced.value = false;
      isPositionSharingUnavailable.value = false;
      positionSharingDiagnosticState.value = 'pending_setup';
      publishingSetupFailureKind.value = null;
      publishingSetupRetryAttempt.value = 0;
      isDynamicReceiveUnavailable.value = false;
      rawDynamicReceiveDegraded.value = false;
      receiveFaultDebouncer.value.reset();
      sharingCapabilityMonitor.reset();
      isSharingCapabilityUnconfirmed.value = false;
      publishingSetupNextRetryAt.value = null;
      gpsStreamRecoveryStartedAt.value = null;
      sessionPoints.value = [];
      sessionAlertEvents.value = [];
      sessionDiagnosticEvents.value = [];
      diagnosticSequence.value = 0;
      diagnosticEventDroppedCount.value = 0;
      alertEventDroppedCount.value = 0;
      diagnosticBoatAliases.value = {};
      diagnosticAlertAliases.value = {};
      diagnosticCandidates.value = {};
      lastDiagnosticAudioKey.value = null;
      lastDiagnosticGpsQuality.value = null;
      lastDiagnosticOrientation.value = null;
      lastDiagnosticHeartbeatTick.value = null;
      warningPresenter.value.reset();
      sessionDiagnosticMetadata.value =
          await loadSessionDiagnosticMetadata(config_);
      ensureStartIsCurrent();
      sessionStartedAt.value = DateTime.now();
      safetyClockOrigin.value = sessionStartedAt.value!;
      safetyClock.value
        ..reset()
        ..start();
      lastSessionCheckpointTick.value = null;
      lastCheckpointSummary.value = null;
      lastCheckpointSummaryTick.value = null;
      lastAlertObservationAt.value = {};
      pendingSessionWrite.value = null;
      totalDistance.value = 0.0;
      currentBatteryLevel.value = null;
      lastBatteryReadAt.value = null;
      batteryReadInFlight.value = false;
      mode.value = NavMode.navigator;
      if (pendingPreSessionDiagnostics.value.isNotEmpty) {
        for (final event in pendingPreSessionDiagnostics.value) {
          appendDiagnosticEvent(event);
        }
        pendingPreSessionDiagnostics.value = [];
      }
      appendDiagnosticEvent(SessionDiagnosticEvent(
        t: sessionStartedAt.value!,
        type: 'navigation_started',
        details: {
          'generation': generation,
          'boatType': config_.boatType.name,
          'seatPosition': config_.seatPos.label,
          'locationAccuracy': config_.accuracy.name,
          'robustPositionFilterEnabled': enableRobustPositionFilter,
          'positionSharingDegraded': false,
          // 縮退したまま開始した機能を、開始時点で明示的に残す。
          'audioReady': audioReady,
          'staticProfileUsable': staticProfileUsable,
          'staticObstacleCount': defaultObstacles.value.length,
          'dangerZoneSettingsSource':
              dangerZoneSettingsSource.value?.name ?? 'codeDefault',
          'sharedSafetyRevision': appliedSharedSafetyRevision.value,
          'sharedSafetyFetchResult': sharedSafetyFetchResult.value.name,
          'sharedSafetyCacheAgeMs': sharedSafetyCacheAge.value?.inMilliseconds,
          'teamIdHash': sharedSafetyTeamIdHash.value,
          ...effectiveDangerZoneDiagnosticFields(),
          if (presetObstacleService.lastProfileIntegrity != null)
            'hazardProfileIntegrity':
                presetObstacleService.lastProfileIntegrity!.toJson(),
          'initialGpsUsable': initialGpsUsable,
          'initialGpsDegraded': initialGpsDegraded,
          'diagnosticEventSchemaVersion': diagnosticEventSchemaVersion,
          'audioSessionPolicy': 'mixWithOthers',
          'positionSharingInitialState': 'pending_setup',
          if (initialPos.accuracy.isFinite)
            'initialGpsAccuracyMeters': initialPos.accuracy,
        },
      ));
      recordGpsQualityIfChanged(
        gpsHealth.value.snapshot(sessionStartedAt.value!),
        sessionStartedAt.value!,
      );
      recordGpsEnvironmentSnapshot('navigation_started', generation, details: {
        if (initialPos.accuracy.isFinite)
          'initialGpsAccuracyMeters': initialPos.accuracy,
      });
      recordOrientationIfChanged();
      gpsFilter.value.rebaseLastAcceptedElapsed(Duration.zero);
      safetyEvaluationLiveness.value
        ..reset()
        ..tick(safetyClock.value.elapsed);
      safetyTimerStalled.value = false;
      safetyEvaluationStalled.value = false;
      pipelineRecoveryTicks.value = 0;
      pipelineRecoveryNeedsAssessment.value = false;
      isPipelineUnresponsive.value = false;
      safetyOrchestrator.value = SafetyOrchestrator(
        sessionId: messageSessionId.value!,
        sessionGeneration: generation,
        mooringAreas: mooringAreaPolygons.value,
        presentationConfig: AlertPresentationConfig(
          continuousAudioDeadline: Duration(
            milliseconds: (primaryWarningLeadTimeSeconds.value * 1000).round(),
          ),
          intermittentAudioDeadline: Duration(
            milliseconds: (warningTimeSeconds.value * 1000).round(),
          ),
        ),
      );
      safetySnapshotGate.value = SafetySnapshotGate();
      activeWarningCount.value = 0;
      positionPublisher.start();
      startPublishingSetupInBackground(generation, config_.boatId);
      ensureStartIsCurrent();
      debugPrint(
          "CONFIG - BoatType: ${config.value!.boatType.name}, SeatPos: ${config.value!.seatPos.label}");
      if (initialGpsUsable) {
        safetyEvaluationLiveness.value.recordSafetyInput(
          safetyClock.value.elapsed,
        );
        await processPosition(initialPos, generation);
      } else {
        // 座標不正・時刻切れなど、カルマン推定へ安全に渡せないfixだけを
        // 保留する。accuracyが大きいだけのfixは上で処理を継続する。
        appendDiagnosticEvent(SessionDiagnosticEvent(
          t: DateTime.now(),
          type: 'gps_bootstrap_unusable',
          details: {
            if (initialPos.accuracy.isFinite)
              'accuracyMeters': initialPos.accuracy,
            'timestamp': initialPos.timestamp.toUtc().toIso8601String(),
          },
        ));
        applySafetyAssessment(
          RiskAssessment(level: CollisionRiskLevel.lv0),
          DateTime.now(),
          AlertDataQuality.unusable,
        );
      }
      if (!isCurrentNavigation(generation)) return;
      await positionStreamSupervisor.start(
        streamFactory: () => geoService.getPositionStream(config_.accuracy),
        onData: (position) {
          isGpsStreamRecovering.value = false;
          gpsRecoveryProbeAttempted.value = false;
          final recoveryStartedAt = gpsStreamRecoveryStartedAt.value;
          if (recoveryStartedAt != null) {
            gpsStreamRecoveryStartedAt.value = null;
            appendRuntimeDiagnostic('gps_stream_recovered', {
              'recoveryDurationMs':
                  DateTime.now().difference(recoveryStartedAt).inMilliseconds,
              'accuracyMeters': _finiteOrNull(position.accuracy),
            });
          }
          enqueuePosition(position, generation);
        },
        onError: (Object error, StackTrace stackTrace) {
          debugPrint(
              'Position stream error; automatic recovery scheduled: $error');
          if (!isCurrentNavigation(generation)) return;
          final now = DateTime.now();
          final streamSilence = error is TimeoutException;
          isGpsStreamRecovering.value = true;
          gpsStreamRecoveryStartedAt.value ??= now;
          final health = gpsHealth.value.markUnusable(now);
          recordGpsQualityIfChanged(health, now);
          appendDiagnosticEvent(SessionDiagnosticEvent(
            t: now,
            type: 'gps_stream_error',
            details: {
              'errorType': error.runtimeType.toString(),
              'recoveryScheduled': true,
              'retryAttempt': positionStreamSupervisor.retryAttempt + 1,
              'streamSilence': streamSilence,
              'silenceRecoverySeconds': gpsStreamSilenceRecoverySeconds,
              if (lastAcceptedGpsSpeedMetersPerSecond.value != null)
                'lastAcceptedRawSpeedMetersPerSecond':
                    lastAcceptedGpsSpeedMetersPerSecond.value,
              if (myBoat.value?.speed != null)
                'lastEstimatedSpeedMetersPerSecond': myBoat.value!.speed,
              if (lastValidGpsAt.value != null)
                'lastGpsAgeMs':
                    now.difference(lastValidGpsAt.value!).inMilliseconds,
            },
          ));
          recordGpsEnvironmentSnapshot('gps_stream_error', generation,
              details: {
                'retryAttempt': positionStreamSupervisor.retryAttempt + 1,
                'streamSilence': streamSilence,
                if (lastAcceptedGpsSpeedMetersPerSecond.value != null)
                  'lastAcceptedRawSpeedMetersPerSecond':
                      lastAcceptedGpsSpeedMetersPerSecond.value,
                if (myBoat.value?.speed != null)
                  'lastEstimatedSpeedMetersPerSecond': myBoat.value!.speed,
              });
          // 無通知停止ごとに単発測位は1回だけ行う。成功したfixは通常の
          // filter→Kalman→警告・記録・共有経路へ戻し、stream再購読も並行して
          // 続ける。再取得中もmyBoatと推定器は消さない。
          if (streamSilence &&
              !gpsRecoveryProbeAttempted.value &&
              !gpsRecoveryProbeInFlight.value) {
            gpsRecoveryProbeAttempted.value = true;
            gpsRecoveryProbeInFlight.value = true;
            appendRuntimeDiagnostic('gps_one_shot_recovery_started', {
              if (lastValidGpsAt.value != null)
                'lastGpsAgeMs':
                    now.difference(lastValidGpsAt.value!).inMilliseconds,
              if (lastAcceptedGpsSpeedMetersPerSecond.value != null)
                'lastAcceptedRawSpeedMetersPerSecond':
                    lastAcceptedGpsSpeedMetersPerSecond.value,
              if (myBoat.value?.speed != null)
                'lastEstimatedSpeedMetersPerSecond': myBoat.value!.speed,
            });
            unawaited(geoService
                .getCurrentPosition(config_.accuracy)
                .then((position) {
              if (!isCurrentNavigation(generation)) return;
              appendRuntimeDiagnostic('gps_one_shot_recovery_succeeded', {
                'accuracyMeters': _finiteOrNull(position.accuracy),
                'fixAgeMs': DateTime.now()
                    .difference(position.timestamp)
                    .inMilliseconds,
              });
              enqueuePosition(position, generation);
            }).catchError((Object probeError) {
              if (!isCurrentNavigation(generation)) return;
              appendRuntimeDiagnostic('gps_one_shot_recovery_failed', {
                'errorType': probeError.runtimeType.toString(),
              });
            }).whenComplete(() {
              gpsRecoveryProbeInFlight.value = false;
            }));
          }
          gpsLossAnnounced.value = true;
          applySafetyAssessment(
            RiskAssessment(level: CollisionRiskLevel.lv0),
            now,
            AlertDataQuality.unusable,
          );
        },
      );
      startGpsWatchdog();
    } catch (_) {
      if (generation == navigationGeneration.value) {
        navigationGeneration.value += 1;
      }
      publishingSetupGeneration.value += 1;
      publishingSetupInFlight.value = null;
      positionBatchCollector.clear();
      positionPublisher.stop();
      positionEstimator.reset();
      conservativePositionEstimator.reset();
      positionIntegrityMonitor.reset();
      safetyContractMonitor.reset();
      fixIngressPolicy.reset();
      estimatorClock.reset();
      lastDeadReckoningPredictionTick.value = null;
      previousEstimatedPosition.value = null;
      distanceIntegrator.reset();
      gpsWatchdog.value?.cancel();
      gpsWatchdog.value = null;

      Future<void> attempt(
        String label,
        Future<void> Function() operation,
      ) async {
        try {
          await operation();
        } catch (error) {
          debugPrint('$label after navigation start failure failed: $error');
        }
      }

      // 1つのplatform cleanup失敗で後続の資源解放を打ち切らない。
      await attempt(
          'Position subscription cancellation', positionStreamSupervisor.stop);
      await attempt('Dynamic obstacle subscription cancellation',
          dynamicObstacleStreamSupervisor.stop);
      await attempt('Temporary obstacle subscription cancellation',
          temporaryObstacleStreamSupervisor.stop);
      await attempt(
        'Shared calibration subscription cancellation',
        stopSharedCalibrationWatch,
      );
      await attempt('Alert audio stop', alert.stop);
      await attempt(
        'Position publisher shutdown',
        () => messageService
            .stopPublishing()
            .timeout(_publishingCleanupAckTimeout),
      );
      await attempt(
        'Remote position cleanup',
        () => messageService
            .clearMessage(config_.boatId)
            .timeout(_publishingCleanupAckTimeout),
      );
      final failedSessionId =
          sessionStartedAt.value?.millisecondsSinceEpoch.toString();
      await attempt('Session checkpoint drain', waitForSessionWrites);
      if (failedSessionId != null) {
        // 航行開始そのものが失敗した場合は、一覧に0秒の
        // 不完全セッションを残さない。
        await attempt(
          'Failed session checkpoint removal',
          () => sessionStoreService.deleteSession(failedSessionId),
        );
      }
      otherBoats.value = [];
      temporaryObstacles.value = [];
      obstacles.value = defaultObstacles.value;
      isWatching.value = false;
      isDynamicReceiveUnavailable.value = false;
      rawDynamicReceiveDegraded.value = false;
      receiveFaultDebouncer.value.reset();
      sharingCapabilityMonitor.reset();
      isSharingCapabilityUnconfirmed.value = false;
      publishingSetupNextRetryAt.value = null;
      gpsStreamRecoveryStartedAt.value = null;
      isGpsStreamRecovering.value = false;
      gpsRecoveryProbeAttempted.value = false;
      gpsRecoveryProbeInFlight.value = false;
      lastAcceptedGpsSpeedMetersPerSecond.value = null;
      lastAcceptedGpsAccuracyMeters.value = null;
      lastValidGpsTimestamp.value = null;
      gpsPollInFlight.value = false;
      lastGpsPollAt.value = null;
      gpsPollSucceededCount.value = 0;
      gpsPollFailedCount.value = 0;
      alertReArmWindow.value = {};
      lastFlappingReportAt.value = {};
      recentPositionArrivals.value = <Duration>[];
      audioDirectiveWhilePausedCount.value = 0;
      audioPresentationWhilePausedCount.value = 0;
      isTemporaryObstacleReceiveUnavailable.value = false;
      mode.value = NavMode.observer;
      config.value = null;
      sessionPoints.value = [];
      sessionAlertEvents.value = [];
      sessionDiagnosticEvents.value = [];
      sessionDiagnosticMetadata.value = null;
      diagnosticBoatAliases.value = {};
      diagnosticAlertAliases.value = {};
      diagnosticCandidates.value = {};
      lastDiagnosticAudioKey.value = null;
      lastDiagnosticGpsQuality.value = null;
      lastDiagnosticOrientation.value = null;
      lastDiagnosticHeartbeatTick.value = null;
      diagnosticSequence.value = 0;
      diagnosticEventDroppedCount.value = 0;
      alertEventDroppedCount.value = 0;
      warningPresenter.value.reset();
      sessionStartedAt.value = null;
      lastSessionCheckpointTick.value = null;
      lastCheckpointSummary.value = null;
      lastCheckpointSummaryTick.value = null;
      lastAlertObservationAt.value = {};
      pendingSessionWrite.value = null;
      myBoat.value = null;
      totalDistance.value = 0;
      currentBatteryLevel.value = null;
      lastBatteryReadAt.value = null;
      batteryReadInFlight.value = false;
      lastDiagnosticBatteryLevel.value = null;
      batteryReadFailureAnnounced.value = false;
      lastProcessedTick.value = null;
      lastProcessedWallClock.value = null;
      lastDiagnosticPositionGapAt.value = null;
      lastProcessingTimingSampleTick.value = null;
      safetyLevel.value = SafetyLevel.safe;
      currentWarning.value = null;
      audioDirective.value = null;
      audioDirectiveCategory.value = null;
      isAshore.value = false;
      ashoreDetector.value?.reset();
      lastAshoreState.value = AshoreState.initial;
      activeWarnings.value = const [];
      activeWarningCount.value = 0;
      safetyRunMode.value = SafetyRunMode.stopped;
      safetyOrchestrator.value = null;
      safetyClock.value.stop();
      isPipelineUnresponsive.value = false;
      pipelineRecoveryNeedsAssessment.value = false;
      safetyTimerStalled.value = false;
      safetyEvaluationStalled.value = false;
      safetyEvaluationLiveness.value.reset();
      isPositionSharingUnavailable.value = false;
      positionSharingDiagnosticState.value = null;
      messageSessionId.value = null;
      messageSequence.value = 0;
      rethrow;
    } finally {
      navigationStartInProgress.value = false;
      isTransitioning.value = false;
    }
  }

  Future<void> stopNavigation() async {
    if (navigationStopInProgress.value) return;
    if (navigationStartInProgress.value) {
      throw StateError('航行開始処理中です。完了後に再試行してください。');
    }
    navigationStopInProgress.value = true;
    isTransitioning.value = true;
    final myStopGeneration = ++stopGeneration.value;
    final stopWatch = Stopwatch()..start();
    const stopBudget = NavigationStopBudget();
    final boatId = config.value?.boatId;

    bool isCurrentStop() => isCurrentStopGeneration(
          expected: myStopGeneration,
          current: stopGeneration.value,
        );

    Future<bool> attempt(
      String label,
      Future<void> Function() operation, {
      Duration? timeout,
    }) async {
      final stepTimeout = stopBudget.timeoutFor(
        stopWatch.elapsed,
        preferredTimeout: timeout,
      );
      if (stepTimeout == null) {
        if (isCurrentStop()) {
          appendRuntimeDiagnostic('navigation_stop_step_skipped', {
            'step': label,
            'elapsedMs': stopWatch.elapsedMilliseconds,
          });
        }
        return false;
      }
      try {
        await operation().timeout(stepTimeout);
      } catch (error) {
        if (isCurrentStop()) {
          appendRuntimeDiagnostic('navigation_stop_step_failed', {
            'step': label,
            'errorType': error.runtimeType.toString(),
            'timeoutMs': stepTimeout.inMilliseconds,
          });
        }
        debugPrint('$label during navigation stop failed: $error');
        return false;
      }
      return isCurrentStop();
    }

    try {
      if (sessionStartedAt.value != null) {
        appendDiagnosticEvent(SessionDiagnosticEvent(
          t: DateTime.now(),
          type: 'navigation_stopping',
          details: {
            'pointCount': sessionPoints.value.length,
            'alertEventCount': sessionAlertEvents.value.length,
            'diagnosticEventCount': sessionDiagnosticEvents.value.length,
            'totalDistanceMeters': totalDistance.value,
            'activeWarningCount': activeWarningCount.value,
            'positionSharingUnavailable': isPositionSharingUnavailable.value,
          },
        ));
      }
      // 最初に不完全スナップショットを保存する。以降の端末処理や通信が
      // 詰まっても、練習の軌跡と終了開始の痕跡だけは端末へ残す。
      final checkpoint = buildSessionSnapshot(isComplete: false);
      if (checkpoint != null) {
        queueSessionWrite(checkpoint);
        await attempt(
          'Stop-start checkpoint',
          waitForSessionWrites,
          timeout: navigationStopCheckpointTimeout,
        );
      }
      if (!isCurrentStop()) return;

      // 先に世代を無効化し、実行中の古い判定による状態更新を止める。
      navigationGeneration.value += 1;
      publishingSetupGeneration.value += 1;
      publishingSetupInFlight.value = null;
      positionBatchCollector.clear();
      // 先に送信mailboxを止め、待機中の古い位置を破棄する。
      // 実行中のnative writeは取消不能だが、この後のclearを同じ
      // Firebase接続へqueueすることで最終状態を削除にする。
      positionPublisher.stop();
      currentWarning.value = null;
      audioDirective.value = null;
      audioDirectiveCategory.value = null;
      isAshore.value = false;
      ashoreDetector.value?.reset();
      lastAshoreState.value = AshoreState.initial;
      activeWarnings.value = const [];
      activeWarningCount.value = 0;
      gpsWatchdog.value?.cancel();
      gpsWatchdog.value = null;

      // 新しい入力源を先に止める。各購読は独立に停止し、
      // 1本のcancel例外で他の購読を残さない。
      await attempt(
          'Position subscription cancellation', positionStreamSupervisor.stop);
      await attempt('Dynamic obstacle subscription cancellation',
          dynamicObstacleStreamSupervisor.stop);
      await attempt('Temporary obstacle subscription cancellation',
          temporaryObstacleStreamSupervisor.stop);
      await attempt(
        'Shared calibration subscription cancellation',
        stopSharedCalibrationWatch,
      );

      // 実行中の端末内GPS処理と、それがqueueした最後の
      // チェックポイントが完了してから完成版で上書きする。
      await attempt('Position drain', () async => positionDrainFuture.value);
      await attempt('Session checkpoint drain', waitForSessionWrites);

      await attempt(
        'Position publisher shutdown',
        () => messageService
            .stopPublishing()
            .timeout(_publishingCleanupAckTimeout),
      );
      if (boatId != null) {
        await attempt(
          'Remote position cleanup',
          () => messageService
              .clearMessage(boatId)
              .timeout(_publishingCleanupAckTimeout),
        );
      }

      final summaryNow = DateTime.now();
      appendRuntimeDiagnostic('session_summary', {
        'pointCount': sessionPoints.value.length,
        'alertEventCount': sessionAlertEvents.value.length,
        'diagnosticEventCount': sessionDiagnosticEvents.value.length,
        'diagnosticEventDroppedCount': diagnosticEventDroppedCount.value,
        'alertEventDroppedCount': alertEventDroppedCount.value,
        'totalDistanceMeters': totalDistance.value,
        'durationMs': sessionStartedAt.value == null
            ? null
            : summaryNow.difference(sessionStartedAt.value!).inMilliseconds,
        'lastGpsAgeMs': lastValidGpsAt.value == null
            ? null
            : summaryNow.difference(lastValidGpsAt.value!).inMilliseconds,
        'audioIsPlaying': alert.isPlaying,
        'audioError': alert.error.value,
        'positionSharingState': positionSharingDiagnosticState.value,
        'pipelineUnresponsive': isPipelineUnresponsive.value,
      });
      updateDiagnosticMetadataCounts();

      appendRuntimeDiagnostic('final_session_save_started', {
        'pointCount': sessionPoints.value.length,
        'diagnosticEventCount': sessionDiagnosticEvents.value.length,
      });
      final session = buildSessionSnapshot(isComplete: true);
      if (session != null) {
        await attempt('Final session save', () async {
          await sessionStoreService.saveSession(session);
          if (kDebugMode) debugPrint('Session saved: ${session.id}');
        });
      }

      // 音声停止は最終セッション保存の後へ回す。AudioPlayerが応答しなくても
      // 航行終了・記録保存・画面復帰を待たせない。
      unawaited(attempt('Alert audio stop', alert.stop));
    } finally {
      if (isCurrentStop()) {
        // UIはcleanup中の数秒だけ航行中表示を維持し、ここで初めて
        // observerに戻す。開始・監視ボタンの早期再表示による競合を防ぐ。
        otherBoats.value = [];
        receivedPracticeLogMessages.value = const [];
        temporaryObstacles.value = [];
        obstacles.value = defaultObstacles.value;
        isWatching.value = false;
        isTemporaryObstacleReceiveUnavailable.value = false;
        isSharedSafetyCalibrationSyncUnavailable.value = false;
        sessionPoints.value = [];
        sessionAlertEvents.value = [];
        sessionDiagnosticEvents.value = [];
        sessionDiagnosticMetadata.value = null;
        diagnosticBoatAliases.value = {};
        diagnosticAlertAliases.value = {};
        diagnosticCandidates.value = {};
        lastDiagnosticAudioKey.value = null;
        lastDiagnosticGpsQuality.value = null;
        lastDiagnosticOrientation.value = null;
        sessionStartedAt.value = null;
        lastSessionCheckpointTick.value = null;
        lastCheckpointSummary.value = null;
        lastCheckpointSummaryTick.value = null;
        lastAlertObservationAt.value = {};
        pendingSessionWrite.value = null;
        myBoat.value = null;
        config.value = null;
        safetyLevel.value = SafetyLevel.safe;
        currentWarning.value = null;
        audioDirective.value = null;
        audioDirectiveCategory.value = null;
        isAshore.value = false;
        ashoreDetector.value?.reset();
        lastAshoreState.value = AshoreState.initial;
        activeWarnings.value = const [];
        activeWarningCount.value = 0;
        safetyRunMode.value = SafetyRunMode.stopped;
        safetyOrchestrator.value = null;
        safetyClock.value.stop();
        isPipelineUnresponsive.value = false;
        pipelineRecoveryNeedsAssessment.value = false;
        safetyTimerStalled.value = false;
        safetyEvaluationStalled.value = false;
        safetyEvaluationLiveness.value.reset();
        isPositionSharingUnavailable.value = false;
        positionSharingDiagnosticState.value = null;
        isDynamicReceiveUnavailable.value = false;
        rawDynamicReceiveDegraded.value = false;
        receiveFaultDebouncer.value.reset();
        sharingCapabilityMonitor.reset();
        isSharingCapabilityUnconfirmed.value = false;
        publishingSetupFailureKind.value = null;
        publishingSetupNextRetryAt.value = null;
        gpsStreamRecoveryStartedAt.value = null;
        isGpsStreamRecovering.value = false;
        gpsRecoveryProbeAttempted.value = false;
        gpsRecoveryProbeInFlight.value = false;
        lastAcceptedGpsSpeedMetersPerSecond.value = null;
        lastAcceptedGpsAccuracyMeters.value = null;
        lastValidGpsTimestamp.value = null;
        gpsPollInFlight.value = false;
        lastGpsPollAt.value = null;
        gpsPollSucceededCount.value = 0;
        gpsPollFailedCount.value = 0;
        alertReArmWindow.value = {};
        lastFlappingReportAt.value = {};
        recentPositionArrivals.value = <Duration>[];
        audioDirectiveWhilePausedCount.value = 0;
        audioPresentationWhilePausedCount.value = 0;
        messageSessionId.value = null;
        messageSequence.value = 0;
        lastProcessedTick.value = null;
        lastProcessedWallClock.value = null;
        lastDiagnosticPositionGapAt.value = null;
        lastProcessingTimingSampleTick.value = null;
        positionEstimator.reset();
        conservativePositionEstimator.reset();
        positionIntegrityMonitor.reset();
        safetyContractMonitor.reset();
        fixIngressPolicy.reset();
        estimatorClock.reset();
        lastDeadReckoningPredictionTick.value = null;
        previousEstimatedPosition.value = null;
        distanceIntegrator.reset();
        preRawPos.value = null;
        preHeading.value = 0;
        currentBatteryLevel.value = null;
        lastBatteryReadAt.value = null;
        batteryReadInFlight.value = false;
        lastDiagnosticBatteryLevel.value = null;
        batteryReadFailureAnnounced.value = false;
        mode.value = NavMode.observer;
        navigationStopInProgress.value = false;
        isTransitioning.value = false;
      }
    }
  }

  useOnAppLifecycleStateChange((previous, current) {
    if (mode.value != NavMode.navigator) return;
    appendDiagnosticEvent(SessionDiagnosticEvent(
      t: DateTime.now(),
      type: 'app_lifecycle_changed',
      details: {
        if (previous != null) 'from': previous.name,
        'to': current.name,
        'audioIsPlaying': alert.isPlaying,
        'audioError': alert.error.value,
        'gpsStreamWatching': isWatching.value,
        'positionSharingUnavailable': isPositionSharingUnavailable.value,
      },
    ));
    scheduleAudioRouteSnapshot('app_lifecycle_changed');
  });

  final metricsObserver = useMemoized(
    () => _NavigationMetricsObserver(recordOrientationIfChanged),
  );

  void queueRecoveryDiagnostic(SessionDiagnosticEvent event) {
    if (mode.value == NavMode.navigator && sessionStartedAt.value != null) {
      appendDiagnosticEvent(event);
    } else if (pendingPreSessionDiagnostics.value.length < 20) {
      pendingPreSessionDiagnostics.value.add(event);
    }
  }

  Future<void> probeRecoverableSession() async {
    if (recoveryProbeDone.value) return;
    recoveryProbeDone.value = true;
    try {
      final sessions = await sessionStoreService.listSessions();
      Session? incomplete;
      for (final session in sessions) {
        if (!session.isComplete) {
          incomplete = session;
          break;
        }
      }
      if (incomplete == null) return;
      final now = DateTime.now();
      final previousSequence = incomplete.diagnosticEvents.fold<int>(
        0,
        (current, event) => math.max(current, event.sequence ?? 0),
      );
      final recoveryEvent = SessionDiagnosticEvent(
        sequence: previousSequence + 1,
        t: now,
        type: 'session_recovery_detected',
        details: {
          'sessionId': incomplete.id,
          'startedAt': incomplete.startedAt.toUtc().toIso8601String(),
          'endedAt': incomplete.endedAt.toUtc().toIso8601String(),
          'ageMs': now.difference(incomplete.endedAt).inMilliseconds,
          'pointCount': incomplete.points.length,
          'alertEventCount': incomplete.alertEvents.length,
          'diagnosticEventCount': incomplete.diagnosticEvents.length,
          'lastDiagnosticEventType': incomplete.diagnosticEvents.isEmpty
              ? null
              : incomplete.diagnosticEvents.last.type,
        },
      );
      try {
        await sessionStoreService.saveSession(
          incomplete.copyWith(
            diagnosticEvents: [
              ...incomplete.diagnosticEvents,
              recoveryEvent,
            ],
          ),
        );
      } catch (error) {
        queueRecoveryDiagnostic(SessionDiagnosticEvent(
          t: now,
          type: 'session_recovery_save_failed',
          details: {
            'sessionId': incomplete.id,
            'errorType': error.runtimeType.toString(),
          },
        ));
      }
    } catch (error) {
      queueRecoveryDiagnostic(SessionDiagnosticEvent(
        t: DateTime.now(),
        type: 'session_recovery_probe_failed',
        details: {'errorType': error.runtimeType.toString()},
      ));
    }
  }

  useEffect(() {
    WidgetsBinding.instance.addObserver(metricsObserver);
    return () => WidgetsBinding.instance.removeObserver(metricsObserver);
  }, [metricsObserver]);

  useEffect(() {
    unawaited(reloadDefaultObstaclesForMap());
    loadWarningTime();
    unawaited(probeRecoverableSession());
    return () {
      final boatId = config.value?.boatId;
      final drain = positionDrainFuture.value;
      if (sessionStartedAt.value != null) {
        appendDiagnosticEvent(SessionDiagnosticEvent(
          t: DateTime.now(),
          type: 'navigation_widget_disposed',
        ));
      }
      final recoverableSession = buildSessionSnapshot(isComplete: false);
      // 破棄後に、timeout済みの古い終了処理が Hook の状態へ戻ってきても
      // 何も書けないよう、終了世代も無効化する。
      stopGeneration.value += 1;
      navigationGeneration.value += 1;
      publishingSetupGeneration.value += 1;
      publishingSetupInFlight.value = null;
      positionBatchCollector.clear();
      positionPublisher.stop();
      positionEstimator.reset();
      conservativePositionEstimator.reset();
      positionIntegrityMonitor.reset();
      safetyContractMonitor.reset();
      fixIngressPolicy.reset();
      estimatorClock.reset();
      lastDeadReckoningPredictionTick.value = null;
      previousEstimatedPosition.value = null;
      distanceIntegrator.reset();
      safetyClock.value.stop();
      gpsWatchdog.value?.cancel();
      // stop()は最初のawaitより前に_running=falseを同期反映する。
      // Futureブロックへ遅延せず、破棄後callbackをこの場で無効化する。
      final positionStop = positionStreamSupervisor.stop();
      final dynamicStop = dynamicObstacleStreamSupervisor.stop();
      final temporaryStop = temporaryObstacleStreamSupervisor.stop();
      sharedCalibrationSyncGeneration.value += 1;
      sharedCalibrationCoalesceTimer.value?.cancel();
      sharedCalibrationCoalesceTimer.value = null;
      sharedCalibrationSyncPolicy.endListening();
      final sharedCalibrationStop = sharedCalibrationStreamSupervisor.stop();
      final alertStop = alert.stop();
      // Hookの破棄後にStateを書き換えないよう、必要な資源だけを退避して
      // 非同期解放する。Firebase ACKは待たず、送信受付停止後のclearを
      // 同じ接続へ最後にqueueして幽霊艇を残さない。
      unawaited(Future<void>(() async {
        Future<void> attempt(
          String label,
          Future<void> Function() operation,
        ) async {
          try {
            await operation();
          } catch (e) {
            debugPrint('$label during navigation disposal failed: $e');
          }
        }

        await attempt(
          'Position subscription cancellation',
          () => positionStop,
        );
        await attempt(
          'Dynamic obstacle subscription cancellation',
          () => dynamicStop,
        );
        await attempt(
          'Static obstacle subscription cancellation',
          () => temporaryStop,
        );
        await attempt(
          'Shared calibration subscription cancellation',
          () => sharedCalibrationStop,
        );
        await attempt('Alert audio stop', () => alertStop);
        await attempt('Position drain', () async => drain);
        await attempt('Session checkpoint drain', waitForSessionWrites);
        if (recoverableSession != null) {
          // route破棄やOSによるWidget終了でも、最新のメモリ上の
          // 記録を次回の一覧から回復できるよう最後に1回保存する。
          await attempt(
            'Recoverable session save',
            () => sessionStoreService.saveSession(recoverableSession),
          );
        }
        await attempt(
          'Position publisher shutdown',
          () => messageService
              .stopPublishing()
              .timeout(_publishingCleanupAckTimeout),
        );
        if (boatId != null) {
          await attempt(
            'Remote position cleanup',
            () => messageService
                .clearMessage(boatId)
                .timeout(_publishingCleanupAckTimeout),
          );
        }
      }));
    };
  }, []);

  // 陸上判定が変わった瞬間に音を止める・戻す。
  //
  // **`isAshore` を `useEffect` の依存にしてはいけない。** それだと
  // フレームが回らない背面で切り替わりを取りこぼす。`ValueNotifier` の
  // listener はフレームを介さず同期的に走るので、背面でも即座に効く。
  // 判定・表示・記録・位置共有は陸上でも従来どおり続く(原則1)。
  useEffect(() {
    void handleAshoreChanged() {
      warningPresenter.value.apply(
        audioDirective.value,
        ashore: isAshore.value,
        category: audioDirectiveCategory.value,
      );
    }

    isAshore.addListener(handleAshoreChanged);
    return () => isAshore.removeListener(handleAshoreChanged);
  }, const []);

  return UseNavigator(
    config: config,
    mode: mode,
    safetyLevel: safetyLevel,
    currentWarning: currentWarning,
    activeWarnings: activeWarnings,
    activeWarningCount: activeWarningCount,
    safetyRunMode: safetyRunMode,
    warningTimeSeconds: warningTimeSeconds,
    myBoat: myBoat,
    otherBoats: otherBoats,
    receivedPracticeLogMessages: receivedPracticeLogMessages,
    obstacles: obstacles,
    channelCenterline: channelCenterline,
    channelLaneResolver: channelLaneResolver,
    gpsQuality: gpsQuality,
    isGpsStreamRecovering: isGpsStreamRecovering,
    isPositionSharingUnavailable: isPositionSharingUnavailable,
    isSharingCapabilityUnconfirmed: isSharingCapabilityUnconfirmed,
    isAudioOutputVolumeLow: isAudioOutputVolumeLow,
    isDynamicReceiveUnavailable: isDynamicReceiveUnavailable,
    isTemporaryObstacleReceiveUnavailable:
        isTemporaryObstacleReceiveUnavailable,
    isSharedSafetyCalibrationSyncUnavailable:
        isSharedSafetyCalibrationSyncUnavailable,
    safetySettingsLabel: safetySettingsLabel,
    safetySettingsNeedsAttention: safetySettingsNeedsAttention,
    dangerZoneSettingsSource: dangerZoneSettingsSource,
    appliedSharedSafetyRevision: appliedSharedSafetyRevision,
    pendingSharedSafetyRevision: pendingSharedSafetyRevision,
    isWatching: isWatching,
    isTransitioning: isTransitioning,
    preProcessTime: preProcessTime,
    postProcessTime: postProcessTime,
    sessionStartedAt: sessionStartedAt,
    totalDistance: totalDistance,
    batteryLevel: currentBatteryLevel,
    spm: strokeRate.spm,
    strokeMotion: strokeRate.motion,
    latestStrokeTrace: strokeRate.latestStrokeTrace,
    strokeTraceWindow: strokeRate.traceWindow,
    audioError: alert.error,
    getCurrentPosition: getCurrentPosition,
    startNavigation: startNavigation,
    checkAudio: checkAudio,
    testAudio: testAudio,
    playCoachAnomalyAlert: playCoachAnomalyAlert,
    isAshore: isAshore,
    overrideAshoreToWater: overrideAshoreToWater,
    stopNavigation: stopNavigation,
    startWatching: () => startWatching(),
    stopWatching: stopRealtimeWatch,
    reloadDefaultObstacles: reloadDefaultObstaclesForMap,
    applyNavigationObstacleSettings: applyNavigationObstacleSettings,
    applyWarningLeadTimesDuringNavigation:
        applyWarningLeadTimesDuringNavigation,
    applyPendingSharedSafetySettings: applyPendingSharedSafetySettings,
  );
}

class UseNavigator {
  final ValueNotifier<NavConfig?> config;
  final ValueNotifier<NavMode> mode;
  final ValueNotifier<SafetyLevel> safetyLevel;
  final ValueNotifier<NavigationWarning?> currentWarning;
  final ValueNotifier<List<NavigationWarning>> activeWarnings;
  final ValueNotifier<int> activeWarningCount;
  final ValueNotifier<SafetyRunMode> safetyRunMode;
  final ValueNotifier<double> warningTimeSeconds;
  final ValueNotifier<Boat?> myBoat;
  final ValueNotifier<List<Boat>> otherBoats;
  final ValueNotifier<List<Message>> receivedPracticeLogMessages;
  final ValueNotifier<List<StaticObstacle>> obstacles;
  final ValueNotifier<ChannelCenterline?> channelCenterline;
  final ValueNotifier<ChannelLaneResolver?> channelLaneResolver;
  final ValueNotifier<GpsHealthQuality> gpsQuality;
  final ValueNotifier<bool> isGpsStreamRecovering;
  final ValueNotifier<bool> isPositionSharingUnavailable;

  /// 位置共有の能力が確認できない状態。**表示のみ。音は足さない。**
  ///
  /// 「他艇がいない」とは区別する。0隻は正常状態でもあり得るので、
  /// 隻数ではなく能力(購読接続・送信設定・認可)を見ている。
  final ValueNotifier<bool> isSharingCapabilityUnconfirmed;

  /// 端末の出力音量が低い。**表示のみ。音は足さない。**
  final ValueNotifier<bool> isAudioOutputVolumeLow;
  final ValueNotifier<bool> isDynamicReceiveUnavailable;

  /// 陸上と判定して警告音を止めている状態。
  /// 検知・表示・記録・位置共有は止まっていない。
  final ValueNotifier<bool> isAshore;

  /// 陸上判定を手動で解除する。
  final void Function() overrideAshoreToWater;
  final ValueNotifier<bool> isTemporaryObstacleReceiveUnavailable;
  final ValueNotifier<bool> isSharedSafetyCalibrationSyncUnavailable;
  final ValueNotifier<String> safetySettingsLabel;
  final ValueNotifier<bool> safetySettingsNeedsAttention;
  final ValueNotifier<DangerZoneSettingsSource?> dangerZoneSettingsSource;
  final ValueNotifier<int?> appliedSharedSafetyRevision;
  final ValueNotifier<int?> pendingSharedSafetyRevision;
  final ValueNotifier<bool> isWatching;
  final ValueNotifier<bool> isTransitioning;
  final ValueNotifier<DateTime> preProcessTime;
  final ValueNotifier<DateTime> postProcessTime;
  final ValueNotifier<DateTime?> sessionStartedAt;
  final ValueNotifier<double> totalDistance;
  final ValueNotifier<int?> batteryLevel;
  final ValueNotifier<double?> spm;
  final ValueNotifier<RowingMotionMetrics?> strokeMotion;

  /// 直近1ストロークの共有用波形。監視共有がONのときだけ送られる。
  final ValueNotifier<SharedStrokeTrace?> latestStrokeTrace;

  /// 艇速変化グラフ1画面ぶんの切り出し。**表示専用**で、安全経路は読まない。
  final StrokeSpeedTraceWindow? Function({
    required DateTime now,
    double? windowSeconds,
  }) strokeTraceWindow;
  final ValueNotifier<String?> audioError;
  final Future<Position> Function(LocationAccuracy accuracy) getCurrentPosition;
  final Future<void> Function(NavConfig config) startNavigation;
  final Future<bool> Function() checkAudio;
  final Future<bool> Function() testAudio;

  /// 監視モードで異常を検知したときに鳴らす通知音。
  final Future<void> Function() playCoachAnomalyAlert;
  final Future<void> Function() stopNavigation;
  final Future<void> Function() startWatching;
  final Future<void> Function() stopWatching;
  final Future<void> Function() reloadDefaultObstacles;
  final Future<bool> Function({
    required String key,
    required Object? from,
    required Object? to,
    int? sharedRevision,
  }) applyNavigationObstacleSettings;
  final Future<void> Function(
    WarningLeadTimes previous,
    int? sharedRevision,
  ) applyWarningLeadTimesDuringNavigation;
  final Future<void> Function() applyPendingSharedSafetySettings;

  UseNavigator({
    required this.config,
    required this.mode,
    required this.safetyLevel,
    required this.currentWarning,
    required this.activeWarnings,
    required this.activeWarningCount,
    required this.safetyRunMode,
    required this.warningTimeSeconds,
    required this.myBoat,
    required this.otherBoats,
    required this.receivedPracticeLogMessages,
    required this.obstacles,
    required this.channelCenterline,
    required this.channelLaneResolver,
    required this.gpsQuality,
    required this.isGpsStreamRecovering,
    required this.isPositionSharingUnavailable,
    required this.isSharingCapabilityUnconfirmed,
    required this.isAudioOutputVolumeLow,
    required this.isDynamicReceiveUnavailable,
    required this.isAshore,
    required this.overrideAshoreToWater,
    required this.isTemporaryObstacleReceiveUnavailable,
    required this.isSharedSafetyCalibrationSyncUnavailable,
    required this.safetySettingsLabel,
    required this.safetySettingsNeedsAttention,
    required this.dangerZoneSettingsSource,
    required this.appliedSharedSafetyRevision,
    required this.pendingSharedSafetyRevision,
    required this.isWatching,
    required this.isTransitioning,
    required this.preProcessTime,
    required this.postProcessTime,
    required this.sessionStartedAt,
    required this.totalDistance,
    required this.batteryLevel,
    required this.spm,
    required this.strokeMotion,
    required this.latestStrokeTrace,
    required this.strokeTraceWindow,
    required this.audioError,
    required this.getCurrentPosition,
    required this.startNavigation,
    required this.checkAudio,
    required this.testAudio,
    required this.playCoachAnomalyAlert,
    required this.stopNavigation,
    required this.startWatching,
    required this.stopWatching,
    required this.reloadDefaultObstacles,
    required this.applyNavigationObstacleSettings,
    required this.applyWarningLeadTimesDuringNavigation,
    required this.applyPendingSharedSafetySettings,
  });
}
