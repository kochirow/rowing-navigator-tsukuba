import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/fixed_obstacle_calibration.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/fixed_obstacle_calibration_service.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/services/shared_safety_calibration_service.dart';
import 'package:rowing_navigator/models/shared_safety_calibration.dart';
import 'package:rowing_navigator/utils/metric_polygon_buffer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('旧アプリの固定区域と案内・テスト区域を読み込む', () async {
    final service = PresetObstacleService();
    final obstacles = await service.loadPresets();
    // 閉じた固定流木は5本の辺リボンではなく、1枚の塗りつぶしにする。
    expect(obstacles, hasLength(346));
    expect(obstacles.every((obstacle) => obstacle.isDefault), isTrue);
    // 近接注意距離はkind別の既定値を使う。プロファイルの
    // defaultObstacleProximityCautionMeters が0のときは「指定なし」として
    // 上書きせず、0で機能を止めることはしない。
    expect(
      obstacles.where((obstacle) => !obstacle.kind.isEntryGuidance).every(
            (obstacle) => obstacle.proximityCautionDistanceMeters == null,
          ),
      isTrue,
    );
    expect(
      obstacles
          .where((obstacle) => obstacle.kind == StaticObstacleKind.shore)
          .every((obstacle) => obstacle.effectiveProximityCautionMeters == 3.0),
      isTrue,
    );
    expect(
      obstacles
          .where((obstacle) => obstacle.kind == StaticObstacleKind.driftwood)
          .every((obstacle) => obstacle.effectiveProximityCautionMeters == 6.0),
      isTrue,
    );
    expect(
      obstacles
          .any((obstacle) => obstacle.id.startsWith('default_shore_north')),
      isTrue,
    );
    expect(
      obstacles
          .any((obstacle) => obstacle.id.startsWith('default_bridge_gakuen')),
      isTrue,
    );
    // 橋脚が未入力の橋は、桁の既存警告を消さず縮退運転を続ける。
    expect(service.lastUnplottedBridgeIds, contains('bridge_gakuen'));
    expect(service.lastOrphanedBridgePiers, isEmpty);
    expect(
      obstacles
          .where((obstacle) => obstacle.sourceId == 'island_upstream')
          .every((obstacle) => !obstacle.isWarningEnabled),
      isTrue,
    );
    expect(
      obstacles
          .where(
            (obstacle) => obstacle.sourceId == 'island_sakuragawa_bridge',
          )
          .every((obstacle) => obstacle.isWarningEnabled),
      isTrue,
    );
    expect(
      obstacles.where((obstacle) => obstacle.kind == StaticObstacleKind.curve),
      hasLength(7),
    );
    final driftwood = obstacles
        .where((obstacle) => obstacle.kind == StaticObstacleKind.driftwood)
        .toList();
    expect(driftwood, hasLength(1));
    expect(driftwood.single.isManaged, isTrue);
    expect(driftwood.single.points, hasLength(5));
    expect(
      obstacles
          .where((obstacle) => obstacle.kind == StaticObstacleKind.reverse),
      hasLength(1),
    );
    expect(
      obstacles
          .where((obstacle) => obstacle.kind == StaticObstacleKind.testZone),
      hasLength(4),
    );
  });

  test('production設定ではtestZoneを同梱判定から除外する', () async {
    final obstacles = await PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
    ).loadPresets();
    expect(
      obstacles.any(
        (obstacle) => obstacle.kind == StaticObstacleKind.testZone,
      ),
      isFalse,
    );
    expect(obstacles, isNotEmpty);
  });

  test('端末の警告対象設定を固定対象物へ反映する', () async {
    SharedPreferences.setMockInitialValues({
      'fixed_obstacle_warning_settings_v1': '["bridge_suigo"]',
    });

    final obstacles = await PresetObstacleService().loadPresets();

    expect(
      obstacles
          .where((obstacle) => obstacle.sourceId == 'bridge_suigo')
          .every((obstacle) => !obstacle.isWarningEnabled),
      isTrue,
    );
    // 明示保存後は、ユーザーが島2をオンにした状態もそのまま保持する。
    expect(
      obstacles
          .where((obstacle) => obstacle.sourceId == 'island_upstream')
          .every((obstacle) => obstacle.isWarningEnabled),
      isTrue,
    );
  });

  test('共有済みの警告対象設定は端末内設定より優先する', () async {
    SharedPreferences.setMockInitialValues({
      'fixed_obstacle_warning_settings_v1': '["bridge_suigo"]',
    });
    final sharedService = SharedSafetyCalibrationService(teamId: 'team-a');
    await sharedService.cache(
      SharedSafetyCalibrationState(
        disabledWarningSourceIds: const {'island_upstream'},
        revision: 1,
      ),
    );

    final obstacles = await PresetObstacleService(
      sharedSafetyCalibrationService: sharedService,
    ).loadPresets();

    expect(
      obstacles
          .where((obstacle) => obstacle.sourceId == 'bridge_suigo')
          .every((obstacle) => obstacle.isWarningEnabled),
      isTrue,
    );
    expect(
      obstacles
          .where((obstacle) => obstacle.sourceId == 'island_upstream')
          .every((obstacle) => !obstacle.isWarningEnabled),
      isTrue,
    );
  });

  test('危険区域幅の出所は共有設定あり・端末設定ありでは共有になる', () async {
    SharedPreferences.setMockInitialValues({
      'danger_zone_offset_v1_shore_water': 10.0,
      'danger_zone_offset_v1_shore_land': 15.0,
    });
    final sharedService = SharedSafetyCalibrationService(teamId: 'team-a');
    await sharedService.cache(SharedSafetyCalibrationState(revision: 12));
    final service = PresetObstacleService(
      sharedSafetyCalibrationService: sharedService,
    );

    await service.loadPresets();

    expect(
      service.lastDangerZoneSettingsResolution?.source,
      DangerZoneSettingsSource.shared,
    );
    expect(
      service.lastDangerZoneSettingsResolution?.sharedSafetyRevision,
      12,
    );
  });

  test('危険区域幅の出所は共有設定なし・端末設定ありでは端末のみになる', () async {
    SharedPreferences.setMockInitialValues({
      'danger_zone_offset_v1_shore_water': 10.0,
      'danger_zone_offset_v1_shore_land': 15.0,
    });
    final service = PresetObstacleService(
      sharedSafetyCalibrationService:
          SharedSafetyCalibrationService(teamId: 'team-a'),
    );

    await service.loadPresets();

    expect(
      service.lastDangerZoneSettingsResolution?.source,
      DangerZoneSettingsSource.local,
    );
  });

  test('危険区域幅の出所は共有設定なし・端末設定なしではコード既定値になる', () async {
    final service = PresetObstacleService(
      sharedSafetyCalibrationService:
          SharedSafetyCalibrationService(teamId: 'team-a'),
    );

    await service.loadPresets();

    expect(
      service.lastDangerZoneSettingsResolution?.source,
      DangerZoneSettingsSource.codeDefault,
    );
  });

  test('端末設定があってもローカル読み込み無効時はコード既定値になる', () async {
    SharedPreferences.setMockInitialValues({
      'danger_zone_offset_v1_shore_water': 10.0,
      'danger_zone_offset_v1_shore_land': 15.0,
    });
    final service = PresetObstacleService(
      useLocalDangerZoneSettings: false,
      sharedSafetyCalibrationService:
          SharedSafetyCalibrationService(teamId: 'team-a'),
    );

    await service.loadPresets();

    expect(
      service.lastDangerZoneSettingsResolution?.source,
      DangerZoneSettingsSource.codeDefault,
    );
  });

  test('端末内の固定障害物校正を同じsourceIdの全ポリゴンへ反映する', () async {
    SharedPreferences.setMockInitialValues({
      'fixed_obstacle_calibrations_v1':
          '{"bridge_suigo":{"northMeters":10.0,"eastMeters":0.0}}',
    });
    final calibrated = await PresetObstacleService().loadPresets();
    SharedPreferences.setMockInitialValues({});
    final original = await PresetObstacleService().loadPresets();

    final calibratedBridge = calibrated.firstWhere(
      (obstacle) => obstacle.sourceId == 'bridge_suigo',
    );
    final originalBridge = original.firstWhere(
      (obstacle) => obstacle.sourceId == 'bridge_suigo',
    );

    expect(
      calibratedBridge.points.first.latitude -
          originalBridge.points.first.latitude,
      closeTo(0.0000899, 0.000002),
    );
    expect(
      calibratedBridge.points.first.longitude,
      closeTo(originalBridge.points.first.longitude, 0.000002),
    );
  });

  test('端末内の流木危険範囲を管理形状の外側余裕へ反映する', () async {
    SharedPreferences.setMockInitialValues({
      'danger_zone_offset_v1_driftwood_water': 0.0,
      'danger_zone_offset_v1_driftwood_land': 0.0,
    });
    final base = (await PresetObstacleService().loadPresets())
        .firstWhere((obstacle) => obstacle.isManaged);
    SharedPreferences.setMockInitialValues({
      'danger_zone_offset_v1_driftwood_water': 10.0,
      'danger_zone_offset_v1_driftwood_land': 10.0,
    });
    final expanded = (await PresetObstacleService().loadPresets())
        .firstWhere((obstacle) => obstacle.isManaged);

    final baseLatitudeSpan = base.points
            .map((point) => point.latitude)
            .reduce((a, b) => a > b ? a : b) -
        base.points
            .map((point) => point.latitude)
            .reduce((a, b) => a < b ? a : b);
    final expandedLatitudeSpan = expanded.points
            .map((point) => point.latitude)
            .reduce((a, b) => a > b ? a : b) -
        expanded.points
            .map((point) => point.latitude)
            .reduce((a, b) => a < b ? a : b);

    expect(expandedLatitudeSpan, greaterThan(baseLatitudeSpan));
  });

  test('共有流木を端末校正してから端末余白を各辺の外周バッファとして適用する', () async {
    const calibration = FixedObstacleCalibration(
      northMeters: 12,
      eastMeters: -4,
    );
    const localMarginMeters = 8.0;
    SharedPreferences.setMockInitialValues({
      'fixed_obstacle_calibrations_v1':
          '{"driftwood_estuary":{"northMeters":12.0,"eastMeters":-4.0}}',
      'danger_zone_offset_v1_driftwood_water': localMarginMeters,
      'danger_zone_offset_v1_driftwood_land': localMarginMeters,
    });
    final recordingBuffer = _RecordingPolygonBuffer();
    final service = PresetObstacleService(polygonBuffer: recordingBuffer);
    final sharedShape = (await service.loadCalibrationTargets())
        .singleWhere((target) => target.sourceId == 'driftwood_estuary')
        .sourcePoints;

    final obstacles = await service.loadPresets();

    expect(recordingBuffer.calls, hasLength(1));
    final call = recordingBuffer.calls.single;
    expect(call.distanceMeters, localMarginMeters);
    final expectedCalibrated = FixedObstacleCalibrationService()
        .translatePoints(sharedShape, calibration);
    expect(call.points, hasLength(expectedCalibrated.length));
    for (var index = 0; index < call.points.length; index++) {
      expect(
        call.points[index].latitude,
        closeTo(expectedCalibrated[index].latitude, 1e-10),
      );
      expect(
        call.points[index].longitude,
        closeTo(expectedCalibrated[index].longitude, 1e-10),
      );
    }

    final driftwood =
        obstacles.singleWhere((obstacle) => obstacle.isManaged).points;
    for (var index = 0; index < call.points.length; index++) {
      final start = call.points[index];
      final end = call.points[(index + 1) % call.points.length];
      final edgeMidpoint = LatLng(
        (start.latitude + end.latitude) / 2,
        (start.longitude + end.longitude) / 2,
      );
      expect(
        _minimumBoundaryDistanceMeters(edgeMidpoint, driftwood),
        closeTo(localMarginMeters, 0.25),
        reason: 'edge $index must retain the configured local margin',
      );
    }
  });

  test('校正対象一覧は基準線と案内区域を元IDで返す', () async {
    final targets = await PresetObstacleService().loadCalibrationTargets();

    expect(
      targets.any((target) => target.sourceId == 'bridge_suigo'),
      isTrue,
    );
    expect(
      targets.any((target) => target.sourceId == 'reverse_main_channel'),
      isTrue,
    );
  });

  test('運用対象水域は10点のポリゴンを返す', () async {
    final coverage = await PresetObstacleService().loadOperationalCoverage();

    expect(coverage, isNotNull);
    expect(coverage, hasLength(10));
    expect(coverage!.first.latitude, closeTo(36.091934, 1e-6));
    expect(coverage.first.longitude, closeTo(140.094594, 1e-6));
    expect(coverage.last.latitude, closeTo(36.094629, 1e-6));
    expect(coverage.last.longitude, closeTo(140.094594, 1e-6));
  });

  // 対応水域が同梱データを覆っていないと、桜川で漕いでいる間ずっと
  // 「未検証水域」の無音system faultが立ち続ける(実機ログで216回primaryを占有)。
  // 実データで覆えていることを不変条件として固定する。
  test('運用対象水域は同梱の全危険区域を内側に含む', () async {
    final service = PresetObstacleService();
    final coverage = await service.loadOperationalCoverage();
    final obstacles = await service.loadPresets();

    expect(coverage, isNotNull);
    for (final obstacle in obstacles) {
      for (final point in obstacle.points) {
        expect(
          _containsPoint(coverage!, point),
          isTrue,
          reason: '${obstacle.id} の頂点 $point が対応水域の外側にある',
        );
      }
    }
  });
}

