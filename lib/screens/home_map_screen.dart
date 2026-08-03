import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/providers/nav_config_providers.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_setting_modal.dart';
import 'package:rowing_navigator/features/home_map/widgets/navigation_safety_settings_sheet.dart';

import '../config/boat_config.dart';
import '../config/coach_config.dart';
import '../config/map_style_config.dart';
import '../config/navigator_config.dart';
import '../features/home_map/widgets/boat_list_panel.dart';
import '../features/home_map/widgets/boat_status_card.dart';
import '../features/home_map/widgets/background_location_disclosure_dialog.dart';
import '../features/home_map/widgets/ashore_notice.dart';
import '../features/home_map/widgets/observer_priority_banner.dart';
import '../features/home_map/widgets/observer_status_icon.dart';
import '../features/home_map/widgets/map_menu_sheet.dart';
import '../features/home_map/widgets/map_type_switcher.dart';
import '../features/home_map/widgets/navigation_status_panel.dart';
import '../features/home_map/widgets/rounded_button.dart';
import '../features/home_map/widgets/safety_banner.dart';
import '../features/home_map/widgets/stroke_trace_sheet.dart';
import '../hooks/use_coach_watch.dart';
import '../hooks/use_practice_log_recording.dart';
import '../hooks/use_stroke_trace_sharing.dart';
import '../hooks/use_tracking.dart';
import '../services/collision_risk_evaluator_service.dart';
import '../services/map_render_update_policy.dart';
import '../services/safety_shape_overlay_service.dart';
import '../services/rowing_motion_fusion.dart';
import '../services/swept_outline_service.dart';
import '../types/tracking_mode.dart';
import '../utils/rowing_navigation.dart';
import '../widgets/map_control_button.dart';
import '../widgets/app_state_views.dart';
import '../models/navigable_water.dart';
import '../models/navigation_warning.dart';
import '../theme/app_theme.dart';
import '../theme/hazard_palette.dart';
import '../theme/map_layer_spec.dart';
import '../utils/tactile_feedback.dart';
import '../hooks/use_navigator.dart';
import '../hooks/use_nav_map.dart';
import '../models/nav_config_model.dart';
import '../services/auth_service.dart';
import '../services/map_display_settings_service.dart';
import '../services/navigation_defaults_service.dart';
import '../services/permission_service.dart';
import '../services/preset_obstacle_service.dart';
import '../services/team_service.dart';
import '../types/marker_type.dart';
import '../types/nav_mode.dart';
import 'app_entry_gate.dart';
import 'area_setting_screen.dart';
import 'danger_zone_settings_screen.dart';
import 'fixed_obstacle_calibration_screen.dart';
import 'device_status_screen.dart';
import 'record_list_screen.dart';
import 'practice_log_list_screen.dart';
import 'usage_guide_screen.dart';
import 'team_screen.dart';

const _sakuragawaFallbackCenter = LatLng(36.069, 140.208);

/// 自艇を画面上端から `navigationSelfBoatScreenRatio` の位置へ置くための
/// カメラパディング。上寄せ(比率 < 0.5)なら下側へ入れる。
EdgeInsets _selfBoatCameraPadding(double mapHeight) {
  if (!mapHeight.isFinite || mapHeight <= 0) return EdgeInsets.zero;
  final shift = mapHeight * (2 * navigationSelfBoatScreenRatio - 1);
  return shift >= 0
      ? EdgeInsets.only(top: shift)
      : EdgeInsets.only(bottom: -shift);
}

enum _NavigationStartRecoveryAction {
  none,
  locationSettings,
  audioCheck,
}

class _NavigationStartRecovery {
  final String message;
  final String? actionLabel;
  final _NavigationStartRecoveryAction action;

  const _NavigationStartRecovery({
    required this.message,
    this.actionLabel,
    this.action = _NavigationStartRecoveryAction.none,
  });
}

_NavigationStartRecovery _navigationStartRecoveryFor(Object error) {
  final detail = error.toString().replaceFirst('Bad state: ', '');
  final normalized = detail.toLowerCase();
  if (detail.contains('音声') || detail.contains('警告音')) {
    return const _NavigationStartRecovery(
      message: '警告音を準備できません。端末の音量と音声出力を確認してください。',
      actionLabel: '音声確認',
      action: _NavigationStartRecoveryAction.audioCheck,
    );
  }
  if (detail.contains('権限') ||
      detail.contains('位置情報サービス') ||
      detail.contains('位置情報の利用許可')) {
    return const _NavigationStartRecovery(
      message: '位置情報を利用できません。端末の位置情報設定を確認してください。',
      actionLabel: '位置情報設定',
      action: _NavigationStartRecoveryAction.locationSettings,
    );
  }
  if (detail.contains('GPS') ||
      normalized.contains('timeout') ||
      detail.contains('現在地') ||
      detail.contains('位置を取得')) {
    return const _NavigationStartRecovery(
      message: 'GPSを十分に受信できません。空が見える屋外へ移動して、同じ画面から再試行してください。',
    );
  }
  if (detail.contains('危険区域') ||
      normalized.contains('firebase') ||
      normalized.contains('network') ||
      normalized.contains('connection') ||
      detail.contains('通信')) {
    return const _NavigationStartRecovery(
      message: '通信データを準備できません。通信状態を確認し、同じ画面から再試行してください。',
    );
  }
  return _NavigationStartRecovery(
    message: '航行の準備を完了できませんでした。同じ画面から再試行してください。\n$detail',
  );
}

Future<bool> _confirmBackgroundLocationUse(BuildContext context) async {
  final currentPermission = await Geolocator.checkPermission();
  if (currentPermission == LocationPermission.always) return true;
  if (!context.mounted) return false;

  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const BackgroundLocationDisclosureDialog(),
      ) ??
      false;
}

void _returnToTeamEntry(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const AppEntryGate()),
    (_) => false,
  );
}

class HomeMapScreen extends HookConsumerWidget {
  const HomeMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hooks
    final navigator = useNavigator();
    final navMap = useNavMap();
    final tracking = useTracking();
    final auth = AuthService();
    final coachWatch = useCoachWatch(
      otherBoats: navigator.otherBoats.value,
      enabled: navigator.mode.value == NavMode.observer &&
          navigator.isWatching.value,
      channelCenterline: navigator.channelCenterline.value,
      channelLaneResolver: navigator.channelLaneResolver.value,
    );
    final practiceLogRecording = usePracticeLogRecording(
      enabled: navigator.mode.value == NavMode.observer &&
          navigator.isWatching.value,
      teamId: TeamService.activeMembership?.teamId,
      recordedBy: auth.currentUser?.uid,
      messages: navigator.receivedPracticeLogMessages.value,
      anomalies: coachWatch.anomalies.value,
    );
    // State
    final loading = useState(true);
    final initLatLng = useState<LatLng?>(null);
    final initError = useState<String?>(null);
    final initAttempt = useState(0);
    final locationPermissionGranted = useState(false);
    final showInfo = useState(false);
    final showBoatList = useState(false);
    final shipDomains = useState<Set<Polygon>>({});
    // 停止距離の輪。ポリラインなので、監視モードの航跡と1つの集合へまとめて
    // 地図へ渡す(片方を設定するともう片方が消える事故を防ぐ)。
    final stoppingDistanceLines = useState<Set<Polyline>>({});
    final shipDomainRenderSnapshot = useRef<ShipDomainRenderSnapshot?>(null);
    final obstacles = useState<Set<Polygon>>({});
    // 開発者が明示的に有効化したときだけ判定形状を加える別レイヤー。
    // 通常の shipDomains はここへ判定用の拡張を混ぜない（不変条件6）。
    final developerSafetyShapeOverlay = useState<Set<Polygon>>({});
    // 航路(往路・復路)の帯。**表示専用**なので use_navigator(安全経路の
    // フック)へは通さず、画面側で直接読む。読めなくても航行・警告は
    // 従来どおり動く(原則1)。
    final navigableWaters = useState<List<NavigableWater>>(const []);
    final showChannelLanes = useState(true); // 既定ON
    final laneOverlay = useState<Set<Polygon>>({});
    // 直射日光下で危険区域を浮き上がらせる地図スタイル(端末内設定)。
    final highContrastMap = useState(false);
    final showDeveloperSafetyShapeOverlay = useState(false);
    // 計測と表示を分離する。表示OFFでもIMU融合とログは継続する。
    final strokeMotionDisplayEnabled = useState(false);
    useStrokeTraceSharing(
      // 監視への共有は計測と一体で、切替を持たない。オプションにするのは
      // 「自分の画面に出すか」だけ。共有先は位置共有と同じチーム内で、
      // 増える転送量は位置の1/20未満(2026-08-03 設計メモ)。
      // 共有は安全経路の外側。ここが失敗しても位置共有・警告は動き続ける。
      enabled: navigator.mode.value == NavMode.navigator &&
          (navigator.config.value?.strokeRateEnabled ?? false),
      boatId: navigator.config.value?.boatId,
      trace: navigator.latestStrokeTrace,
    );
    final mapDisplaySettings = useMemoized(MapDisplaySettingsService.new);
    final navigationDefaults = useMemoized(NavigationDefaultsService.new);
    final safetyShapeOverlayService =
        useMemoized(SafetyShapeOverlayService.new);
    final announcedImminentWarnings = useRef(<String>{});
    final previousSharedCalibrationFailure = useRef(false);
    final announcedCoachAnomalies = useRef(<String, DateTime>{});
    final lowBatteryNotificationShown = useRef(false);
    final gestureAutoRecenterTimer = useRef<Timer?>(null);
    // Services
    final permission = PermissionService();
    // Constants
    const locationAccuracy = LocationAccuracy.bestForNavigation;

