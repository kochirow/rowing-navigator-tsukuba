import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/fixed_obstacle_calibration.dart';
import '../../models/session_model.dart';
import '../../models/static_obstacle_model.dart';
import '../../services/calibration_track_overlay_service.dart';
import '../../services/fixed_obstacle_calibration_service.dart';
import '../../services/preset_obstacle_service.dart';
import '../../services/session_store_service.dart';
import '../../services/shared_safety_calibration_service.dart';
import '../../services/team_service.dart';
import '../../widgets/fixed_obstacle_calibration_controls.dart';

// # 同梱の危険区域の位置合わせ(状態と処理)
//
// 以前は専用の画面(fixed_obstacle_calibration_screen.dart)が持っていた状態と処理を、
// 「危険区域の追加・編集」画面の中で使えるよう、画面から切り出したもの
// (2026-11-05 利用者決定: メニューの「同梱の危険区域の位置合わせ」を
// 「危険区域の追加・編集」へまとめ、同じ地図の上で位置合わせできるようにする)。
//
// 中身(端末内の下書き・0.5m刻み・チームに公開・競合の扱い)は専用画面のときと同じ。
// 確認のダイアログは画面側(パネル)が出し、ここは確認後の処理だけを持つ。

/// 位置合わせの状態と処理。画面の外から [ChangeNotifier] として聞く。
class FixedObstacleCalibrationController extends ChangeNotifier {
  static const stepMeters = 0.5;
  static const trackColors = [
    Colors.lightGreenAccent,
    Colors.amberAccent,
    Colors.purpleAccent,
    Colors.tealAccent,
    Colors.pinkAccent,
  ];

  // 位置合わせの間だけは、未公開の端末内下書きを地図へプレビューする。
  // 通常の監視・航行画面は共有確定版を優先し、両者を加算しない。
  final PresetObstacleService _presetService;
  final FixedObstacleCalibrationService _calibrationService;
  final CalibrationTrackOverlayService trackOverlayService;
  final SessionStoreService _sessionStoreService;
  final SharedSafetyCalibrationService _sharedCalibrationService;

  /// 利用者へ短い知らせ(スナックバー)を出す。画面側が渡す。
  final void Function(String message) onMessage;

  /// チームに参加しているか。テストで差し替える。
  final bool Function() _isTeamMember;

  FixedObstacleCalibrationController({
    required this.onMessage,
    String? initialSourceId,
    PresetObstacleService? presetService,
    FixedObstacleCalibrationService? calibrationService,
    CalibrationTrackOverlayService? trackOverlayService,
    SessionStoreService? sessionStoreService,
    SharedSafetyCalibrationService? sharedCalibrationService,
    bool Function()? isTeamMember,
  })  : _selectedId = initialSourceId,
        _isTeamMember =
            isTeamMember ?? (() => TeamService.activeMembership != null),
        _presetService = presetService ??
            PresetObstacleService(previewLocalFixedObstacleCalibrations: true),
        _calibrationService =
            calibrationService ?? FixedObstacleCalibrationService(),
        trackOverlayService =
            trackOverlayService ?? CalibrationTrackOverlayService(),
        _sessionStoreService = sessionStoreService ?? SessionStoreService(),
        _sharedCalibrationService =
            sharedCalibrationService ?? SharedSafetyCalibrationService();

  List<FixedObstacleCalibrationTarget> targets = const [];
  List<StaticObstacle> obstacles = const [];
  List<Session> recentSessions = const [];
  Map<String, FixedObstacleCalibration> calibrations = const {};
  String? _selectedId;
  int? selectedPointIndex;
  Set<String> overlaySessionIds = const {};
  FixedObstacleCalibration draft = const FixedObstacleCalibration();
  GoogleMapController? _mapController;
  Object? error;
  bool loading = true;
  bool saving = false;
  bool publishing = false;

  /// この位置合わせの間に、端末内の位置合わせを変えたか。
  bool changed = false;