/// 平面近似(等距円筒図法)での ray casting。対応水域は数km規模で、
/// この近似の誤差は判定に影響しない。
bool _containsPoint(List<LatLng> polygon, LatLng target) {
  double x(LatLng p) =>
      p.longitude * 111320 * cos(target.latitude * pi / 180.0);
  double y(LatLng p) => p.latitude * 110574;

  var inside = false;
  var j = polygon.length - 1;
  for (var i = 0; i < polygon.length; i++) {
    final yi = y(polygon[i]);
    final yj = y(polygon[j]);
    if ((yi > y(target)) != (yj > y(target))) {
      final crossX =
          (x(polygon[j]) - x(polygon[i])) * (y(target) - yi) / (yj - yi) +
              x(polygon[i]);
      if (x(target) < crossX) inside = !inside;
    }
    j = i;
  }
  return inside;
}

class _PolygonBufferCall {
  final List<LatLng> points;
  final double distanceMeters;

  const _PolygonBufferCall({
    required this.points,
    required this.distanceMeters,
  });
}

class _RecordingPolygonBuffer extends MetricPolygonBuffer {
  final List<_PolygonBufferCall> calls = [];

  @override
  List<LatLng> expand(List<LatLng> rawPoints, double distanceMeters) {
    calls.add(_PolygonBufferCall(
      points: List<LatLng>.unmodifiable(rawPoints),
      distanceMeters: distanceMeters,
    ));
    return super.expand(rawPoints, distanceMeters);
  }
}