    void showNavigationStartFailure(Object error) {
      final recovery = _navigationStartRecoveryFor(error);
      SnackBarAction? action;
      switch (recovery.action) {
        case _NavigationStartRecoveryAction.locationSettings:
          action = SnackBarAction(
            label: recovery.actionLabel!,
            onPressed: () async => Geolocator.openAppSettings(),
          );
          break;
        case _NavigationStartRecoveryAction.audioCheck:
          action = SnackBarAction(
            label: recovery.actionLabel!,
            onPressed: () async {
              final ok = await navigator.testAudio();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ok
                    ? '警告音を再生しました。実際に聞こえたことを確認してください。'
                    : '音声を再生できませんでした。端末の音量・消音設定を確認してください。'),
              ));
            },
          );
          break;
        case _NavigationStartRecoveryAction.none:
          break;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(recovery.message),
          duration: const Duration(seconds: 7),
          action: action,
        ));
    }

    focusP14y(double lat, double lng, double heading,
        {bool force = false, double? overrideZoomLevel}) async {
      // Focus programatically
      tracking.setProgFlag(true); // プログラムによる操作フラグを立てる
      try {
        final currentZoomLevel = await navMap.getZoomLevel();
        // 航行中に利用者が選んだ拡大・縮小倍率を保ったまま、現在地へ
        // 戻す。以前は縮小した場合に18へ戻ってしまっていた。
        //
        // [overrideZoomLevel] を渡すのは航行開始・監視開始の1回だけ。
        // 毎秒の追従・ジェスチャー後の自動復帰では渡さないため、利用者が
        // ピンチで選んだ倍率は上書きされない(原則2)。
        final zoomLevel = overrideZoomLevel ??
            zoomForMapRefocus(
              currentZoomLevel,
              fallbackZoomLevel: initialMapZoomLevel,
            );
        final moved =
            await navMap.focus(lat, lng, heading, zoomLevel, force: force);
        // 微小更新を省略した場合はonCameraIdleが呼ばれない。
        if (!moved) tracking.setProgFlag(false);
      } catch (_) {
        tracking.setProgFlag(false);
        rethrow;
      }
    }

    /// 監視中の全艇が収まる位置へカメラを引く。
    ///
    /// 監視者は陸上にいて端末を操作できるため、確認ダイアログは挟まない
    /// (誤操作しても自分でもう一度動かせる)。
    Future<void> fitAllWatchedBoats() async {
      final points = coachWatch.boatStatuses.value
          .map((status) => LatLng(status.boat.lat, status.boat.lng))
          .toList();
      if (points.isEmpty) return;
      // 自動追従に戻されないよう、プログラムによる操作として扱う。
      tracking.setProgFlag(true);
      try {
        await navMap.fitBounds(points);
      } catch (_) {
        // 地図が準備できていないだけ。監視表示はそのまま続く。
        tracking.setProgFlag(false);
      }
    }

    /// 監視中に指定した艇へカメラを寄せる。艇一覧・異常チップから使う。
    ///
    /// 倍率は `max(現在の倍率, watchFocusMinimumZoomLevel)`。引きすぎている
    /// ときだけ寄せ、すでに寄っているなら引き戻さない。
    Future<void> focusOnWatchedBoat(String boatId) async {
      final matches = coachWatch.boatStatuses.value
          .where((status) => status.boat.boatId == boatId);
      if (matches.isEmpty) return;
      final boat = matches.first.boat;
      double zoomLevel;
      try {
        final current = await navMap.getZoomLevel();
        zoomLevel = current.isFinite && current > watchFocusMinimumZoomLevel
            ? current
            : watchFocusMinimumZoomLevel;
      } catch (_) {
        zoomLevel = watchFocusMinimumZoomLevel;
      }
      tracking.setProgFlag(true);
      try {
        // heading に 0 を渡して地図を北固定にする。監視者の見ている向きを
        // 艇の向きで回すと、艇を選ぶたびに地図が回って読めなくなる。
        final moved =
            await navMap.focus(boat.lat, boat.lng, 0, zoomLevel, force: true);
        if (!moved) tracking.setProgFlag(false);
      } catch (_) {
        tracking.setProgFlag(false);
      }
    }

    void cancelGestureAutoRecenter() {
      gestureAutoRecenterTimer.value?.cancel();
      gestureAutoRecenterTimer.value = null;
    }

    void scheduleGestureAutoRecenter() {
      cancelGestureAutoRecenter();
      if (navigator.mode.value != NavMode.navigator ||
          !tracking.mode.value.allowsAutomaticRecentering) {
        return;
      }
      gestureAutoRecenterTimer.value = Timer(mapAutoRecenterDelay, () {
        gestureAutoRecenterTimer.value = null;
        if (navigator.mode.value != NavMode.navigator ||
            !tracking.mode.value.allowsAutomaticRecentering) {
          return;
        }
        tracking.setMode(TrackingMode.track);
        final myBoat = navigator.myBoat.value;
        if (myBoat == null) return;
        unawaited(focusP14y(
          myBoat.lat,
          myBoat.lng,
          rowingMapBearing(myBoat.heading),
          force: true,
        ).catchError((_) {}));
      });
    }

    useEffect(() {
      return cancelGestureAutoRecenter;
    }, const []);

    // 副次操作(チーム/記録/障害物の追加/安全設定/詳細)は、マップ上に並べると
    // 小型端末でオーバーフローするため、単一の「メニュー」からシートで開く。
    void openMapMenu() {
      final isObserver = navigator.mode.value == NavMode.observer;
      // 航行中に使えない項目は消さず、無効表示のまま同じ位置に残す。
      // 項目が減ると並びが変わり、覚えた位置が毎回ずれる。
      const duringNavigation = '航行終了後に利用できます';
      final actions = <MapMenuAction>[
        MapMenuAction(
          icon: Icons.groups_outlined,
          title: 'チーム',
          subtitle: '招待コードの確認・共有',
          enabled: isObserver,
          disabledReason: duringNavigation,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TeamScreen()),
            );
          },
        ),
        MapMenuAction(
          icon: Icons.history,
          title: '記録',
          subtitle: '過去の練習ログ',
          enabled: isObserver,
          disabledReason: duringNavigation,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RecordListScreen()),
            );
          },
        ),
        MapMenuAction(
          icon: Icons.edit_location_alt,
          title: '障害物の追加',
          subtitle: '臨時危険区域・固定流木の編集',
          onTap: () async {
            // 編集権限は全チームメンバー共通。航行中でも第一発見者がすぐ登録でき、
            // 背景の位置共有・警告処理は継続する。
            // ただしこの画面は地図に全画面で重なるため、航行中は警告バナーを
            // 画面上部へ引き継ぐ(音だけになる状態を作らない)。
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AreaSettingScreen(
                  navigationWarnings: navigator.mode.value == NavMode.navigator
                      ? navigator.activeWarnings
                      : null,
                ),
              ),
            );
            await navigator.reloadDefaultObstacles();
          },
        ),
        MapMenuAction(
          icon: Icons.shield_outlined,
          title: isObserver ? '警告設定' : '航行中の警告設定',
          subtitle:
              isObserver ? '危険区域の幅・警告開始時間・プライバシー' : '地図と警告を見ながら、確認して安全設定を反映',
          onTap: () async {
            if (!isObserver) {
              await showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.55,
                ),
                builder: (_) => NavigationSafetySettingsSheet(
                  safetySettingsLabel: navigator.safetySettingsLabel.value,
                  usesSharedSafetySettings:
                      navigator.dangerZoneSettingsSource.value ==
                          DangerZoneSettingsSource.shared,
                  appliedSharedSafetyRevision:
                      navigator.appliedSharedSafetyRevision.value,
                  pendingSharedSafetyRevision:
                      navigator.pendingSharedSafetyRevision.value,
                  onApplyWarningLeadTimes:
                      navigator.applyWarningLeadTimesDuringNavigation,
                  onApplyObstacles: navigator.applyNavigationObstacleSettings,
                  onApplyPendingSharedSafetySettings:
                      navigator.applyPendingSharedSafetySettings,
                ),
              );
              return;
            }
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const DangerZoneSettingsScreen(),
              ),
            );
            await navigator.reloadDefaultObstacles();
            // 開発者トグルは設定画面の最下部で変更する。判定そのものを
            // 変更しない表示設定なので、ここでだけ復元すればよい。
            showDeveloperSafetyShapeOverlay.value =
                await mapDisplaySettings.loadDeveloperSafetyShapeOverlay();
          },
        ),
        MapMenuAction(
          icon: strokeMotionDisplayEnabled.value
              ? Icons.insights
              : Icons.insights_outlined,
          title: '1ストロークの艇速分析',
          subtitle: isObserver
              ? '航行開始画面で選択できます'
              : strokeMotionDisplayEnabled.value
                  ? '表示中・タップで非表示'
                  : '非表示・タップで表示',
          enabled: !isObserver,
          disabledReason: '航行開始画面で選択できます',
          onTap: () {
            final next = !strokeMotionDisplayEnabled.value;
            strokeMotionDisplayEnabled.value = next;
            unawaited(
              navigationDefaults
                  .saveStrokeMotionDisplayEnabled(next)
                  .catchError((Object error) {
                debugPrint('Failed to save stroke analysis display: $error');
              }),
            );
          },
        ),
        MapMenuAction(
          icon: Icons.edit_location_alt_outlined,
          title: '固定障害物の位置調整',
          subtitle: '位置を調整・チームに公開',
          enabled: isObserver,
          disabledReason: duringNavigation,
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const FixedObstacleCalibrationScreen(),
              ),
            );
            await navigator.reloadDefaultObstacles();
          },
        ),
        // 表示だけの切替なので航行中でも触れる。安全判定には影響しない。
        MapMenuAction(
          icon: showChannelLanes.value ? Icons.route : Icons.route_outlined,
          title: '航路を表示',
          subtitle: showChannelLanes.value ? '往路・復路の帯を表示中' : '非表示',
          onTap: () {
            final next = !showChannelLanes.value;
            showChannelLanes.value = next;
            unawaited(mapDisplaySettings.saveShowChannelLanes(next));
          },
        ),
        MapMenuAction(
          icon:
              highContrastMap.value ? Icons.contrast : Icons.contrast_outlined,
          title: '高コントラスト表示',
          subtitle: highContrastMap.value
              ? 'オン: 地図を淡いグレーにし、危険区域を目立たせる'
              : 'オフ: 通常の地図配色',
          onTap: () {
            final next = !highContrastMap.value;
            highContrastMap.value = next;
            unawaited(mapDisplaySettings.saveHighContrast(next));
          },
        ),
        // 使い方・端末情報は航行中でも開ける。航行を止めず、書き込みもしない。
        MapMenuAction(
          icon: Icons.help_outline,
          title: '使い方',
          subtitle: '警告の3段階・地図の色・警告音の試聴',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const UsageGuideScreen()),
            );
          },
        ),
        // リリースでも見られるようにする。現地で「鳴らない」と言われたとき、
        // 何が落ちているのかを開発ビルド無しで確かめられる必要がある。
        MapMenuAction(
          icon: Icons.monitor_heart_outlined,
          title: '端末情報',
          subtitle: 'GPS精度・最終測位・安全機能の状態',
          onTap: () {
            final boat = navigator.myBoat.value;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DeviceStatusScreen(
                  latitude: boat?.lat,
                  longitude: boat?.lng,
                  accuracyMeters: boat?.accuracy,
                  speedMetersPerSecond: boat?.speed,
                  headingDegrees: boat?.heading,
                  lastFixAt: boat?.timestamp,
                  batteryPercent: navigator.batteryLevel.value,
                  positionSharingUnavailable:
                      navigator.isPositionSharingUnavailable.value,
                  otherBoatReceiveUnavailable:
                      navigator.isDynamicReceiveUnavailable.value,
                  temporaryObstacleReceiveUnavailable:
                      navigator.isTemporaryObstacleReceiveUnavailable.value,
                  safetyRunMode: navigator.safetyRunMode.value,
                  otherBoatCount: navigator.otherBoats.value.length,
                  obstacleCount: navigator.obstacles.value.length,
                  navigating: navigator.mode.value == NavMode.navigator,
                ),
              ),
            );
          },
        ),
        if (!kReleaseMode)
          MapMenuAction(
            icon: Icons.article_outlined,
            title: '詳細（開発用）',
            subtitle: '緯度経度・処理時刻などの内部情報',
            onTap: () {
              showInfo.value = !showInfo.value;
            },
          ),
        // 通常の航行・監視には使わない端末内ログなので、メニューの最後に置く。
        MapMenuAction(
          icon: Icons.folder_zip_outlined,
          title: '練習一括ログ',
          subtitle: '監視端末に記録した全艇の位置・警告状態',
          enabled: isObserver,
          disabledReason: duringNavigation,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const PracticeLogListScreen(),
              ),
            );
          },
        ),
      ];
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => MapMenuSheet(actions: actions),
      );
    }

    // ##########################
    // 初期位置の取得
    // Firebaseの匿名認証とチーム所属は入口で復元済み。ここでは新しい
    // 匿名UIDを作らず、認証が失われた場合は招待コード再参加へ戻す。
    // ##########################
    useEffect(() {
      var cancelled = false;
      unawaited(Future<void>(() async {
        if (cancelled) return;
        loading.value = true;
        initError.value = null;
        try {
          // 起動直後にOS権限を要求しない。拒否中でも記録、
          // プライバシー、設定に入れるよう、桜川中心を初期表示する。
          navMap.setMapType(MapType.normal);
          final serviceEnabled = await Geolocator.isLocationServiceEnabled();
          if (cancelled) return;
          final currentPermission = await Geolocator.checkPermission();
          if (cancelled) return;
          final granted = serviceEnabled &&
              (currentPermission == LocationPermission.whileInUse ||
                  currentPermission == LocationPermission.always);
          locationPermissionGranted.value = granted;
          if (granted) {
            final currentPosition =
                await navigator.getCurrentPosition(locationAccuracy);
            if (cancelled) return;
            initLatLng.value =
                LatLng(currentPosition.latitude, currentPosition.longitude);
          } else {
            initLatLng.value = _sakuragawaFallbackCenter;
          }
        } catch (e) {
          if (cancelled) return;
          // 現在地の一時的な取得失敗でアプリ全体をブロックしない。
          initLatLng.value = _sakuragawaFallbackCenter;
          initError.value = null;
        } finally {
          if (!cancelled) loading.value = false;
        }
      }));
      return () {
        cancelled = true;
      };
    }, [initAttempt.value]);

    // 地図の見え方設定を復元する。失敗しても既定(通常表示)で続行する。
    useEffect(() {
      var disposed = false;
      unawaited(mapDisplaySettings.loadHighContrast().then((enabled) {
        if (disposed) return;
        highContrastMap.value = enabled;
      }));
      unawaited(
          mapDisplaySettings.loadDeveloperSafetyShapeOverlay().then((enabled) {
        if (disposed) return;
        showDeveloperSafetyShapeOverlay.value = enabled;
      }));
      unawaited(mapDisplaySettings.loadShowChannelLanes().then((enabled) {
        if (disposed) return;
        showChannelLanes.value = enabled;
      }));
      return () => disposed = true;
    }, const []);

    // 航路データを起動時に1回だけ読む。表示専用なので、読めなければ
    // 帯を描かないだけで、航行も警告も従来どおり動く(原則1)。
    useEffect(() {
      var disposed = false;
      unawaited(PresetObstacleService().loadNavigableWaters().then((waters) {
        if (disposed) return;
        navigableWaters.value = waters;
      }).catchError((Object error) {
        if (kDebugMode) debugPrint('Navigable waters not displayed: $error');
      }));
      return () => disposed = true;
    }, const []);

    // ##########################
    // 航路(往路・復路)の帯を描く
    // ##########################
    // **主役は危険区域であって航路ではない。** レーンは川幅いっぱいの面積が
    // あるため、塗りが少しでも濃いとその下の岸・橋脚・中州の色を全部濁らせる。
    // 配色と重なり順は map_layer_spec.dart に集約している。
    useEffect(() {
      if (!showChannelLanes.value) {
        if (laneOverlay.value.isNotEmpty) laneOverlay.value = {};
        return null;
      }
      final isSatellite = navMap.mapType.value == MapType.hybrid;
      final nextLanes = <Polygon>{};
      for (final water in navigableWaters.value) {
        final style = laneStyleFor(leg: water.leg, isSatellite: isSatellite);
        nextLanes.add(Polygon(
          polygonId: PolygonId('lane_${water.id}'),
          points: water.points,
          strokeWidth: style.strokeWidth,
          strokeColor: style.strokeColor,
          fillColor: style.fillColor,
          zIndex: laneFillZIndex,
          // 地図操作を邪魔しない。帯は川幅いっぱいを覆うため、タップを
          // 奪うと危険区域や艇のタップが届かなくなる。
          consumeTapEvents: false,
        ));
      }
      laneOverlay.value = nextLanes;
      return null;
    }, [
      navigableWaters.value,
      showChannelLanes.value,
      navMap.mapType.value,
    ]);

    // 起動時は音を鳴らさず、対象別の警告音の準備状態だけ自動確認する。
    // 問題があっても画面に警告を出すだけで、航行開始は妨げない。
    useEffect(() {
      unawaited(Future<void>(() async {
        await navigator.checkAudio();
      }).catchError((Object error) {
        if (kDebugMode) debugPrint('Boat marker render failed: $error');
      }));
      return null;
    }, []);

    // 監視中の地図操作で追跡を解除していても、航行開始時は必ず
    // ローイング用の後ろ向き追跡へ戻す。
    useEffect(() {
      if (navigator.mode.value == NavMode.navigator) {
        cancelGestureAutoRecenter();
        tracking.setMode(TrackingMode.track);
      }
      return null;
    }, [navigator.mode.value]);

    // 臨時危険区域の受信障害は「今そうなっている状態」であって出来事ではない。
    // 5秒で消えるトーストに載せると、見逃したあとは能力が落ちたまま
    // 気づけない。計器カードの能力低下バッジ(常設)が同じ内容を
    // 持ち続けるため、ここでは重ねて通知しない。
    //
    // 連続音の警告が出た瞬間だけ強い触覚を返す。風・イヤホン無し・エルゴ音で
    // 音が届かないときの冗長経路。同じ警告が続く間は繰り返さない。
    useEffect(() {
      final imminentKeys = navigator.activeWarnings.value
          .where((warning) => warning.urgency == WarningDisplayUrgency.imminent)
          .map((warning) => warning.key)
          .toSet();
      final isNew =
          imminentKeys.difference(announcedImminentWarnings.value).isNotEmpty;
      announcedImminentWarnings.value = imminentKeys;
      if (isNew) TactileFeedback.alert();
      return null;
    }, [navigator.activeWarnings.value]);

    // 共有校正の受信障害も航行を止めず、最後に検証できた範囲を使い続ける。
    // 同じ障害が継続している間は通知を繰り返さない。
    useEffect(() {
      final unavailable =
          navigator.isSharedSafetyCalibrationSyncUnavailable.value;
      final newlyUnavailable =
          unavailable && !previousSharedCalibrationFailure.value;
      previousSharedCalibrationFailure.value = unavailable;
      if (newlyUnavailable) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('チーム安全設定を更新できません。直前の設定で航行を続けます。'),
            duration: Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ));
        });
      }
      return null;
    }, [navigator.isSharedSafetyCalibrationSyncUnavailable.value]);

    // 自艇の低電池は安全機能を止めず、閾値を下回った時に一度だけ
    // 小さく知らせる。25%まで回復するか航行終了で通知ラッチを戻す。
    useEffect(() {
      final level = navigator.batteryLevel.value;
      if (navigator.mode.value != NavMode.navigator) {
        lowBatteryNotificationShown.value = false;
        return null;
      }
      if (level == null) return null;
      if (level >= lowBatteryWarningResetPercent) {
        lowBatteryNotificationShown.value = false;
        return null;
      }
      if (level <= lowBatteryWarningPercent &&
          !lowBatteryNotificationShown.value) {
        lowBatteryNotificationShown.value = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('電池残量が$level%です。航行はそのまま継続できます。'),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ));
        });
      }
      return null;
    }, [navigator.mode.value, navigator.batteryLevel.value]);

    // 監視異常の提示は「地図上の小さなチップ(CoachAnomalyChip)+ 艇一覧」で行う。
    // ここが受け持つのは音だけで、既定では一度も鳴らない。
    //
    // 以前は新規異常のたびに `playCoachAnomalyAlert()`(= 他艇衝突と同じ
    // add_warning.mp3)と赤い danger SnackBar を出し、`anomalyReannounceSec`
    // 間隔で鳴らし直していた。実機テストで利用者から
    // 「監視は画面で見られれば十分。音はトランシーバーアプリと干渉し、
    // 近隣住民にも迷惑」「細かいエラーを大きく伝えすぎ」との指摘を受け、
    // DESIGN_PRINCIPLES 原則2(使い方は使い手が決める)に従って既定を無音にした。
    //
    // トレードオフ: 監視者が画面から目を離している間、沈・電池切れへの
    // 気づきが音では得られない。運用でそこを拾いたい場合は
    // `coachAudibleAnomalyKindNames` に種類を足すと、この経路が復活する。
    // 異常の**表示**は常に出しており、情報は減らしていない(原則1・原則6)。
    useEffect(() {
      final watching = navigator.mode.value == NavMode.observer &&
          navigator.isWatching.value;
      // 音を鳴らす対象が無ければ再通知ラッチも持たない。次に対象が現れた
      // ときは「新規」として扱われ、設定を有効にした運用でも正しく鳴る。
      final audible = watching
          ? coachWatch.anomalies.value
              .where((anomaly) => isAudibleCoachAnomalyKind(anomaly.kind))
              .toList()
          : const <BoatAnomaly>[];
      if (audible.isEmpty) {
        announcedCoachAnomalies.value = <String, DateTime>{};
        return null;
      }
      final now = DateTime.now();
      const reannounceInterval = Duration(seconds: anomalyReannounceSec);
      final announceTargets = audible.where((anomaly) {
        final lastAnnouncedAt = announcedCoachAnomalies.value[anomaly.key];
        return lastAnnouncedAt == null ||
            now.difference(lastAnnouncedAt) >= reannounceInterval;
      }).toList();
      announcedCoachAnomalies.value = {
        for (final anomaly in audible)
          anomaly.key: announceTargets.contains(anomaly)
              ? now
              : (announcedCoachAnomalies.value[anomaly.key] ?? now),
      };
      if (announceTargets.isNotEmpty) {
        unawaited(navigator.playCoachAnomalyAlert());
      }
      return null;
    }, [
      navigator.mode.value,
      navigator.isWatching.value,
      coachWatch.anomalies.value,
    ]);

    // ##########################
    // 自艇および他艇を描画
    // ##########################
    useEffect(() {
      if (!navMap.isReady.value) return;
      final evalService = CollisionRiskEvaluatorService();
      Future(() async {
        final markerSpecs = <BoatMarkerRenderSpec>[];
        // 自艇のマーカーを作成
        final myBoat = navigator.myBoat.value;
        if (myBoat != null) {
          final travelBearing = normalizeBearing(myBoat.heading);
          markerSpecs.add(BoatMarkerRenderSpec(
            markerId: myBoat.boatId,
            type: MarkerType.myBoat,
            boatType: myBoat.boatType,
            lat: myBoat.lat,
            lng: myBoat.lng,
            heading: travelBearing,
            title: '自艇',
            snippet: "${myBoat.boatId}\n"
                "BoatType: ${myBoat.boatType}\n"
                "速度: ${myBoat.speed.toStringAsFixed(1)} m/s\n"
                "進路: ${myBoat.heading.toStringAsFixed(1)}°\n"
                "画面上の艇印: 下向き",
          ));
        }
        // 他艇は新しい受信値が届いた時だけ描画位置を更新する。
        // 1Hzの安全判定では従来どおり現在時刻まで外挿するが、表示だけの
        // 補間で全艇マーカーを毎秒再生成しないことで電池消費を抑える。
        final otherBoats = navigator.otherBoats.value;
        for (final boat in otherBoats) {
          markerSpecs.add(BoatMarkerRenderSpec(
            markerId: boat.boatId,
            type: MarkerType.otherBoat,
            boatType: boat.boatType,
            lat: boat.lat,
            lng: boat.lng,
            heading: boat.heading,
            title: boat.displayName,
            snippet: "名前: ${boat.displayName}\n"
                "艇種: ${boatConfigs.byBoatType(boat.boatType).label}\n"
                "速度: ${boat.speed.toStringAsFixed(1)} m/s\n"
                "進路: ${boat.heading.toStringAsFixed(1)}°"
                "${boat.battery != null ? '\n電池: ${boat.battery}%' : ''}",
            // 他艇は受信鮮度で既に絞られている。航行中だけ名称を隠すと、
            // 警告対象が誰かを確認できないため、表示対象はすべてラベルを出す。
            nameLabel: boat.displayName,
          ));
        }
        final rendered = await navMap.renderBoatMarkers(markerSpecs);
        // より新しいGPS更新の描画が始まっていたら、古い位置へ
        // カメラを戻さず、その新しい処理に追跡を任せる。
        if (!rendered) return;
        // ナビゲーションモードかつトラッキングモードなら自艇を追跡
        if (myBoat != null && tracking.mode.value == TrackingMode.track) {
          // 艇の矢印と実際の進行方向を画面下に固定する。
          await focusP14y(
            myBoat.lat,
            myBoat.lng,
            rowingMapBearing(myBoat.heading),
          );
        }
      });

      // ###########################
      // 船舶領域を可視化
      // ###########################
      final shipDomainService = ShipDomainService();
      // 全艇の船舶領域を取得
      final myBoat = navigator.myBoat.value;
      final allBoats = [
        if (myBoat != null) myBoat,
        ...navigator.otherBoats.value
      ];
      final nextRenderSnapshot = ShipDomainRenderSnapshot(
        renderedAt: DateTime.now(),
        warningTimeSeconds: navigator.warningTimeSeconds.value,
        boats: allBoats.map(BoatRenderSnapshot.fromBoat),
      );
      if (!shouldRefreshShipDomains(
        previous: shipDomainRenderSnapshot.value,
        next: nextRenderSnapshot,
      )) {
        return null;
      }
      // 1艇につき3つの図形だけを描く。
      //   ① 船体領域(t=0)     … いま艇がある場所
      //   ② 掃引外形(凸包)     … どこまで届くか
      //   ③ 停止距離ライン     … どこまでなら止まれるか
      // 以前はサンプルごとに2枚(最大48枚)を重ねていたが、中身は同じ
      // 六角形の平行移動の繰り返しで、情報は増えないまま画面が埋まる。
      final newShipDomains = <Polygon>{};
      final newStoppingDistanceLines = <Polyline>{};
      for (final boat in allBoats) {
        final speed = boat.speed;
        final stoppingDistance = evalService.getStoppingDistance(boat);
        final warningDistance = max(
          stoppingDistance,
          navigator.warningTimeSeconds.value * speed,
        );
        final sampleDistances =
            shipDomainDisplaySampleDistances(warningDistance);

        // 地図の表示形状は従来どおり。低速時の横拡張は安全判定専用で、
        // 描画すると停止のたびに領域が太って見え、意味を誤解させる(不変条件6)。
        ShipDomains domainsAt(double distance) {
          final t = speed > 0 ? distance / speed : 0.0;
          return shipDomainService.getShipDomains(
            evalService.predictPosition(boat, t),
            headingReliable: true,
          );
        }

        // ① 船体領域。塗るのはここだけで、いま艇が在る場所を示す。
        newShipDomains.add(Polygon(
          polygonId: PolygonId('ship_body_${boat.boatId}'),
          points: domainsAt(0).shipBodyDomain.points,
          strokeWidth: 2,
          strokeColor: Colors.black.withValues(alpha: 0.45),
          fillColor: Colors.black.withValues(alpha: 0.08),
          zIndex: predictionShapeZIndex,
        ));

        // ② 掃引外形。「塗り = 実在する危険」「線 = 予測」の規則を守り、
        // 塗りはほぼ透明にして輪郭で伝える。
        final sweptPoints = sweptOutline([
          for (final distance in sampleDistances)
            domainsAt(distance).exclusiveDomain.points,
        ]);
        if (sweptPoints.length >= 3) {
          newShipDomains.add(Polygon(
            polygonId: PolygonId('sweep_outline_${boat.boatId}'),
            points: sweptPoints,
            strokeWidth: 3,
            strokeColor: const Color(0xFFF9A825).withValues(alpha: 0.9),
            fillColor: const Color(0xFFF9A825).withValues(alpha: 0.06),
            zIndex: predictionShapeZIndex,
          ));
        }

        // ③ 停止距離の位置での排他領域を、閉じた輪のポリラインで描く。
        // 速度0のときは掃引そのものが無いので出さない。
        if (speed > 0) {
          final stopPoints = domainsAt(stoppingDistance).exclusiveDomain.points;
          if (stopPoints.length >= 3) {
            newStoppingDistanceLines.add(Polyline(
              polylineId: PolylineId('stop_line_${boat.boatId}'),
              points: [...stopPoints, stopPoints.first],
              width: 2,
              color: const Color(0xFFD32F2F),
              zIndex: predictionShapeZIndex,
            ));
          }
        }
      }
      shipDomains.value = newShipDomains;
      stoppingDistanceLines.value = newStoppingDistanceLines;
      shipDomainRenderSnapshot.value = nextRenderSnapshot;
      return null;
    }, [
      navigator.myBoat.value,
      navigator.otherBoats.value,
      coachWatch.boatStatuses.value, // 観察者モードでも定期的に再描画する
      tracking.mode.value,
      navMap.isReady.value,
      navigator.warningTimeSeconds.value,
    ]);

    // ##########################
    // 開発用: 実際の安全判定形状を別レイヤーへ描画
    // ##########################
    useEffect(() {
      final myBoat = navigator.myBoat.value;
      if (!showDeveloperSafetyShapeOverlay.value ||
          !navMap.isReady.value ||
          myBoat == null) {
        if (developerSafetyShapeOverlay.value.isNotEmpty) {
          developerSafetyShapeOverlay.value = {};
        }
        return null;
      }
      developerSafetyShapeOverlay.value = safetyShapeOverlayService.build(
        boat: myBoat,
        obstacles: navigator.obstacles.value,
        warningTimeSeconds: navigator.warningTimeSeconds.value,
        // 判定器と同じ中心線を使う。中心線が無ければサービス側は従来と
        // 同じ直線予測へ縮退するため、表示だけ別の予測をしない。
        centerline: navigator.channelCenterline.value,
      );
      return null;
    }, [
      showDeveloperSafetyShapeOverlay.value,
      navMap.isReady.value,
      navigator.myBoat.value,
      navigator.obstacles.value,
      navigator.warningTimeSeconds.value,
      navigator.channelCenterline.value,
    ]);

    // ##########################
    // 障害物を描画
    // ##########################
    // 種類ごとに色と濃さを変える。すべて同じ赤で塗ると、release で約310枚に
    // なる岸の長方形が川の両側を一様に埋め、本当に避けたい流木や中州が
    // その中へ紛れる。バナーと同じ HazardPalette を参照し、
    // 「バナーは流木と言っているのに地図では岸と同じ色」を起こさない。
    useEffect(() {
      final newObstacles = <Polygon>{};
      for (final obstacle in navigator.obstacles.value) {
        final points = obstacle.points
            .map((point) => LatLng(point.latitude, point.longitude))
            .toList();
        final category = obstacle.kind.name;
        newObstacles.add(Polygon(
          polygonId: PolygonId(obstacle.id),
          points: points,
          // 塗りが薄い区域ほど輪郭線で形を伝える。色だけに頼らない。
          strokeWidth: HazardPalette.strokeWidthOf(category),
          strokeColor: HazardPalette.strokeColorOf(context, category),
          fillColor: HazardPalette.fillColorOf(
            context,
            category,
            isTemporary: obstacle.isTemporary,
          ),
          // 実在する危険は、航路の帯と監視の航跡より必ず上に出す。
          zIndex: hazardPolygonZIndex,
        ));
      }
      obstacles.value = newObstacles;
      return null;
    }, [navigator.obstacles.value, navigator.warningTimeSeconds.value]);

    // ##########################
    // Polygonsの統合
    // ##########################
    useEffect(() {
      // 重なり順は zIndex が決めるが、集合へ入れる順序も意味の順に揃えて
      // おく(帯 → 実在する危険 → 予測 → 開発用)。
      final newPolygons = {
        ...laneOverlay.value,
        ...shipDomains.value,
        ...obstacles.value,
        // この集合は開発者トグルがONのときだけ非空。通常地図の描画形状を
        // 安全判定用のGPS帯・低速時拡張へ置き換えない。
        ...developerSafetyShapeOverlay.value,
      };
      navMap.setPolygons(newPolygons);
      return null;
    }, [
      laneOverlay.value,
      shipDomains.value,
      obstacles.value,
      developerSafetyShapeOverlay.value,
    ]);

    // ##########################
    // ポリラインの統合(航跡 + 停止距離ライン)
    // ##########################
    // 地図のポリラインは1つの集合しか持てない。航跡と停止距離ラインを
    // 別々に setPolylines すると、片方を設定した瞬間にもう片方が消える。
    useEffect(() {
      navMap.setPolylines({
        // 過去に通った線。危険区域より下に敷く。
        if (navigator.mode.value == NavMode.observer)
          for (final trail in coachWatch.trailPolylines.value)
            trail.copyWith(zIndexParam: coachTrailZIndex),
        // これから通る予測。危険区域の上に線だけ乗せる。
        ...stoppingDistanceLines.value,
      });
      return null;
    }, [
      coachWatch.trailPolylines.value,
      stoppingDistanceLines.value,
      navigator.mode.value,
    ]);

    return Scaffold(
      // 水上では地図が1pxでも広い方がよいためAppBarは置かず、マップを全画面に使う
      body: loading.value
          ? const AppLoadingView(message: '位置情報を取得しています…')
          : initError.value != null
              ? AppErrorView(
                  icon: Icons.location_off,
                  title: '起動を完了できませんでした',
                  message: initError.value!,
                  primaryLabel: '再試行',
                  onPrimary: () => initAttempt.value += 1,
                  secondaryLabel: '端末の設定を開く',
                  onSecondary: () async {
                    await Geolocator.openAppSettings();
                  },
                )
              : Stack(alignment: Alignment.center, children: <Widget>[
                  // ################ マップ ################
                  // 自艇を画面上端から `navigationSelfBoatScreenRatio` の
                  // 位置へ置くためのパディングを、実際の地図の高さから
                  // 計算する。LayoutBuilder は制約をそのまま子へ渡すため、
                  // 地図の大きさは従来と変わらない。
                  LayoutBuilder(builder: (context, mapConstraints) {
                    return GoogleMap(
                      // 通常時も許可済みならOS標準の現在地アイコンを表示する。
                      // 航行中の安全判定・位置共有とは別の地図表示専用レイヤーである。
                      // 航行中はOS標準の現在地(生GPS)を出さない。Kalman推定で
                      // 描く自艇マーカーと数m ずれた青丸が並ぶと、どちらが自分の
                      // 位置なのか判断できなくなる。監視中は自艇マーカーが
                      // 無いので、こちらだけ表示する。
                      myLocationEnabled: locationPermissionGranted.value &&
                          navigator.mode.value != NavMode.navigator,
                      myLocationButtonEnabled: false,
                      initialCameraPosition: CameraPosition(
                        target: initLatLng.value!,
                        zoom: initialMapZoomLevel,
                      ),
                      mapType: navMap.mapType.value,
                      // 航空写真ではスタイルが無視されるため、通常地図のときだけ
                      // 適用する。適用に失敗しても通常表示のまま航行は続く。
                      style: highContrastMap.value &&
                              navMap.mapType.value == MapType.normal
                          ? highContrastMapStyle
                          : null,
                      onMapCreated: (GoogleMapController controller) async {
                        navMap.setController(controller);
                      },
                      onCameraMoveStarted: () {
                        // プログラムによる操作以外はジェスチャーとして扱う。
                        // ボタンでの明示解除は、ジェスチャーで上書きしない。
                        if (!tracking.progFlag.value) {
                          cancelGestureAutoRecenter();
                          if (tracking.mode.value !=
                              TrackingMode.untrackedByUser) {
                            tracking.setMode(TrackingMode.untrackedByGesture);
                          }
                        }
                      },
                      onCameraIdle: () {
                        // カメラ更新完了までフラグを維持する。開始直後に解除すると
                        // 同じアニメーションのコールバックで追跡が外れる端末がある。
                        final wasProgrammatic = tracking.progFlag.value;
                        tracking.setProgFlag(false);
                        if (!wasProgrammatic) scheduleGestureAutoRecenter();
                      },
                      markers: navMap.markers.value,
                      polygons: navMap.polygons.value,
                      polylines: navMap.polylines.value,
                      // 航行中は自艇を画面の上から
                      // `navigationSelfBoatScreenRatio` の位置へ置く。
                      // カメラのターゲットは、上パディング P で画面
                      // Y=(P+H)/2、下パディング Q で Y=(H-Q)/2 に来る。
                      // 比率が 0.5 より上(小さい)なら下パディングを使う。
                      //
                      // 監視中・待機中は入れない。監視者は艇を俯瞰したいので、
                      // 中心をずらす理由がない。
                      padding: navigator.mode.value == NavMode.navigator
                          ? _selfBoatCameraPadding(mapConstraints.maxHeight)
                          : EdgeInsets.zero,
                    );
                  }),
                  // ################ マップ上のオーバーレイ ################
                  SafeArea(
                    child:
                        LayoutBuilder(builder: (context, overlayConstraints) {
                      final isLandscape = overlayConstraints.maxWidth >
                          overlayConstraints.maxHeight;
                      // 縦向きは上部40%以内。横向きは画面高さ自体が小さく、
                      // 30%だと計器カードの下端(距離・経過時間)が切れて
                      // しまうため広く取る。横向きのカードは幅が
                      // 380px以内なので、高さを許しても地図は右側に残る。
                      final topOverlayBudget = overlayConstraints.maxHeight *
                          (isLandscape ? 0.72 : 0.4);
                      return Stack(
                          alignment: Alignment.center,
                          children: <Widget>[
                            // ################ 艇情報カード(画面上部のみ) ################
                            Align(
                              alignment: isLandscape ||
                                      navigator.mode.value == NavMode.navigator
                                  ? Alignment.topLeft
                                  : Alignment.topCenter,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: isLandscape ||
                                        navigator.mode.value ==
                                            NavMode.navigator
                                    ? CrossAxisAlignment.start
                                    : CrossAxisAlignment.center,
                                children: [
                                  // 監視中であることを表示する。
                                  //
                                  // 航行していない待機状態は observer だが、
                                  // それを「監視モード」と出すと、画面下に
                                  // 「監視スタート」が並んで矛盾して見える。
                                  // 実際に監視しているときだけ出す。
                                  if (navigator.mode.value ==
                                          NavMode.observer &&
                                      navigator.isWatching.value)
                                    Container(
                                      margin: const EdgeInsets.only(top: 8),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: context.colors.chipScrim,
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.visibility,
                                              size: 18, color: Colors.white),
                                          SizedBox(width: 6),
                                          Text(
                                            '監視モード',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  // 監視者が即時に読むべき逆走・対向接近だけを
                                  // 地図上部に最大2本で表示する。既存衝突警報や
                                  // 音声経路には接続しない。
                                  if (navigator.mode.value == NavMode.observer)
                                    ObserverPriorityBanner(
                                      snapshot:
                                          coachWatch.trafficSnapshot.value,
                                      onTapReverse: () {
                                        showBoatList.value = true;
                                        final boats = coachWatch
                                            .trafficSnapshot.value.reverseBoats;
                                        if (boats.isNotEmpty) {
                                          unawaited(focusOnWatchedBoat(
                                              boats.first.boatId));
                                        }
                                      },
                                      onTapApproaching: () {
                                        showBoatList.value = true;
                                        final groups = coachWatch
                                            .trafficSnapshot.value.groups;
                                        if (groups.isNotEmpty &&
                                            groups.first.boatIds.isNotEmpty) {
                                          unawaited(focusOnWatchedBoat(
                                              groups.first.boatIds.first));
                                        }
                                      },
                                    ),
                                  // 機能不全・停止・更新途絶は青いアイコンだけに
                                  // 退避し、タップ後の艇一覧で内容を確認する。
                                  if (navigator.mode.value == NavMode.observer)
                                    ObserverStatusIcon(
                                      anomalies: coachWatch.anomalies.value,
                                      onTap: () => showBoatList.value = true,
                                    ),
                                  // 陸上と判定して警告音を止めている間は、
                                  // その事実を必ず画面へ出す。黙って音を
                                  // 止めると「鳴らないアプリ」と区別できない。
                                  // 判定を誤っていると感じたら、ここから
                                  // すぐ音へ戻せる。
                                  if (navigator.mode.value ==
                                          NavMode.navigator &&
                                      navigator.isAshore.value)
                                    AshoreNotice(
                                      onRestoreAudio:
                                          navigator.overrideAshoreToWater,
                                    ),
                                  // 安全レベルに応じた警告バナー(音声警告と併用)。
                                  // 警告は最優先のため高さ制限の外に置き、常に全体表示する。
                                  if (navigator.mode.value == NavMode.navigator)
                                    SafetyBanner(
                                      warnings: navigator.activeWarnings.value,
                                    ),
                                  if (navigator.audioError.value != null)
                                    Container(
                                      width: double.infinity,
                                      color: context.colors.danger,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.volume_off,
                                              color: Colors.white),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              navigator.audioError.value!,
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  // 縦向きは上部40%以内、横向きは左上の小型カードにする。
                                  // 警告バナーはカードに含めず、独立した細い表示を保つ。
                                  if (navigator.mode.value == NavMode.navigator)
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                          maxHeight: topOverlayBudget),
                                      child: SingleChildScrollView(
                                        child: NavigationStatusPanel(
                                          paceSeconds: navigator.myBoat.value !=
                                                  null
                                              ? navigator.myBoat.value!.speed !=
                                                      0
                                                  ? (500 ~/
                                                      navigator
                                                          .myBoat.value!.speed)
                                                  : 0
                                              : 0,
                                          distanceMeters: navigator
                                              .totalDistance.value
                                              .round(),
                                          sessionStartedAt:
                                              navigator.sessionStartedAt.value,
                                          spm: navigator.spm.value,
                                          strokeMotion: navigator.strokeMotion
                                                      .value?.quality ==
                                                  RowingMotionQuality.good
                                              ? navigator.strokeMotion.value
                                              : null,
                                          strokeMotionDisplayEnabled:
                                              strokeMotionDisplayEnabled.value,
                                          strokeTraceWindowBuilder: (now) =>
                                              navigator.strokeTraceWindow(
                                                  now: now),
                                          spmMeasurementEnabled: navigator
                                                  .config
                                                  .value
                                                  ?.strokeRateEnabled ??
                                              false,
                                          compact: isLandscape,
                                          portraitCompact: !isLandscape,
                                        ),
                                      ),
                                    ),
                                  // コーチモードの艇一覧パネル(同じく上部40%以内で内部スクロール)
                                  if (navigator.mode.value ==
                                          NavMode.observer &&
                                      showBoatList.value)
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                          maxHeight: topOverlayBudget),
                                      child: SingleChildScrollView(
                                        child: SizedBox(
                                          width: double.infinity,
                                          child: BoatListPanel(
                                            statuses:
                                                coachWatch.boatStatuses.value,
                                            onTapBoat: (boatId) => unawaited(
                                              focusOnWatchedBoat(boatId),
                                            ),
                                            // シートを閉じれば購読も止まる。
                                            // 開いている1隻ぶんしか受信しない。
                                            onShowStrokeTrace:
                                                (boatId, displayName) {
                                              unawaited(
                                                showModalBottomSheet<void>(
                                                  context: context,
                                                  isScrollControlled: true,
                                                  backgroundColor:
                                                      context.colors.card,
                                                  shape:
                                                      const RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.vertical(
                                                      top: Radius.circular(20),
                                                    ),
                                                  ),
                                                  builder: (_) =>
                                                      StrokeTraceSheet(
                                                    boatId: boatId,
                                                    displayName: displayName,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (!kReleaseMode && showInfo.value)
                                    SizedBox(
                                        width: double.infinity,
                                        child: BoatStatusCard(
                                          myBoat: navigator.myBoat.value,
                                          config: navigator.config.value,
                                          preProcessTime:
                                              navigator.preProcessTime.value,
                                          postProcessTime:
                                              navigator.postProcessTime.value,
                                        )),
                                ],
                              ),
                            ),
                            // ################ 左右操作ボタン類 ################
                            Container(
                              alignment: Alignment.center,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 48, horizontal: 17),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    // ################ 左側 ################
                                    Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        MapTypeSwitcher(
                                          mapType: navMap.mapType.value,
                                          onTap: () {
                                            navMap.setMapType(
                                                navMap.mapType.value ==
                                                        MapType.normal
                                                    ? MapType.hybrid
                                                    : MapType.normal);
                                          },
                                        ),
                                      ],
                                    ),
                                    // ################ 右側 ################
                                    Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        // コーチ用: 艇一覧パネルの表示切替(監視中のみ)
                                        if (navigator.mode.value ==
                                                NavMode.observer &&
                                            navigator.isWatching.value)
                                          Container(
                                            margin:
                                                const EdgeInsets.only(top: 12),
                                            child: MapControlButton(
                                              icon: Icons.groups,
                                              label: '艇一覧',
                                              active: showBoatList.value,
                                              onPressed: () {
                                                showBoatList.value =
                                                    !showBoatList.value;
                                              },
                                            ),
                                          ),
                                        // コーチ用: 全艇が収まる位置へ引く。
                                        // 監視者は陸上で端末を操作できるので、
                                        // 確認ダイアログは挟まない。
                                        if (navigator.mode.value ==
                                                NavMode.observer &&
                                            navigator.isWatching.value)
                                          Container(
                                            margin:
                                                const EdgeInsets.only(top: 12),
                                            child: MapControlButton(
                                              icon: Icons.fit_screen,
                                              label: '全艇',
                                              // 0隻のときは押せる見た目にしない。
                                              // 押しても何も起きない操作を
                                              // 有効に見せない。
                                              onPressed: coachWatch.boatStatuses
                                                      .value.isEmpty
                                                  ? null
                                                  : fitAllWatchedBoats,
                                            ),
                                          ),
                                        // 航行用: 自艇の追跡ON/OFF
                                        if (navigator.mode.value ==
                                            NavMode.navigator)
                                          Container(
                                            margin:
                                                const EdgeInsets.only(top: 12),
                                            child: MapControlButton(
                                              icon: Icons.navigation,
                                              label: '追跡',
                                              angle: 45,
                                              active: tracking.mode.value ==
                                                  TrackingMode.track,
                                              onPressed: () async {
                                                if (tracking.mode.value ==
                                                    TrackingMode.track) {
                                                  // カメラの自動追従だけを解除する。
                                                  // 位置共有・警告処理は継続する。
                                                  cancelGestureAutoRecenter();
                                                  tracking.setMode(TrackingMode
                                                      .untrackedByUser);
                                                  return;
                                                }
                                                cancelGestureAutoRecenter();
                                                tracking.setMode(
                                                    TrackingMode.track);
                                                // 現在位置をフォーカス
                                                final myBoat =
                                                    navigator.myBoat.value;
                                                if (myBoat != null) {
                                                  focusP14y(
                                                      myBoat.lat,
                                                      myBoat.lng,
                                                      rowingMapBearing(navigator
                                                              .myBoat
                                                              .value
                                                              ?.heading ??
                                                          0.0),
                                                      force: true);
                                                }
                                              },
                                            ),
                                          ),
                                        // 監視用: 現在地へフォーカス
                                        if (navigator.mode.value ==
                                            NavMode.observer)
                                          Container(
                                            margin:
                                                const EdgeInsets.only(top: 12),
                                            child: MapControlButton(
                                              icon: Icons.gps_fixed,
                                              label: '現在地',
                                              onPressed: () async {
                                                try {
                                                  await permission
                                                      .requestLocationServicePermission();
                                                  locationPermissionGranted
                                                      .value = true;
                                                  final pos = await navigator
                                                      .getCurrentPosition(
                                                          locationAccuracy);
                                                  focusP14y(pos.latitude,
                                                      pos.longitude, 0.0,
                                                      force: true);
                                                } catch (e) {
                                                  if (!context.mounted) return;
                                                  ScaffoldMessenger.of(context)
                                                      .showSnackBar(SnackBar(
                                                    content:
                                                        Text('現在地を取得できません: $e'),
                                                  ));
                                                }
                                              },
                                            ),
                                          ),
                                        // その他の操作はメニューへ集約(過密・オーバーフロー回避)
                                        Container(
                                          margin:
                                              const EdgeInsets.only(top: 12),
                                          child: MapControlButton(
                                            icon: Icons.menu,
                                            label: 'メニュー',
                                            onPressed: openMapMenu,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // ################ ナビゲーションボタン ################
                            Container(
                              alignment: Alignment.bottomCenter,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                    top: 48, bottom: 24, left: 17, right: 17),
                                child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      if (navigator.isTransitioning.value)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 18, vertical: 12),
                                          decoration: BoxDecoration(
                                            color: Colors.black
                                                .withValues(alpha: 0.7),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const SizedBox(
                                                width: 18,
                                                height: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Text(
                                                navigator.mode.value ==
                                                        NavMode.navigator
                                                    ? '航行を終了しています…'
                                                    : '航行を準備しています…',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (!navigator.isTransitioning.value &&
                                          navigator.mode.value ==
                                              NavMode.observer)
                                        RoundedButton(
                                          label: "航行スタート",
                                          icon: Icons.rowing,
                                          onPressed: () {
                                            showModalBottomSheet<void>(
                                              context: context,
                                              backgroundColor:
                                                  Colors.transparent,
                                              // 名前入力でキーボードが出ると、
                                              // 既定の高さでは入力欄が隠れる。
                                              isScrollControlled: true,
                                              // ただし画面いっぱいには開かない。
                                              // 全画面まで伸びると、シートを
                                              // 閉じるために触れる場所が画面の
                                              // 最上端しか残らず、そこからの
                                              // 下スワイプはOSの通知センターに
                                              // 取られて戻れなくなる。
                                              // 上に2割残し、その暗い部分を
                                              // タップして地図へ戻れるようにする。
                                              constraints: BoxConstraints(
                                                maxHeight: MediaQuery.sizeOf(
                                                      context,
                                                    ).height *
                                                    0.8,
                                              ),
                                              builder:
                                                  (BuildContext sheetContext) {
                                                return NavSettingModal(
                                                  onPressTestAudio: () async {
                                                    final ok = await navigator
                                                        .testAudio();
                                                    if (!context.mounted) {
                                                      return;
                                                    }
                                                    ScaffoldMessenger.of(
                                                            context)
                                                        .showSnackBar(SnackBar(
                                                      content: Text(ok
                                                          ? '警告音を再生しました。実際に聞こえたことを確認してください。'
                                                          : '音声を再生できませんでした。端末の音量・消音設定を確認してください。'),
                                                    ));
                                                  },
                                                  onPressStartNav: (displayName,
                                                      strokeRateEnabled,
                                                      showStrokeMotion) async {
                                                    if (!navMap.isReady.value) {
                                                      ScaffoldMessenger.of(
                                                              context)
                                                          .showSnackBar(
                                                        const SnackBar(
                                                          content: Text(
                                                              '地図を準備中です。数秒後に同じ画面から再試行してください。'),
                                                          duration: Duration(
                                                              seconds: 4),
                                                        ),
                                                      );
                                                      return;
                                                    }
                                                    try {
                                                      final user =
                                                          auth.currentUser;
                                                      if (user == null) {
                                                        _returnToTeamEntry(
                                                            context);
                                                        return;
                                                      }
                                                      final accepted =
                                                          await _confirmBackgroundLocationUse(
                                                              context);
                                                      if (!accepted) return;
                                                      final notificationGranted =
                                                          await permission
                                                              .requestNavigationNotificationPermission();
                                                      // ナビゲーションを開始
                                                      final userId = user.uid;
                                                      // 最新の boatType と seatPosition を参照
                                                      final boatType = ref.read(
                                                          boatTypeProvider);
                                                      final seatPosition = ref.read(
                                                          seatPositionProvider);
                                                      final config = NavConfig(
                                                          boatId: userId,
                                                          displayName:
                                                              displayName,
                                                          boatType: boatType,
                                                          seatPos: seatPosition,
                                                          accuracy: LocationAccuracy
                                                              .bestForNavigation,
                                                          strokeRateEnabled:
                                                              strokeRateEnabled);
                                                      strokeMotionDisplayEnabled
                                                              .value =
                                                          strokeRateEnabled &&
                                                              showStrokeMotion;
                                                      try {
                                                        await navigator
                                                            .startNavigation(
                                                                config);
                                                        locationPermissionGranted
                                                            .value = true;
                                                      } catch (e) {
                                                        if (!context.mounted) {
                                                          return;
                                                        }
                                                        showNavigationStartFailure(
                                                            e);
                                                        return;
                                                      }
                                                      if (sheetContext
                                                          .mounted) {
                                                        Navigator.of(
                                                                sheetContext)
                                                            .pop();
                                                      }
                                                      // トラッキングモードに切り替え
                                                      tracking.setMode(
                                                          TrackingMode.track);
                                                      // 現在位置をフォーカス。
                                                      // 航行開始のこの1回だけ
                                                      // 川幅の約2倍が入る倍率へ
                                                      // 寄せる。以後の追従では
                                                      // 渡さないので、利用者が
                                                      // ピンチで変えた倍率は
                                                      // 上書きされない。
                                                      final myBoat = navigator
                                                          .myBoat.value;
                                                      if (myBoat != null) {
                                                        focusP14y(
                                                            myBoat.lat,
                                                            myBoat.lng,
                                                            rowingMapBearing(
                                                                navigator
                                                                        .myBoat
                                                                        .value
                                                                        ?.heading ??
                                                                    0.0),
                                                            force: true,
                                                            overrideZoomLevel:
                                                                navigationStartZoomLevel);
                                                      }
                                                      if (!notificationGranted &&
                                                          context.mounted) {
                                                        ScaffoldMessenger.of(
                                                                context)
                                                            .showSnackBar(
                                                          const SnackBar(
                                                            content: Text(
                                                              '通知が許可されていないため、バックグラウンド航行中の持続通知が表示されません。',
                                                            ),
                                                          ),
                                                        );
                                                      }
                                                      debugPrint(
                                                          "Navigation started.");
                                                    } catch (e) {
                                                      if (!context.mounted) {
                                                        return;
                                                      }
                                                      showNavigationStartFailure(
                                                          e);
                                                    }
                                                  },
                                                );
                                              },
                                            );
                                          },
                                        ),
                                      if (!navigator.isTransitioning.value &&
                                          navigator.mode.value ==
                                              NavMode.observer &&
                                          !navigator.isWatching.value)
                                        RoundedButton(
                                          label: '監視スタート',
                                          icon: Icons.visibility,
                                          compact: true,
                                          onPressed: () async {
                                            try {
                                              if (auth.currentUser == null) {
                                                _returnToTeamEntry(context);
                                                return;
                                              }
                                              await navigator.startWatching();
                                              // 監視開始のこの1回だけ俯瞰へ引く。
                                              // 現在地が取れなければ何もしない
                                              // (監視の開始は妨げない)。
                                              try {
                                                final pos = await navigator
                                                    .getCurrentPosition(
                                                        locationAccuracy);
                                                await focusP14y(
                                                  pos.latitude,
                                                  pos.longitude,
                                                  0.0,
                                                  force: true,
                                                  overrideZoomLevel:
                                                      watchStartZoomLevel,
                                                );
                                              } catch (_) {
                                                // 位置が取れないだけ。監視は続く。
                                              }
                                            } catch (e) {
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(SnackBar(
                                                content: Text('監視を開始できません: $e'),
                                              ));
                                            }
                                          },
                                        ),
                                      if (!navigator.isTransitioning.value &&
                                          navigator.mode.value ==
                                              NavMode.observer &&
                                          navigator.isWatching.value)
                                        RoundedButton(
                                          label:
                                              practiceLogRecording.log.value ==
                                                      null
                                                  ? '監視終了'
                                                  : '監視終了（記録中）',
                                          icon: Icons.visibility_off,
                                          color: context.colors.danger,
                                          compact: true,
                                          onPressed: navigator.stopWatching,
                                        ),
                                      if (!navigator.isTransitioning.value &&
                                          navigator.mode.value ==
                                              NavMode.navigator)
                                        RoundedButton(
                                            label: "航行終了",
                                            icon: Icons.stop_circle_outlined,
                                            // 航行中は地図の視認性を優先する。
                                            // 押し間違いは確認ダイアログで
                                            // 受け止めるので、面積を大きく
                                            // 取る必要がない。
                                            color: context.colors.danger
                                                .withValues(alpha: 0.55),
                                            compact: true,
                                            onPressed: () async {
                                              // 誤タップで位置共有・警告が止まるのを防ぐため必ず確認する
                                              final confirmed =
                                                  await showDialog<bool>(
                                                context: context,
                                                builder: (dialogContext) =>
                                                    AlertDialog(
                                                  title:
                                                      const Text('航行を終了しますか?'),
                                                  content: const Text(
                                                      '位置共有と衝突警告が停止し、練習記録が保存されます。'),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.of(
                                                                  dialogContext)
                                                              .pop(false),
                                                      child:
                                                          const Text('キャンセル'),
                                                    ),
                                                    FilledButton(
                                                      style: FilledButton
                                                          .styleFrom(
                                                        backgroundColor:
                                                            const Color(
                                                                0xFFC62828),
                                                      ),
                                                      onPressed: () =>
                                                          Navigator.of(
                                                                  dialogContext)
                                                              .pop(true),
                                                      child: const Text('終了する'),
                                                    ),
                                                  ],
                                                ),
                                              );
                                              if (confirmed != true) return;
                                              try {
                                                // 地図描画の状態に関係なく、資源解放を
                                                // 最優先で実行する。
                                                await navigator
                                                    .stopNavigation();
                                                debugPrint(
                                                    "Navigation stopped.");
                                              } catch (error) {
                                                if (!context.mounted) return;
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(SnackBar(
                                                  content: Text(
                                                      '航行終了処理でエラーが発生しました。資源解放は継続しました: $error'),
                                                ));
                                              }
                                            }),
                                    ]),
                              ),
                            ),
                          ]);
                    }),
                  ),
                ]),
    );
  }
}
