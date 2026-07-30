import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/managed_hazard_model.dart';
import '../models/static_obstacle_model.dart';
import '../services/env_service.dart';
import '../services/managed_hazard_service.dart';
import '../services/preset_obstacle_service.dart';
import '../services/static_obstacle_service.dart';
import '../types/map_editor_mode.dart';

UseMapEditor useMapEditor(
  GoogleMapController? mapController, {
  required bool temporarySyncEnabled,
}) {
  final mode = useState(MapEditorMode.select);
  final obstacles = useState<List<StaticObstacle>>([]);
  final obstaclesSubscription = useRef<StreamSubscription?>(null);
  final defaultObstacles = useRef<List<StaticObstacle>>([]);
  final temporaryObstacles = useRef<List<StaticObstacle>>([]);
  final selectedObstacle = useState<StaticObstacle?>(null);
  final draftCenter = useState<LatLng?>(null);
  final draftRadiusMeters = useState<double>(
    StaticObstacleService.defaultTemporaryRadiusMeters,
  );
  final managedState = useState<ManagedHazardState?>(null);
  final managedDraft = useState<ManagedHazardState?>(null);
  final temporaryPreviewPoints = useState<List<LatLng>>([]);
  final managedPreviewPoints = useState<List<LatLng>>([]);
  final managedBasePoints = useRef<List<LatLng>>([]);
  final saving = useState(false);
  final isMounted = useRef(true);

  final env = useMemoized(EnvService.new);
  final managedService = useMemoized(ManagedHazardService.new);
  final presetService = useMemoized(
    () => PresetObstacleService(managedHazardService: managedService),
  );

  useEffect(() {
    isMounted.value = true;
    return () {
      isMounted.value = false;
    };
  }, []);

  void setMode(MapEditorMode newMode) {
    mode.value = newMode;
    if (newMode == MapEditorMode.edit) selectedObstacle.value = null;
  }

  void clearSelection() {
    selectedObstacle.value = null;
    draftCenter.value = null;
    managedDraft.value = null;
    temporaryPreviewPoints.value = [];
    managedPreviewPoints.value = [];
  }

  void selectObstacle(StaticObstacle obstacle) {
    if (!obstacle.isTemporary && !obstacle.isManaged) return;
    mode.value = MapEditorMode.select;
    selectedObstacle.value = obstacle;
    if (obstacle.isTemporary) {
      draftCenter.value = obstacle.circleCenter ?? _meanCenter(obstacle.points);
      draftRadiusMeters.value = obstacle.circleRadiusMeters ??
          StaticObstacleService.defaultTemporaryRadiusMeters;
      managedDraft.value = null;
      temporaryPreviewPoints.value = env.staticObstacleService
          .createCirclePoints(draftCenter.value!, draftRadiusMeters.value);
    } else {
      final state = managedState.value ??
          ManagedHazardState.forBaseShape(obstacle.points);
      managedDraft.value = state;
      managedPreviewPoints.value = const ManagedHazardTransformer().transform(
        managedBasePoints.value,
        state,
      );
      draftCenter.value = null;
    }
  }

  Future<void> createTemporaryCircle(LatLng center) async {
    if (!temporarySyncEnabled || saving.value) return;
    saving.value = true;
    try {
      await env.addTemporaryCircle(center);
    } finally {
      saving.value = false;
    }
  }

  void updateDraftCenter(LatLng center) {
    if (selectedObstacle.value?.isTemporary == true) {
      draftCenter.value = center;
      temporaryPreviewPoints.value = env.staticObstacleService
          .createCirclePoints(center, draftRadiusMeters.value);
    } else if (selectedObstacle.value?.isManaged == true) {
      final draft = managedDraft.value?.copyWith(center: center);
      if (draft != null) {
        try {
          draft.validate();
        } on FormatException {
          // 誤操作で桜川の許可範囲外へ移動しない。
          return;
        }
        managedDraft.value = draft;
        managedPreviewPoints.value = const ManagedHazardTransformer().transform(
          managedBasePoints.value,
          draft,
        );
      }
    }
  }

  void updateDraftRadius(double radiusMeters) {
    draftRadiusMeters.value = radiusMeters;
    final center = draftCenter.value;
    if (center != null) {
      temporaryPreviewPoints.value =
          env.staticObstacleService.createCirclePoints(center, radiusMeters);
    }
  }

  void updateManagedDraft(ManagedHazardState state) {
    managedDraft.value = state;
    managedPreviewPoints.value = const ManagedHazardTransformer().transform(
      managedBasePoints.value,
      state,
    );
  }

  void resetManagedDraft() {
    final current = managedState.value;
    if (managedBasePoints.value.length < 3 || current == null) return;
    updateManagedDraft(
      ManagedHazardState.forBaseShape(managedBasePoints.value).copyWith(
        revision: current.revision,
      ),
    );
  }

  late Future<void> Function({bool refreshManagedHazards})
      reloadDefaultObstacles;

  Future<void> saveSelection() async {
    final selected = selectedObstacle.value;
    if (selected == null || saving.value) return;
    saving.value = true;
    try {
      if (selected.isTemporary) {
        final center = draftCenter.value;
        if (center == null) throw StateError('中心位置がありません。');
        await env.updateTemporaryCircle(
          selected.id,
          center,
          draftRadiusMeters.value,
        );
      } else if (selected.isManaged) {
        final draft = managedDraft.value;
        final current = managedState.value;
        if (draft == null || current == null) {
          throw StateError('固定流木の最新状態がありません。');
        }
        final saved = await managedService.save(
          draft: draft,
          expectedRevision: current.revision,
        );
        managedState.value = saved;
        managedDraft.value = saved;
        await reloadDefaultObstacles(refreshManagedHazards: false);
      }
      clearSelection();
    } finally {
      saving.value = false;
    }
  }

  Future<void> deleteSelected() async {
    final selected = selectedObstacle.value;
    if (selected == null || !selected.isTemporary || saving.value) return;
    saving.value = true;
    try {
      await env.deleteTemporaryObstacle(selected.id);
      clearSelection();
    } finally {
      saving.value = false;
    }
  }

  reloadDefaultObstacles = ({
    bool refreshManagedHazards = false,
  }) async {
    final defaults = await presetService.loadPresets(
      refreshManagedHazards: refreshManagedHazards,
    );
    if (!isMounted.value) return;
    final basePoints = await presetService.loadManagedDriftwoodBaseShape();
    if (!isMounted.value) return;
    final cached = await managedService.loadCached();
    if (!isMounted.value) return;
    managedBasePoints.value = basePoints;
    defaultObstacles.value = defaults;
    obstacles.value = [...defaults, ...temporaryObstacles.value];
    StaticObstacle? driftwood;
    for (final obstacle in defaults) {
      if (obstacle.isManaged) {
        driftwood = obstacle;
        break;
      }
    }
    managedState.value = cached ??
        (driftwood == null
            ? null
            : ManagedHazardState.forBaseShape(driftwood.points));
  };

  Future<void> refreshManagedHazard() async {
    await reloadDefaultObstacles(refreshManagedHazards: true);
    clearSelection();
  }

  useEffect(() {
    var cancelled = false;
    StreamSubscription? ownedSubscription;

    Future<void> startWatching() async {
      temporaryObstacles.value = [];
      await reloadDefaultObstacles(
        refreshManagedHazards: temporarySyncEnabled,
      );
      if (cancelled || !isMounted.value || !temporarySyncEnabled) return;

      final previous = obstaclesSubscription.value;
      obstaclesSubscription.value = null;
      try {
        await previous?.cancel();
      } catch (error) {
        debugPrint('Previous obstacle editor stream cancel failed: $error');
      }
      if (cancelled || !isMounted.value) return;

      final subscription = env.getTemporaryObstaclesStream().listen(
        (staticObs) {
          if (cancelled || !isMounted.value) return;
          final temporary = List<StaticObstacle>.from(staticObs['obstacles']);
          temporaryObstacles.value = temporary;
          obstacles.value = [...defaultObstacles.value, ...temporary];
        },
        onError: (Object error, StackTrace stackTrace) {
          // 共有側が停止しても、端末内の固定危険区域と最後の取得値を維持する。
          debugPrint('Temporary obstacle editor stream unavailable: $error');
        },
      );
      if (cancelled || !isMounted.value) {
        await subscription.cancel();
        return;
      }
      ownedSubscription = subscription;
      obstaclesSubscription.value = subscription;
    }

    unawaited(startWatching().catchError((Object error, StackTrace stackTrace) {
      if (!cancelled && isMounted.value) {
        debugPrint('Obstacle editor initialization failed: $error');
      }
    }));
    return () {
      cancelled = true;
      final subscription = ownedSubscription;
      if (identical(obstaclesSubscription.value, subscription)) {
        obstaclesSubscription.value = null;
      }
      if (subscription != null) {
        unawaited(subscription.cancel().catchError((Object error) {
          debugPrint('Obstacle editor stream cancel failed: $error');
        }));
      }
    };
  }, [temporarySyncEnabled]);

  return UseMapEditor(
    mode: mode,
    obstacles: obstacles,
    selectedObstacle: selectedObstacle,
    draftCenter: draftCenter,
    draftRadiusMeters: draftRadiusMeters,
    managedDraft: managedDraft,
    temporaryPreviewPoints: temporaryPreviewPoints,
    managedPreviewPoints: managedPreviewPoints,
    saving: saving,
    setMode: setMode,
    clearSelection: clearSelection,
    selectObstacle: selectObstacle,
    createTemporaryCircle: createTemporaryCircle,
    updateDraftCenter: updateDraftCenter,
    updateDraftRadius: updateDraftRadius,
    updateManagedDraft: updateManagedDraft,
    resetManagedDraft: resetManagedDraft,
    saveSelection: saveSelection,
    deleteSelected: deleteSelected,
    reloadDefaultObstacles: reloadDefaultObstacles,
    refreshManagedHazard: refreshManagedHazard,
  );
}