double _minimumBoundaryDistanceMeters(
  LatLng point,
  List<LatLng> polygon,
) {
  var minimum = double.infinity;
  for (var index = 0; index < polygon.length; index++) {
    minimum = min(
      minimum,
      _pointToSegmentDistanceMeters(
        point,
        polygon[index],
        polygon[(index + 1) % polygon.length],
      ),
    );
  }
  return minimum;
}

double _pointToSegmentDistanceMeters(
  LatLng point,
  LatLng start,
  LatLng end,
) {
  const earthRadiusMeters = 6378137.0;
  final latitudeRadians = point.latitude * pi / 180;

  ({double x, double y}) toLocal(LatLng value) => (
        x: (value.longitude - point.longitude) *
            pi /
            180 *
            cos(latitudeRadians) *
            earthRadiusMeters,
        y: (value.latitude - point.latitude) * pi / 180 * earthRadiusMeters,
      );

  final a = toLocal(start);
  final b = toLocal(end);
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) return sqrt(a.x * a.x + a.y * a.y);
  final projection = ((-a.x * dx - a.y * dy) / lengthSquared).clamp(0.0, 1.0);
  final nearestX = a.x + dx * projection;
  final nearestY = a.y + dy * projection;
  return sqrt(nearestX * nearestX + nearestY * nearestY);
}
