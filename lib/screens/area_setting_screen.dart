import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../features/home_map/widgets/map_type_switcher.dart';
import '../features/home_map/widgets/safety_banner.dart';
import '../hooks/use_map_editor.dart';
import '../hooks/use_nav_map.dart';
import '../models/managed_hazard_model.dart';
import '../models/navigation_warning.dart';
import '../services/auth_service.dart';
import '../services/permission_service.dart';
import '../types/map_editor_mode.dart';
import '../widgets/rounded_icon_button.dart';
import '../widgets/app_state_views.dart';
import '../theme/app_theme.dart';
import 'app_entry_gate.dart';
import 'danger_zone_settings_screen.dart';

const _sakuragawaFallbackCenter = LatLng(36.069, 140.208);

class AreaSettingScreen extends HookConsumerWidget {
  /// 航行中に開かれた場合の、進行中の警告。
  ///
  /// この画面は全画面で地図の上に重なるため、開いている間は警告バナーが
  /// 見えなくなる。音声警告と位置共有は継続しているので、視覚経路だけが
  /// 無告知で落ちないよう、航行中はここへ重ねて出す。
  final ValueListenable<List<NavigationWarning>>? navigationWarnings;

  const AreaSettingScreen({super.key, this.navigationWarnings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navMap = useNavMap();
    final loading = useState(true);
    final initLatLng = useState<LatLng?>(null);
    final initAttempt = useState(0);
    final locationAvailable = useState(false);
    final locationIssue = useState<String?>(null);
    final permission = useMemoized(PermissionService.new);
    final auth = useMemoized(AuthService.new);
    final mapEditor = useMapEditor(
      navMap.mapController.value,
      temporarySyncEnabled: !loading.value && auth.isSignedIn,
    );
    const locationAccuracy = LocationAccuracy.bestForNavigation;
    const defaultZoomLevel = 17.0;

    void showError(Object error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存できませんでした: $error')),
      );
    }

    void returnToEntryGate() {
      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppEntryGate()),
        (_) => false,
      );
    }

    bool hasExistingTeamSession() {
      if (auth.isSignedIn) return true;
      returnToEntryGate();
      return false;
    }

    useEffect(() {
      var cancelled = false;
      unawaited(Future<void>(() async {
        if (cancelled) return;
        loading.value = true;
        locationIssue.value = null;
        locationAvailable.value = false;
        if (!auth.isSignedIn) {
          // 認証情報を失ったときに別の匿名UIDを作ると、
          // 元のチームと所属が分断される。中央の入口で
          // 招待コードによる再参加を案内する。
          returnToEntryGate();
          return;
        }
        try {
          navMap.setMapType(MapType.hybrid);
          await permission.requestLocationServicePermission();
          if (cancelled) return;
          final current = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: locationAccuracy,
              timeLimit: Duration(seconds: 15),
            ),
          );
          if (cancelled) return;
          initLatLng.value = LatLng(current.latitude, current.longitude);
          locationAvailable.value = true;
        } catch (_) {
          if (cancelled) return;
          // 現在地が使えなくても第一発見者が危険区域を
          // 閲覧・編集できるよう、地図自体は必ず表示する。
          initLatLng.value = _sakuragawaFallbackCenter;
          locationIssue.value = '現在地を取得できないため、桜川中心を表示しています。'
              '地図を移動して危険区域の閲覧・編集は続けられます。';
        } finally {
          if (!cancelled) loading.value = false;
        }
      }));
      return () {
        cancelled = true;
      };
    }, [initAttempt.value]);

    useEffect(() {
      if (!navMap.isReady.value) return null;
      final polygons = HashSet<Polygon>();
      for (final obstacle in mapEditor.obstacles.value) {
        final selected = obstacle.id == mapEditor.selectedObstacle.value?.id;
        final previewPoints = selected && obstacle.isTemporary
            ? mapEditor.temporaryPreviewPoints.value
            : selected && obstacle.isManaged
                ? mapEditor.managedPreviewPoints.value
                : obstacle.points;
        polygons.add(Polygon(
          polygonId: PolygonId(obstacle.id),
          points: previewPoints.isEmpty ? obstacle.points : previewPoints,
          strokeWidth: selected ? 4 : 2,
          strokeColor: obstacle.isManaged
              ? Colors.deepOrange
              : obstacle.isTemporary
                  ? Colors.red
                  : Colors.orange.shade800,
          fillColor: (obstacle.isManaged ? Colors.deepOrange : Colors.red)
              .withValues(alpha: selected ? 0.55 : 0.35),
          consumeTapEvents: obstacle.isTemporary || obstacle.isManaged,
          onTap: () => mapEditor.selectObstacle(obstacle),
        ));
      }
      final markers = HashSet<Marker>();
      final selected = mapEditor.selectedObstacle.value;
      final center = selected?.isManaged == true
          ? mapEditor.managedDraft.value?.center
          : mapEditor.draftCenter.value;
      if (selected != null && center != null) {
        markers.add(Marker(
          markerId: MarkerId('edit_${selected.id}'),
          position: center,
          draggable: true,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            selected.isManaged
                ? BitmapDescriptor.hueOrange
                : BitmapDescriptor.hueRed,
          ),
          infoWindow: const InfoWindow(title: '中心を移動'),
          onDragEnd: mapEditor.updateDraftCenter,
        ));
      }
      navMap.setPolygons(polygons);
      navMap.setMarkers(markers);
      return null;
    }, [
      mapEditor.obstacles.value,
      mapEditor.selectedObstacle.value,
      mapEditor.draftCenter.value,
      mapEditor.managedDraft.value,
      mapEditor.temporaryPreviewPoints.value,
      mapEditor.managedPreviewPoints.value,
      navMap.isReady.value,
    ]);

    Future<void> saveSelection() async {
      if (!hasExistingTeamSession()) return;
      try {
        await mapEditor.saveSelection();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('危険区域を保存しました。')),
        );
      } catch (error) {
        showError(error);
      }
    }

    Future<void> deleteSelection() async {
      if (!hasExistingTeamSession()) return;
      if (mapEditor.selectedObstacle.value?.isTemporary != true) return;
      final confirmed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              title: const Text('臨時危険区域を削除しますか？'),
              content: const Text(
                '地図上で選択中の赤い危険区域を、チームの共有地図から削除します。'
                'この操作は取り消せません。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC62828),
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('削除する'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !context.mounted) return;
      if (!hasExistingTeamSession()) return;
      try {
        await mapEditor.deleteSelected();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('臨時危険区域を削除しました。')),
        );
      } catch (error) {
        showError(error);
      }
    }

    final warnings = navigationWarnings;
    return Scaffold(
      appBar: AppBar(
        title: Text(warnings == null ? '危険区域を追加' : '危険区域を追加(航行中)'),
        bottom: warnings == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(74),
                child: ValueListenableBuilder<List<NavigationWarning>>(
                  valueListenable: warnings,
                  builder: (context, active, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        color: const Color(0xFF1B5E20),
                        child: const Text(
                          '航行中です。警告は音と下のバナーで継続しています',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      SafetyBanner(warnings: active),
                    ],
                  ),
                ),
              ),
        actions: [
          IconButton(
            tooltip: '固定流木の最新状態を取得',
            icon: const Icon(Icons.sync),
            onPressed: mapEditor.saving.value
                ? null
                : () async {
                    if (!hasExistingTeamSession()) return;
                    try {
                      await mapEditor.refreshManagedHazard();
                    } catch (error) {
                      showError(error);
                    }
                  },
          ),
          if (!kReleaseMode)
            IconButton(
              tooltip: '警告の設定',
              icon: const Icon(Icons.tune),
              onPressed: () async {
                final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DangerZoneSettingsScreen(),
                  ),
                );
                if (changed == true) {
                  await mapEditor.reloadDefaultObstacles();
                }
              },
            ),
        ],
      ),
      body: loading.value || initLatLng.value == null
          ? const AppLoadingView(message: '危険区域を読み込んでいます…')
          : Stack(
              children: [
                GoogleMap(
                  myLocationEnabled: locationAvailable.value,
                  myLocationButtonEnabled: false,
                  initialCameraPosition: CameraPosition(
                    target: initLatLng.value!,
                    zoom: defaultZoomLevel,
                  ),
                  mapType: navMap.mapType.value,
                  onMapCreated: navMap.setController,
                  onTap: (position) async {
                    if (mapEditor.mode.value == MapEditorMode.edit) {
                      if (!hasExistingTeamSession()) return;
                      try {
                        await mapEditor.createTemporaryCircle(position);
                        if (!context.mounted) return;
                        // 追加モードを1回で解除し、連続タップによる
                        // 重複区域と不要なFirestore writeを防ぐ。
                        mapEditor.setMode(MapEditorMode.select);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('半径5mの臨時危険区域を保存しました。'),
                          ),
                        );
                      } catch (error) {
                        showError(error);
                      }
                    } else {
                      mapEditor.clearSelection();
                    }
                  },
                  polygons: navMap.polygons.value,
                  markers: navMap.markers.value,
                ),
                if (locationIssue.value != null ||
                    mapEditor.mode.value == MapEditorMode.edit)
                  Positioned(
                    top: 12,
                    left: 16,
                    right: 16,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (locationIssue.value != null)
                          _LocationIssueCard(
                            message: locationIssue.value!,
                            onRetry: () => initAttempt.value += 1,
                            onOpenSettings: () async {
                              final serviceEnabled =
                                  await Geolocator.isLocationServiceEnabled();
                              if (serviceEnabled) {
                                await Geolocator.openAppSettings();
                              } else {
                                await Geolocator.openLocationSettings();
                              }
                            },
                          ),
                        if (locationIssue.value != null &&
                            mapEditor.mode.value == MapEditorMode.edit)
                          const SizedBox(height: 8),
                        if (mapEditor.mode.value == MapEditorMode.edit)
                          const _Guide(
                            text: '追加したい場所を1回タップすると、半径5mの臨時危険区域を保存します。',
                          ),
                      ],
                    ),
                  ),
                Positioned(
                  left: 17,
                  right: 17,
                  bottom: mapEditor.selectedObstacle.value == null ? 28 : 250,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      MapTypeSwitcher(
                        mapType: navMap.mapType.value,
                        onTap: () => navMap.setMapType(
                          navMap.mapType.value == MapType.normal
                              ? MapType.hybrid
                              : MapType.normal,
                        ),
                      ),
                      RoundedIconButton(
                        icon: mapEditor.mode.value == MapEditorMode.edit
                            ? Icons.close
                            : Icons.add_location_alt,
                        label: mapEditor.mode.value == MapEditorMode.edit
                            ? '追加終了'
                            : '危険区域を追加',
                        color: mapEditor.mode.value == MapEditorMode.edit
                            ? context.colors.danger
                            : null,
                        onPressed: mapEditor.saving.value
                            ? null
                            : () => mapEditor.setMode(
                                  mapEditor.mode.value == MapEditorMode.select
                                      ? MapEditorMode.edit
                                      : MapEditorMode.select,
                                ),
                      ),
                    ],
                  ),
                ),
                if (mapEditor.selectedObstacle.value?.isTemporary == true)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _TemporaryEditor(
                      radius: mapEditor.draftRadiusMeters.value,
                      saving: mapEditor.saving.value,
                      onRadiusChanged: mapEditor.updateDraftRadius,
                      onSave: saveSelection,
                      onDelete: deleteSelection,
                      onCancel: mapEditor.clearSelection,
                    ),
                  ),
                if (mapEditor.selectedObstacle.value?.isManaged == true &&
                    mapEditor.managedDraft.value != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: _ManagedEditor(
                      state: mapEditor.managedDraft.value!,
                      saving: mapEditor.saving.value,
                      onChanged: mapEditor.updateManagedDraft,
                      onReset: mapEditor.resetManagedDraft,
                      onSave: saveSelection,
                      onCancel: mapEditor.clearSelection,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Guide extends StatelessWidget {
  final String text;
  const _Guide({required this.text});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(text, style: const TextStyle(color: Colors.white)),
        ),
      );
}