  /// 変えた位置合わせを、まだチームに公開していないか。
  bool hasUnpublishedChanges = false;
  int sharedRevision = 0;
  FixedObstacleCalibrationPublishStatus publishStatus =
      FixedObstacleCalibrationPublishStatus.idle;
  String? publishMessage;
  bool _disposed = false;

  String? get selectedId => _selectedId;
  bool get busy => saving || publishing;
  bool get hasTeamMembership => _isTeamMember();

  FixedObstacleCalibrationTarget? get selectedTarget =>
      _selectedId == null ? null : targetById(_selectedId!);

  /// 地図の操作をこの位置合わせに渡す(カメラを選んだ区域へ動かすため)。
  /// 地図は画面が持つので、ここでは破棄しない。
  void attachMap(GoogleMapController? controller) {
    _mapController = controller;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    loading = true;
    error = null;
    _notify();
    try {
      final loadedTargets = await _presetService.loadCalibrationTargets();
      final loadedCalibrations = await _calibrationService.loadAll();
      final loadedObstacles = await _presetService.loadPresets();
      List<Session> sessions;
      try {
        sessions = (await _sessionStoreService.listSessions())
            .where((session) => session.points.length >= 2)
            .take(5)
            .toList();
      } catch (_) {
        // 航跡の読込失敗で、固定障害物の校正そのものを止めない。
        sessions = const [];
      }
      if (_disposed) return;
      final selected = loadedTargets.any((t) => t.sourceId == _selectedId)
          ? _selectedId
          : (loadedTargets.isEmpty ? null : loadedTargets.first.sourceId);
      final recentIds = sessions.map((session) => session.id).toSet();
      final selectedSessionIds = overlaySessionIds.intersection(recentIds);
      if (selectedSessionIds.isEmpty && sessions.isNotEmpty) {
        selectedSessionIds.add(sessions.first.id);
      }
      targets = loadedTargets;
      calibrations = loadedCalibrations;
      obstacles = loadedObstacles;
      recentSessions = sessions;
      _selectedId = selected;
      overlaySessionIds = selectedSessionIds;
      draft = loadedCalibrations[selected] ?? const FixedObstacleCalibration();
      loading = false;
      _notify();
      final target = selectedTarget;
      if (target != null) await _moveCameraTo(target);
      try {
        final shared = hasTeamMembership
            ? await _sharedCalibrationService.fetchLatest()
            : await _sharedCalibrationService.loadCached();
        if (_disposed) return;
        sharedRevision = shared?.revision ?? 0;
        _notify();
      } catch (_) {
        if (_disposed) return;
        if (hasTeamMembership) {
          publishStatus = FixedObstacleCalibrationPublishStatus.failure;
          publishMessage = '共有版の更新状況を取得できませんでした。'
              '端末内の位置合わせは続けられます。';
          _notify();
        }
      }
    } catch (loadError) {
      if (_disposed) return;
      error = loadError;
      loading = false;
      _notify();
    }
  }

  Future<void> select(String? sourceId) async {
    if (sourceId == null || busy) return;
    final target = targetById(sourceId);
    if (target == null) return;
    _selectedId = sourceId;
    draft = calibrations[sourceId] ?? const FixedObstacleCalibration();
    selectedPointIndex = null;
    _notify();
    await _moveCameraTo(target);
  }

