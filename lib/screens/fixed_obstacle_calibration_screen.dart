import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/fixed_obstacle_calibration.dart';
import '../models/session_model.dart';
import '../models/static_obstacle_model.dart';
import '../services/calibration_track_overlay_service.dart';
import '../services/fixed_obstacle_calibration_service.dart';
import '../services/preset_obstacle_service.dart';
import '../services/session_store_service.dart';
import '../services/shared_safety_calibration_service.dart';
import '../services/team_service.dart';
import '../widgets/app_state_views.dart';
import '../widgets/fixed_obstacle_calibration_controls.dart';

/// 同梱プリセットを変更せず、端末内の頂点差分を現地校正する画面。
class FixedObstacleCalibrationScreen extends StatefulWidget {
  const FixedObstacleCalibrationScreen({super.key});

  @override
  State<FixedObstacleCalibrationScreen> createState() =>
      _FixedObstacleCalibrationScreenState();
}

class _FixedObstacleCalibrationScreenState
    extends State<FixedObstacleCalibrationScreen> {
  static const _stepMeters = 0.5;
  static const _trackColors = [
    Colors.lightGreenAccent,
    Colors.amberAccent,
    Colors.purpleAccent,
    Colors.tealAccent,
    Colors.pinkAccent,
  ];

  // この画面だけは未公開の端末内下書きを地図へプレビューする。
  // 通常の監視・航行画面は共有確定版を優先し、両者を加算しない。
  final _presetService = PresetObstacleService(
    previewLocalFixedObstacleCalibrations: true,
  );
  final _calibrationService = FixedObstacleCalibrationService();
  final _trackOverlayService = CalibrationTrackOverlayService();
  final _sessionStoreService = SessionStoreService();
  final _sharedCalibrationService = SharedSafetyCalibrationService();

  List<FixedObstacleCalibrationTarget> _targets = const [];
  List<StaticObstacle> _obstacles = const [];
  List<Session> _recentSessions = const [];
  Map<String, FixedObstacleCalibration> _calibrations = const {};
  String? _selectedId;
  int? _selectedPointIndex;
  Set<String> _overlaySessionIds = const {};
  FixedObstacleCalibration _draft = const FixedObstacleCalibration();
  GoogleMapController? _mapController;
  Object? _error;
  bool _loading = true;
  bool _saving = false;
  bool _publishing = false;
  bool _changed = false;
  int _sharedRevision = 0;
  FixedObstacleCalibrationPublishStatus _publishStatus =
      FixedObstacleCalibrationPublishStatus.idle;
  String? _publishMessage;

  bool get _busy => _saving || _publishing;
  bool get _hasTeamMembership => TeamService.activeMembership != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final targets = await _presetService.loadCalibrationTargets();
      final calibrations = await _calibrationService.loadAll();
      final obstacles = await _presetService.loadPresets();
      List<Session> recentSessions;
      try {
        recentSessions = (await _sessionStoreService.listSessions())
            .where((session) => session.points.length >= 2)
            .take(5)
            .toList();
      } catch (_) {
        // 航跡の読込失敗で、固定障害物の校正そのものを止めない。
        recentSessions = const [];
      }
      if (!mounted) return;
      final selectedId = targets.any(
        (target) => target.sourceId == _selectedId,
      )
          ? _selectedId
          : (targets.isEmpty ? null : targets.first.sourceId);
      final recentIds = recentSessions.map((session) => session.id).toSet();
      final selectedSessionIds = _overlaySessionIds.intersection(recentIds);
      if (selectedSessionIds.isEmpty && recentSessions.isNotEmpty) {
        selectedSessionIds.add(recentSessions.first.id);
      }
      setState(() {
        _targets = targets;
        _calibrations = calibrations;
        _obstacles = obstacles;
        _recentSessions = recentSessions;
        _selectedId = selectedId;
        _overlaySessionIds = selectedSessionIds;
        _draft = calibrations[selectedId] ?? const FixedObstacleCalibration();
        _loading = false;
      });
      try {
        final shared = _hasTeamMembership
            ? await _sharedCalibrationService.fetchLatest()
            : await _sharedCalibrationService.loadCached();
        if (!mounted) return;
        setState(() => _sharedRevision = shared?.revision ?? 0);
      } catch (error) {
        if (!mounted) return;
        if (_hasTeamMembership) {
          setState(() {
            _publishStatus = FixedObstacleCalibrationPublishStatus.failure;
            _publishMessage = '共有版の更新状況を取得できませんでした。'
                '端末内の位置調整は続けられます。';
          });
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _select(String? sourceId) async {
    if (sourceId == null || _busy) return;
    final target = _targetById(sourceId);
    if (target == null) return;
    setState(() {
      _selectedId = sourceId;
      _draft = _calibrations[sourceId] ?? const FixedObstacleCalibration();
      _selectedPointIndex = null;
    });
    final controller = _mapController;
    if (controller != null) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(_targetCenter(target, _draft), 18),
      );
    }
  }

  Future<void> _saveDraft(FixedObstacleCalibration value) async {
    final sourceId = _selectedId;
    if (sourceId == null || _busy) return;
    final normalized = FixedObstacleCalibration(
      northMeters: _roundToStep(value.northMeters),
      eastMeters: _roundToStep(value.eastMeters),
      vertexOffsets: value.vertexOffsets,
    );
    setState(() {
      _saving = true;
      _draft = normalized;
    });
    try {
      await _calibrationService.save(sourceId, normalized);
      if (!mounted) return;
      final calibrations =
          Map<String, FixedObstacleCalibration>.from(_calibrations);
      if (normalized.isZero) {
        calibrations.remove(sourceId);
      } else {
        calibrations[sourceId] = normalized;
      }
      setState(() {
        _calibrations = calibrations;
        if (_selectedId == sourceId) {
          _draft = calibrations[sourceId] ?? const FixedObstacleCalibration();
        }
        _changed = true;
        _publishStatus = FixedObstacleCalibrationPublishStatus.idle;
        _publishMessage = null;
      });
      try {
        final obstacles = await _presetService.loadPresets();
        if (!mounted) return;
        setState(() => _obstacles = obstacles);
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '位置補正は保存しましたが、地図プレビューを更新できませんでした: $error',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('位置補正を保存できませんでした: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _nudge({
    double northDelta = 0,
    double eastDelta = 0,
  }) {
    final pointIndex = _selectedPointIndex;
    if (pointIndex == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地図上の色付き座標点を選択してください。')),
      );
      return Future.value();
    }
    final current = _draft.vertexOffsetFor(pointIndex);
    return _saveDraft(_draft.withVertexOffset(
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

  Future<void> _resetSelectedPoint() async {
    final pointIndex = _selectedPointIndex;
    if (pointIndex == null || _busy) return;
    await _saveDraft(
      _draft.withVertexOffset(
        pointIndex,
        const FixedObstacleVertexOffset(),
      ),
    );
  }

  Future<void> _resetAll() async {
    if (_busy || _calibrations.isEmpty) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('すべての位置補正を解除しますか？'),
            content: const Text(
              'この端末で行った固定障害物の位置調整をすべて削除し、'
              '同梱された基準位置へ戻します。危険範囲の幅設定は変わりません。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('すべて解除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      await _calibrationService.resetAll();
      if (!mounted) return;
      setState(() {
        _calibrations = const {};
        _draft = const FixedObstacleCalibration();
        _changed = true;
        _publishStatus = FixedObstacleCalibrationPublishStatus.idle;
        _publishMessage = null;
      });
      try {
        final obstacles = await _presetService.loadPresets();
        if (!mounted) return;
        setState(() => _obstacles = obstacles);
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '位置補正はすべて解除しましたが、地図プレビューを更新できませんでした: $error',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('位置補正を解除できませんでした: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _publishToTeam() async {
    if (!_hasTeamMembership || _busy) return;
    final items = <FixedObstacleCalibrationPublishItem>[
      for (final target in _targets)
        if (_calibrations[target.sourceId] case final calibration?)
          FixedObstacleCalibrationPublishItem(
            target: target,
            calibration: calibration,
            beforeCenter: _targetCenter(
              target,
              const FixedObstacleCalibration(),
            ),
            afterCenter: _targetCenter(target, calibration),
          ),
    ];
    // 全補正を0mへ戻す公開も確認できるよう、調整対象を1件表示する。
    if (items.isEmpty && _selectedId != null) {
      final target = _targetById(_selectedId!);
      if (target != null) {
        final center = _targetCenter(
          target,
          const FixedObstacleCalibration(),
        );
        items.add(FixedObstacleCalibrationPublishItem(
          target: target,
          calibration: const FixedObstacleCalibration(),
          beforeCenter: center,
          afterCenter: center,
        ));
      }
    }
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => FixedObstacleCalibrationPublishConfirmation(
            items: items,
            referenceSessionLabels: [
              for (final session in _overlaySessions)
                '${_sessionLabel(session)}・'
                    '${_trackOverlayService.directionLabel(session)}',
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() {
      _publishing = true;
      _publishStatus = FixedObstacleCalibrationPublishStatus.publishing;
      _publishMessage = null;
    });
    try {
      final saved = await _sharedCalibrationService.publishCalibrations(
        calibrations: _calibrations,
        expectedRevision: _sharedRevision,
      );
      if (!mounted) return;
      setState(() {
        _sharedRevision = saved.revision;
        _publishStatus = FixedObstacleCalibrationPublishStatus.success;
        _publishMessage = 'チームへ公開しました（版 ${saved.revision}）。';
      });
    } on SharedSafetyCalibrationConflictException {
      if (!mounted) return;
      var message = '他の端末が先に更新しました。最新版を取得して、'
          '内容を確認してから再公開してください。';
      try {
        final latest = await _sharedCalibrationService.fetchLatest(
          forceServer: true,
        );
        if (!mounted) return;
        _sharedRevision = latest?.revision ?? 0;
        message = '他の端末が先に更新しました。最新版（版 $_sharedRevision）を'
            '取得したため、内容を確認して再公開してください。';
      } catch (_) {
        // 競合自体を優先表示し、再取得失敗で端末内の下書きを失わない。
      }
      if (mounted) {
        setState(() {
          _publishStatus = FixedObstacleCalibrationPublishStatus.conflict;
          _publishMessage = message;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _publishStatus = FixedObstacleCalibrationPublishStatus.failure;
        _publishMessage = '公開できませんでした: $error';
      });
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  FixedObstacleCalibrationTarget? _targetById(String sourceId) {
    for (final target in _targets) {
      if (target.sourceId == sourceId) return target;
    }
    return null;
  }

  LatLng _targetCenter(
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

  void _selectVertex(int pointIndex) {
    if (_busy) return;
    setState(() => _selectedPointIndex = pointIndex);
  }

  Set<Circle> _buildVertexCircles() {
    final sourceId = _selectedId;
    if (sourceId == null) return const {};
    final target = _targetById(sourceId);
    if (target == null) return const {};
    final adjusted = _calibrationService.translatePoints(
      target.sourcePoints,
      _draft,
    );
    return {
      for (final entry in adjusted.indexed)
        Circle(
          circleId: CircleId('calibration_vertex_${sourceId}_${entry.$1}'),
          center: entry.$2,
          radius: _selectedPointIndex == entry.$1 ? 4.8 : 2.8,
          strokeWidth: _selectedPointIndex == entry.$1 ? 3 : 2,
          strokeColor: _selectedPointIndex == entry.$1
              ? Colors.greenAccent
              : Colors.lightBlueAccent,
          fillColor: (_selectedPointIndex == entry.$1
                  ? Colors.green
                  : Colors.lightBlue)
              .withValues(alpha: 0.82),
          consumeTapEvents: true,
          onTap: () => _selectVertex(entry.$1),
        ),
    };
  }

  Widget _buildVertexControls(BuildContext context) {
    final pointIndex = _selectedPointIndex;
    if (pointIndex == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '地図上の青い座標点をタップして選択してください。選んだ点だけが緑色になり、矢印で動かせます。',
          ),
        ),
      );
    }
    final offset = _draft.vertexOffsetFor(pointIndex);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '調整中の座標点 #${pointIndex + 1}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '北 ${_signedMeters(offset.northMeters)}　'
                  '東 ${_signedMeters(offset.eastMeters)}'
                  '${_saving ? '　保存中…' : '　端末内に保存'}',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filledTonal(
              tooltip: '西へ0.5m',
              onPressed: _busy ? null : () => _nudge(eastDelta: -_stepMeters),
              icon: const Icon(Icons.west),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                IconButton.filledTonal(
                  tooltip: '北へ0.5m',
                  onPressed:
                      _busy ? null : () => _nudge(northDelta: _stepMeters),
                  icon: const Icon(Icons.north),
                ),
                IconButton.filledTonal(
                  tooltip: '南へ0.5m',
                  onPressed:
                      _busy ? null : () => _nudge(northDelta: -_stepMeters),
                  icon: const Icon(Icons.south),
                ),
              ],
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: '東へ0.5m',
              onPressed: _busy ? null : () => _nudge(eastDelta: _stepMeters),
              icon: const Icon(Icons.east),
            ),
          ],
        ),
        TextButton.icon(
          onPressed: _busy || offset.isZero ? null : _resetSelectedPoint,
          icon: const Icon(Icons.restore),
          label: const Text('この座標点を基準位置へ戻す'),
        ),
      ],
    );
  }

  String _signedMeters(double value) =>
      '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}m';

  Set<Polygon> _buildPolygons() {
    return {
      for (final obstacle in _obstacles)
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
            consumeTapEvents: !_busy && obstacle.sourceId != null,
            onTap: _busy || obstacle.sourceId == null
                ? null
                : () => _select(obstacle.sourceId),
          ),
    };
  }

  Set<Polyline> _buildReferenceLines() {
    final lines = <Polyline>{};
    final sourceId = _selectedId;
    if (sourceId != null) {
      final target = _targetById(sourceId);
      if (target != null && target.sourcePoints.length >= 2) {
        final adjusted = _calibrationService.translatePoints(
          target.sourcePoints,
          _draft,
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
    }
    for (final entry in _overlaySessions.indexed) {
      final index = entry.$1;
      final session = entry.$2;
      if (session.points.length < 2) continue;
      final sampled = _sampleTrack(session.points);
      final baseColor = _trackColors[index % _trackColors.length];
      for (final segmentEntry
          in _trackOverlayService.buildFilteredSegments(sampled).indexed) {
        final segmentIndex = segmentEntry.$1;
        final segment = segmentEntry.$2;
        lines.add(Polyline(
          polylineId: PolylineId(
            'calibration_filtered_track_${session.id}_$segmentIndex',
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
          in _trackOverlayService.buildRawSegments(sampled).indexed) {
        final segmentIndex = segmentEntry.$1;
        final segment = segmentEntry.$2;
        lines.add(Polyline(
          polylineId: PolylineId(
            'calibration_raw_track_${session.id}_$segmentIndex',
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
          patterns: [
            PatternItem.dash(10),
            PatternItem.gap(7),
          ],
        ));
      }
    }
    return lines;
  }

  Set<Circle> _buildAccuracyCircles() {
    final circles = <Circle>{};
    for (final entry in _overlaySessions.indexed) {
      final sessionIndex = entry.$1;
      final session = entry.$2;
      if (session.points.isEmpty) continue;
      final trackColor = _trackColors[sessionIndex % _trackColors.length];
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
          center: LatLng(
            point.rawLat ?? point.lat,
            point.rawLng ?? point.lng,
          ),
          radius: accuracy.clamp(1.0, 50.0).toDouble(),
          strokeWidth: 1,
          strokeColor: Colors.blueGrey.withValues(alpha: 0.18),
          fillColor: Colors.blueGrey.withValues(alpha: 0.05),
        ));
      }
    }
    return circles;
  }

  Set<Marker> _buildAlertMarkers() {
    final markers = <Marker>{};
    for (final session in _overlaySessions) {
      for (final pin in _trackOverlayService.warningPins(session)) {
        final point = pin.trackPoint;
        final accuracy = point.gnssAccuracyMeters;
        final accuracyLabel = accuracy == null
            ? '精度記録なし'
            : 'GPS精度 ${accuracy.toStringAsFixed(1)}m';
        markers.add(Marker(
          markerId: MarkerId(
            'calibration_alert_${session.id}_${pin.episodeId}',
          ),
          position: LatLng(point.lat, point.lng),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            pin.isPositionMismatch
                ? BitmapDescriptor.hueViolet
                : BitmapDescriptor.hueRed,
          ),
          infoWindow: InfoWindow(
            title: pin.isPositionMismatch ? '位置ずれ評価' : '警告開始地点',
            snippet: '${_sessionLabel(session)}・$accuracyLabel・${pin.category}',
          ),
        ));
      }
    }
    return markers;
  }

  List<Session> get _overlaySessions => _recentSessions
      .where((session) => _overlaySessionIds.contains(session.id))
      .toList(growable: false);

  List<TrackPoint> _sampleTrack(List<TrackPoint> points) {
    const maxRenderedTrackPoints = 1200;
    if (points.length <= maxRenderedTrackPoints) return points;
    final step = (points.length / maxRenderedTrackPoints).ceil();
    return [
      for (var index = 0; index < points.length; index += step) points[index],
      if ((points.length - 1) % step != 0) points.last,
    ];
  }

  String _sessionLabel(Session session) {
    final date = session.startedAt.toLocal();
    return '${date.month}/${date.day} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}'
        '・${(session.summary.totalDistanceMeters / 1000).toStringAsFixed(1)}km';
  }

  Future<void> _chooseOverlaySessions() async {
    if (_recentSessions.isEmpty) return;
    final selected = Set<String>.from(_overlaySessionIds);
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('比較する航行記録'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 420,
              maxHeight: 360,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final session in _recentSessions)
                  CheckboxListTile(
                    value: selected.contains(session.id),
                    title: Text(_sessionLabel(session)),
                    subtitle: Text(
                      '${session.points.length}点'
                      '・${_trackOverlayService.directionLabel(session)}'
                      '${session.alertEvents.isEmpty ? '' : '・警告記録あり'}',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (checked) => setDialogState(() {
                      if (checked ?? false) {
                        selected.add(session.id);
                      } else {
                        selected.remove(session.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, <String>{}),
              child: const Text('すべて非表示'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: const Text('適用'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _overlaySessionIds = Set.unmodifiable(result));
  }

  String get _overlaySelectionLabel {
    if (_recentSessions.isEmpty) return '比較できる航行記録がありません';
    if (_overlaySessionIds.isEmpty) return '航跡を表示しない';
    return '比較する航行記録：${_overlaySessionIds.length}件';
  }

  Widget _buildOverlayLegend(BuildContext context) {
    final sessions = _overlaySessions;
    if (sessions.isEmpty) return const SizedBox.shrink();
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in sessions.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 5,
                      decoration: BoxDecoration(
                        color: _trackColors[entry.$1 % _trackColors.length],
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_sessionLabel(entry.$2)}・'
                        '${_trackOverlayService.directionLabel(entry.$2)}',
                        style: textStyle,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 3),
            Text(
              '小さい黒縁が開始、大きい白縁が終了。薄い線はGPS精度12〜25m、'
              '25m超は線を接続しません。',
              style: textStyle,
            ),
          ],
        ),
      ),
    );
  }

  double _roundToStep(double value) =>
      (value / _stepMeters).round() * _stepMeters;

  @override
  Widget build(BuildContext context) {
    return FixedObstacleCalibrationSaveGuard(
      saving: _busy,
      onBlockedPop: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('位置補正を保存しています。完了後に戻れます。')),
        );
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('既設危険区域の位置の調整'),
          leading: IconButton(
            tooltip: '戻る',
            icon: const Icon(Icons.arrow_back),
            onPressed: _busy ? null : () => Navigator.pop(context, _changed),
          ),
          actions: [
            IconButton(
              tooltip: 'すべての位置補正を解除',
              onPressed: _busy || _calibrations.isEmpty ? null : _resetAll,
              icon: const Icon(Icons.restore_page_outlined),
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const AppLoadingView(message: '固定障害物を読み込んでいます…');
    }
    if (_error != null || _targets.isEmpty) {
      return AppErrorView(
        title: '固定障害物を読み込めません',
        message: _error?.toString() ?? '調整できる固定障害物がありません。',
        primaryLabel: '再試行',
        onPrimary: _load,
      );
    }
    final selected = _selectedId == null ? null : _targetById(_selectedId!);
    final initialTarget = selected == null
        ? _targets.first.sourcePoints.first
        : _targetCenter(selected, _draft);
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout =
            FixedObstacleCalibrationLayoutSpec.fromConstraints(constraints);
        final isLandscape = layout.isLandscape;
        final panelWidth = layout.panelWidth;
        final portraitPanelHeight = layout.portraitPanelHeight;
        return Stack(
          children: [
            GoogleMap(
              initialCameraPosition: CameraPosition(
                target: initialTarget,
                zoom: 18,
              ),
              mapType: MapType.hybrid,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              padding: layout.mapPadding,
              polygons: _buildPolygons(),
              polylines: _buildReferenceLines(),
              circles: {
                ..._buildAccuracyCircles(),
                ..._buildVertexCircles(),
              },
              markers: _buildAlertMarkers(),
              onMapCreated: (controller) => _mapController = controller,
            ),
            Positioned(
              top: 12,
              left: 12,
              right: isLandscape ? panelWidth + 12 : 12,
              child: Material(
                color: Colors.black.withValues(alpha: 0.76),
                borderRadius: BorderRadius.circular(12),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '航行中には操作しないでください。橋下のGPS 1点だけで決めず、'
                    '航空写真と複数回・両方向の航跡を照合します。'
                    '白線が補正前、水色線が調整後、青い点は動かせる座標点、'
                    '緑の点は選択中の座標点です。色付き線が推定航跡、'
                    '灰色破線が生GPS、薄い円が測位精度、赤ピンが警告開始、'
                    '紫ピンが「位置ずれ」評価です。',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
            Align(
              alignment:
                  isLandscape ? Alignment.centerRight : Alignment.bottomCenter,
              child: SizedBox(
                width: panelWidth,
                height: isLandscape ? constraints.maxHeight : null,
                child: SafeArea(
                  top: false,
                  left: false,
                  child: Material(
                    elevation: 12,
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: isLandscape
                        ? const BorderRadius.horizontal(
                            left: Radius.circular(20),
                          )
                        : const BorderRadius.vertical(
                            top: Radius.circular(20),
                          ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: isLandscape
                            ? constraints.maxHeight
                            : portraitPanelHeight,
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FixedObstacleCalibrationTargetDropdown(
                              targets: _targets,
                              selectedId: _selectedId,
                              saving: _busy,
                              onChanged: _select,
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _recentSessions.isEmpty
                                  ? null
                                  : _chooseOverlaySessions,
                              icon: const Icon(Icons.layers_outlined),
                              label: Text(_overlaySelectionLabel),
                            ),
                            if (_overlaySessions.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              _buildOverlayLegend(context),
                            ],
                            const SizedBox(height: 8),
                            _buildVertexControls(context),
                            const SizedBox(height: 8),
                            FixedObstacleCalibrationPublishPanel(
                              status: _publishStatus,
                              statusMessage: _hasTeamMembership
                                  ? _publishMessage
                                  : '共有確定版: 版 $_sharedRevision。'
                                      '現在の地図は端末内の下書きです。'
                                      'チームに参加すると公開できます。',
                              enabled: !_busy,
                              showPublishButton: _hasTeamMembership,
                              onPublish: _publishToTeam,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