class _LocationIssueCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final Future<void> Function() onOpenSettings;

  const _LocationIssueCard({
    required this.message,
    required this.onRetry,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Material(
      color: colors.cautionSurface,
      elevation: dimens.elevationMd,
      borderRadius: dimens.borderMd,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          dimens.space3,
          dimens.space3,
          dimens.space2,
          dimens.space2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.location_off_outlined,
                  color: colors.caution,
                ),
                SizedBox(width: dimens.space2),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: colors.textPrimary),
                  ),
                ),
              ],
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('再試行'),
                ),
                TextButton.icon(
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('設定を開く'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TemporaryEditor extends StatelessWidget {
  final double radius;
  final bool saving;
  final ValueChanged<double> onRadiusChanged;
  final VoidCallback onSave;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  const _TemporaryEditor({
    required this.radius,
    required this.saving,
    required this.onRadiusChanged,
    required this.onSave,
    required this.onDelete,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) => _EditorCard(
        title: '臨時危険区域  半径${radius.toStringAsFixed(0)}m',
        child: Column(
          children: [
            Slider(
              value: radius,
              min: 1,
              max: 100,
              divisions: 99,
              label: '${radius.round()}m',
              onChanged: saving ? null : onRadiusChanged,
            ),
            const Text('赤いマーカーをドラッグすると中心を移動できます。'),
            _EditorButtons(
              saving: saving,
              onSave: onSave,
              onDelete: onDelete,
              onCancel: onCancel,
            ),
          ],
        ),
      );
}

class _ManagedEditor extends StatelessWidget {
  final ManagedHazardState state;
  final bool saving;
  final ValueChanged<ManagedHazardState> onChanged;
  final VoidCallback onReset;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  const _ManagedEditor({
    required this.state,
    required this.saving,
    required this.onChanged,
    required this.onReset,
    required this.onSave,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) => _EditorCard(
        title: '固定流木（削除なし）',
        child: Column(
          children: [
            _CompactSlider(
              label: '長さ',
              value: state.lengthScale,
              min: ManagedHazardState.minScale,
              max: ManagedHazardState.maxScale,
              onChanged: (value) =>
                  onChanged(state.copyWith(lengthScale: value)),
            ),
            _CompactSlider(
              label: '幅',
              value: state.widthScale,
              min: ManagedHazardState.minScale,
              max: ManagedHazardState.maxScale,
              onChanged: (value) =>
                  onChanged(state.copyWith(widthScale: value)),
            ),
            _CompactSlider(
              label: '向き',
              value: state.rotationDegrees,
              min: -180,
              max: 180,
              onChanged: (value) =>
                  onChanged(state.copyWith(rotationDegrees: value)),
            ),
            _CompactSlider(
              label: '外側余裕m',
              value: state.outwardMarginMeters,
              min: 0,
              max: ManagedHazardState.maxOutwardMarginMeters,
              onChanged: (value) =>
                  onChanged(state.copyWith(outwardMarginMeters: value)),
            ),
            const Text('オレンジのマーカーで中心を移動します。'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: saving ? null : onReset,
                icon: const Icon(Icons.restore),
                label: const Text('基準位置・サイズに戻す'),
              ),
            ),
            _EditorButtons(
              saving: saving,
              onSave: onSave,
              onCancel: onCancel,
            ),
          ],
        ),
      );
}

class _CompactSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  const _CompactSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(
              width: 70, child: Text('$label ${value.toStringAsFixed(1)}')),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      );
}

class _EditorButtons extends StatelessWidget {
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback? onDelete;
  final VoidCallback onCancel;
  const _EditorButtons({
    required this.saving,
    required this.onSave,
    this.onDelete,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
              onPressed: saving ? null : onCancel, child: const Text('取消')),
          if (onDelete != null)
            TextButton(
              onPressed: saving ? null : onDelete,
              child: const Text('削除', style: TextStyle(color: Colors.red)),
            ),
          FilledButton(
            onPressed: saving ? null : onSave,
            child: saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      );
}

class _EditorCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _EditorCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Material(
          elevation: 12,
          color: context.colors.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                child,
              ],
            ),
          ),
        ),
      );
}