  Future<void> _moveCameraTo(FixedObstacleCalibrationTarget target) async {
    final controller = _mapController;
    if (controller == null) return;
    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(targetCenter(target, draft), 18),
      );
    } catch (_) {
      // 地図がまだ準備中・破棄済みでも、位置合わせそのものは続ける。
    }
  }

  void selectVertex(int pointIndex) {
    if (busy) return;
    selectedPointIndex = pointIndex;
    _notify();
  }

  Future<void> _saveDraft(FixedObstacleCalibration value) async {
    final sourceId = _selectedId;
    if (sourceId == null || busy) return;
    final normalized = FixedObstacleCalibration(
      northMeters: _roundToStep(value.northMeters),
      eastMeters: _roundToStep(value.eastMeters),
      vertexOffsets: value.vertexOffsets,
    );
    saving = true;
    draft = normalized;
    _notify();
    try {
      await _calibrationService.save(sourceId, normalized);
      if (_disposed) return;
      final next = Map<String, FixedObstacleCalibration>.from(calibrations);
      if (normalized.isZero) {
        next.remove(sourceId);
      } else {
        next[sourceId] = normalized;
      }
      calibrations = next;
      if (_selectedId == sourceId) {
        draft = next[sourceId] ?? const FixedObstacleCalibration();
      }
      changed = true;
      hasUnpublishedChanges = true;
      publishStatus = FixedObstacleCalibrationPublishStatus.idle;
      publishMessage = null;
      _notify();
      await _reloadPreview(failurePrefix: '位置合わせは保存しましたが、地図プレビューを更新できませんでした');
    } catch (saveError) {
      onMessage('位置合わせを保存できませんでした: $saveError');
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> _reloadPreview({required String failurePrefix}) async {
    try {
      final loaded = await _presetService.loadPresets();
      if (_disposed) return;
      obstacles = loaded;
      _notify();
    } catch (reloadError) {
      onMessage('$failurePrefix: $reloadError');
    }
  }

  Future<void> nudge({double northDelta = 0, double eastDelta = 0}) {
    final pointIndex = selectedPointIndex;
    if (pointIndex == null) {
      onMessage('地図上の色付き座標点を選択してください。');
      return Future.value();
    }
    final current = draft.vertexOffsetFor(pointIndex);
    return _saveDraft(draft.withVertexOffset(
      pointIndex,
      FixedObstacleVertexOffset(
        northMeters: (current.northMeters + northDelta).clamp(
          -FixedObstacleCalibration.maxAbsoluteOffsetMeters,
          FixedObstacleCalibration.maxAbsoluteOffsetMeters,
        ),
        eastMeters: (current.eastMeters + eastDelta).clamp(
          -FixedObstacleCalibration.maxAbsoluteOffsetMeters,
          FixedObstacleCalibration.maxAbsoluteOffsetMeters,
        ),
      ),
    ));
  }

  Future<void> resetSelectedPoint() async {
    final pointIndex = selectedPointIndex;
    if (pointIndex == null || busy) return;
    await _saveDraft(
      draft.withVertexOffset(pointIndex, const FixedObstacleVertexOffset()),
    );
  }

  /// この端末の位置合わせをすべて解除する。確認は呼び出し側で済ませる。
  Future<void> resetAll() async {
    if (busy || calibrations.isEmpty) return;
    saving = true;
    _notify();
    try {
      await _calibrationService.resetAll();
      if (_disposed) return;
      calibrations = const {};
      draft = const FixedObstacleCalibration();
      changed = true;
      hasUnpublishedChanges = true;
      publishStatus = FixedObstacleCalibrationPublishStatus.idle;
      publishMessage = null;
      _notify();
      await _reloadPreview(
          failurePrefix: '位置合わせはすべて解除しましたが、地図プレビューを更新できませんでした');
    } catch (resetError) {
      onMessage('位置合わせを解除できませんでした: $resetError');
    } finally {
      saving = false;
      _notify();
    }
  }

  /// 公開の確認に出す一覧。空なら公開できるものがない。
  List<FixedObstacleCalibrationPublishItem> publishItems() {
    final items = <FixedObstacleCalibrationPublishItem>[
      for (final target in targets)
        if (calibrations[target.sourceId] case final calibration?)
          FixedObstacleCalibrationPublishItem(
            target: target,
            calibration: calibration,
            beforeCenter:
                targetCenter(target, const FixedObstacleCalibration()),
            afterCenter: targetCenter(target, calibration),
          ),
    ];
    // 全補正を0mへ戻す公開も確認できるよう、調整対象を1件表示する。
    if (items.isEmpty) {
      final target = selectedTarget;
      if (target != null) {
        final center = targetCenter(target, const FixedObstacleCalibration());
        items.add(FixedObstacleCalibrationPublishItem(
          target: target,
          calibration: const FixedObstacleCalibration(),
          beforeCenter: center,
          afterCenter: center,
        ));
      }
    }
    return items;
  }

  /// 公開の確認に添える、比較している航行記録の名前。
  List<String> get referenceSessionLabels => [
        for (final session in overlaySessions)
          '${sessionLabel(session)}・'
              '${trackOverlayService.directionLabel(session)}',
      ];

  /// チームに公開する。確認は呼び出し側で済ませる。
  Future<void> publishToTeam() async {
    if (!hasTeamMembership || busy) return;
    publishing = true;
    publishStatus = FixedObstacleCalibrationPublishStatus.publishing;
    publishMessage = null;
    _notify();
    try {
      final saved = await _sharedCalibrationService.publishCalibrations(
        calibrations: calibrations,
        expectedRevision: sharedRevision,
      );
      if (_disposed) return;
      sharedRevision = saved.revision;
      hasUnpublishedChanges = false;
      publishStatus = FixedObstacleCalibrationPublishStatus.success;
      publishMessage = 'チームに公開しました（版 ${saved.revision}）。';
    } on SharedSafetyCalibrationConflictException {
      if (_disposed) return;
      var message = '他の端末が先に更新しました。最新版を取得して、'
          '内容を確認してから再公開してください。';
      try {
        final latest = await _sharedCalibrationService.fetchLatest(
          forceServer: true,
        );
        if (_disposed) return;
        sharedRevision = latest?.revision ?? 0;
        message = '他の端末が先に更新しました。最新版（版 $sharedRevision）を'
            '取得したため、内容を確認して再公開してください。';
      } catch (_) {
        // 競合自体を優先表示し、再取得失敗で端末内の下書きを失わない。
      }
      publishStatus = FixedObstacleCalibrationPublishStatus.conflict;
      publishMessage = message;
    } catch (publishError) {
      if (_disposed) return;
      publishStatus = FixedObstacleCalibrationPublishStatus.failure;
      publishMessage = '公開できませんでした: $publishError';
    } finally {
      publishing = false;
      _notify();
    }
  }

  void setOverlaySessions(Set<String> ids) {
    overlaySessionIds = Set.unmodifiable(ids);
    _notify();
  }

  FixedObstacleCalibrationTarget? targetById(String sourceId) {
    for (final target in targets) {
      if (target.sourceId == sourceId) return target;
    }
    return null;
  }

  LatLng targetCenter(
    FixedObstacleCalibrationTarget target,
    FixedObstacleCalibration calibration,
  ) {
    final points = _calibrationService.translatePoints(
      target.sourcePoints,
      calibration,
    );
    final lat = points.fold<double>(0, (sum, point) => sum + point.latitude) /
        points.length;
    final lng = points.fold<double>(0, (sum, point) => sum + point.longitude) /
        points.length;
    return LatLng(lat, lng);
  }

  double _roundToStep(double value) =>
      (value / stepMeters).round() * stepMeters;

  List<Session> get overlaySessions => recentSessions
      .where((session) => overlaySessionIds.contains(session.id))
      .toList(growable: false);

  String sessionLabel(Session session) {
    final date = session.startedAt.toLocal();
    return '${date.month}/${date.day} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}'
        '・${(session.summary.totalDistanceMeters / 1000).toStringAsFixed(1)}km';
  }

  String get overlaySelectionLabel {
    if (recentSessions.isEmpty) return '比較できる航行記録がありません';
    if (overlaySessionIds.isEmpty) return '航跡を表示しない';
    return '比較する航行記録：${overlaySessionIds.length}件';
  }

  // ## 地図に重ねるもの

  Set<Polygon> buildPolygons() {
    return {
      for (final obstacle in obstacles)
        if (obstacle.points.length >= 3)
          Polygon(
            polygonId: PolygonId('calibration_${obstacle.id}'),
            points: obstacle.points,
            strokeWidth: obstacle.sourceId == _selectedId ? 4 : 1,
            strokeColor: obstacle.sourceId == _selectedId
                ? Colors.red.shade800
                : Colors.orange.shade700,
            fillColor:
                (obstacle.sourceId == _selectedId ? Colors.red : Colors.orange)
                    .withValues(
              alpha: obstacle.sourceId == _selectedId ? 0.38 : 0.14,
            ),
            consumeTapEvents: !busy && obstacle.sourceId != null,
            onTap: busy || obstacle.sourceId == null
                ? null
                : () => select(obstacle.sourceId),
          ),
    };
  }

  Set<Circle> buildCircles() => {
        ..._buildAccuracyCircles(),
        ..._buildVertexCircles(),
      };

  Set<Circle> _buildVertexCircles() {
    final target = selectedTarget;
    if (target == null) return const {};
    final adjusted = _calibrationService.translatePoints(
      target.sourcePoints,
      draft,
    );
    return {
      for (final entry in adjusted.indexed)
        Circle(
          circleId:
              CircleId('calibration_vertex_${target.sourceId}_${entry.$1}'),
          center: entry.$2,
          radius: selectedPointIndex == entry.$1 ? 4.8 : 2.8,
          strokeWidth: selectedPointIndex == entry.$1 ? 3 : 2,
          strokeColor: selectedPointIndex == entry.$1
              ? Colors.greenAccent
              : Colors.lightBlueAccent,
          fillColor:
              (selectedPointIndex == entry.$1 ? Colors.green : Colors.lightBlue)
                  .withValues(alpha: 0.82),
          consumeTapEvents: true,
          onTap: () => selectVertex(entry.$1),
        ),
    };
  }

  Set<Polyline> buildPolylines() {
    final lines = <Polyline>{};
    final target = selectedTarget;
    if (target != null && target.sourcePoints.length >= 2) {
      final adjusted = _calibrationService.translatePoints(
        target.sourcePoints,
        draft,
      );
      lines.addAll({
        Polyline(
          polylineId: const PolylineId('calibration_original'),
          points: target.sourcePoints,
          width: 4,
          color: Colors.white.withValues(alpha: 0.9),
        ),
        Polyline(
          polylineId: const PolylineId('calibration_adjusted'),
          points: adjusted,
          width: 4,
          color: Colors.lightBlueAccent,
        ),
      });
    }
    for (final entry in overlaySessions.indexed) {
      final index = entry.$1;
      final session = entry.$2;
      if (session.points.length < 2) continue;
      final sampled = _sampleTrack(session.points);
      final baseColor = trackColors[index % trackColors.length];
      for (final segmentEntry
          in trackOverlayService.buildFilteredSegments(sampled).indexed) {
        final segment = segmentEntry.$2;
        lines.add(Polyline(
          polylineId: PolylineId(
            'calibration_filtered_track_${session.id}_${segmentEntry.$1}',
          ),
          points: [
            for (final vertex in segment.vertices)
              LatLng(vertex.lat, vertex.lng),
          ],
          width: segment.quality == CalibrationTrackQuality.reliable ? 4 : 3,
          color: baseColor.withValues(
            alpha:
                segment.quality == CalibrationTrackQuality.reliable ? 0.9 : 0.3,
          ),
        ));
      }
      for (final segmentEntry
          in trackOverlayService.buildRawSegments(sampled).indexed) {
        final segment = segmentEntry.$2;
        lines.add(Polyline(
          polylineId: PolylineId(
            'calibration_raw_track_${session.id}_${segmentEntry.$1}',
          ),
          points: [
            for (final vertex in segment.vertices)
              LatLng(vertex.lat, vertex.lng),
          ],
          width: 2,
          color: Colors.blueGrey.shade200.withValues(
            alpha: segment.quality == CalibrationTrackQuality.reliable
                ? 0.65
                : 0.2,
          ),
          patterns: [PatternItem.dash(10), PatternItem.gap(7)],
        ));
      }
    }
    return lines;
  }

  Set<Circle> _buildAccuracyCircles() {
    final circles = <Circle>{};
    for (final entry in overlaySessions.indexed) {
      final session = entry.$2;
      if (session.points.isEmpty) continue;
      final trackColor = trackColors[entry.$1 % trackColors.length];
      final usablePoints = session.points
          .where((point) =>
              point.gnssAccuracyMeters == null ||
              (point.gnssAccuracyMeters!.isFinite &&
                  point.gnssAccuracyMeters! <=
                      CalibrationTrackOverlayService.excludedAccuracyMeters))
          .toList(growable: false);
      if (usablePoints.isNotEmpty) {
        circles.addAll({
          Circle(
            circleId: CircleId('track_start_${session.id}'),
            center: LatLng(usablePoints.first.lat, usablePoints.first.lng),
            radius: 3,
            strokeWidth: 2,
            strokeColor: Colors.black87,
            fillColor: trackColor,
          ),
          Circle(
            circleId: CircleId('track_end_${session.id}'),
            center: LatLng(usablePoints.last.lat, usablePoints.last.lng),
            radius: 5,
            strokeWidth: 2,
            strokeColor: Colors.white,
            fillColor: trackColor,
          ),
        });
      }
      const maxAccuracyCircles = 60;
      final accuracyStep = (session.points.length / maxAccuracyCircles)
          .ceil()
          .clamp(1, 1000000)
          .toInt();
      for (var index = 0;
          index < session.points.length;
          index += accuracyStep) {
        final point = session.points[index];
        final accuracy = point.gnssAccuracyMeters;
        if (accuracy == null || !accuracy.isFinite || accuracy <= 0) continue;
        circles.add(Circle(
          circleId: CircleId('accuracy_${session.id}_$index'),
          center: LatLng(point.rawLat ?? point.lat, point.rawLng ?? point.lng),
          radius: accuracy.clamp(1.0, 50.0).toDouble(),
          strokeWidth: 1,
          strokeColor: Colors.blueGrey.withValues(alpha: 0.18),
          fillColor: Colors.blueGrey.withValues(alpha: 0.05),
        ));
      }
    }
    return circles;
  }

  Set<Marker> buildMarkers() {
    final markers = <Marker>{};
    for (final session in overlaySessions) {
      for (final pin in trackOverlayService.warningPins(session)) {
        final point = pin.trackPoint;
        final accuracy = point.gnssAccuracyMeters;
        final accuracyLabel = accuracy == null
            ? '精度記録なし'
            : 'GPS精度 ${accuracy.toStringAsFixed(1)}m';
        markers.add(Marker(
          markerId:
              MarkerId('calibration_alert_${session.id}_${pin.episodeId}'),
          position: LatLng(point.lat, point.lng),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            pin.isPositionMismatch
                ? BitmapDescriptor.hueViolet
                : BitmapDescriptor.hueRed,
          ),
          infoWindow: InfoWindow(
            title: pin.isPositionMismatch ? '位置ずれ評価' : '警告開始地点',
            snippet: '${sessionLabel(session)}・$accuracyLabel・${pin.category}',
          ),
        ));
      }
    }
    return markers;
  }

  List<TrackPoint> _sampleTrack(List<TrackPoint> points) {
    const maxRenderedTrackPoints = 1200;
    if (points.length <= maxRenderedTrackPoints) return points;
    final step = (points.length / maxRenderedTrackPoints).ceil();
    return [
      for (var index = 0; index < points.length; index += step) points[index],
      if ((points.length - 1) % step != 0) points.last,
    ];
  }
}