class UseMapEditor {
  final ValueNotifier<MapEditorMode> mode;
  final ValueNotifier<List<StaticObstacle>> obstacles;
  final ValueNotifier<StaticObstacle?> selectedObstacle;
  final ValueNotifier<LatLng?> draftCenter;
  final ValueNotifier<double> draftRadiusMeters;
  final ValueNotifier<ManagedHazardState?> managedDraft;
  final ValueNotifier<List<LatLng>> temporaryPreviewPoints;
  final ValueNotifier<List<LatLng>> managedPreviewPoints;
  final ValueNotifier<bool> saving;
  final void Function(MapEditorMode) setMode;
  final void Function() clearSelection;
  final void Function(StaticObstacle) selectObstacle;
  final Future<void> Function(LatLng) createTemporaryCircle;
  final void Function(LatLng) updateDraftCenter;
  final void Function(double) updateDraftRadius;
  final void Function(ManagedHazardState) updateManagedDraft;
  final void Function() resetManagedDraft;
  final Future<void> Function() saveSelection;
  final Future<void> Function() deleteSelected;
  final Future<void> Function({bool refreshManagedHazards})
      reloadDefaultObstacles;
  final Future<void> Function() refreshManagedHazard;

  UseMapEditor({
    required this.mode,
    required this.obstacles,
    required this.selectedObstacle,
    required this.draftCenter,
    required this.draftRadiusMeters,
    required this.managedDraft,
    required this.temporaryPreviewPoints,
    required this.managedPreviewPoints,
    required this.saving,
    required this.setMode,
    required this.clearSelection,
    required this.selectObstacle,
    required this.createTemporaryCircle,
    required this.updateDraftCenter,
    required this.updateDraftRadius,
    required this.updateManagedDraft,
    required this.resetManagedDraft,
    required this.saveSelection,
    required this.deleteSelected,
    required this.reloadDefaultObstacles,
    required this.refreshManagedHazard,
  });
}

LatLng _meanCenter(List<LatLng> points) => LatLng(
      points.map((point) => point.latitude).reduce((a, b) => a + b) /
          points.length,
      points.map((point) => point.longitude).reduce((a, b) => a + b) /
          points.length,
    );
