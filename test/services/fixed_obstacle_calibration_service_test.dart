import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/fixed_obstacle_calibration.dart';
import 'package:rowing_navigator/services/fixed_obstacle_calibration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = FixedObstacleCalibrationService();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('障害物単位の東西・南北補正を保存して再読込できる', () async {
    const calibration = FixedObstacleCalibration(
      northMeters: 2.5,
      eastMeters: -1.5,
    );

    await service.save('bridge_suigo', calibration);
    final loaded = await service.loadAll();

    expect(loaded['bridge_suigo']?.northMeters, 2.5);
    expect(loaded['bridge_suigo']?.eastMeters, -1.5);
  });

  test('ゼロ補正または個別リセットで保存対象から除外する', () async {
    await service.save(
      'bridge_suigo',
      const FixedObstacleCalibration(northMeters: 1),
    );
    await service.save(
      'bridge_suigo',
      const FixedObstacleCalibration(),
    );
    expect(await service.loadAll(), isEmpty);

    await service.save(
      'bridge_suigo',
      const FixedObstacleCalibration(eastMeters: 1),
    );
    await service.reset('bridge_suigo');
    expect(await service.loadAll(), isEmpty);
  });

  test('北・東への平行移動をメートル単位で座標へ反映する', () {
    const source = LatLng(36.075, 140.205);
    final moved = service.translatePoint(
      source,
      const FixedObstacleCalibration(
        northMeters: 10,
        eastMeters: 10,
      ),
    );

    // 緯度36度付近では、10mは緯度約0.00009度・経度約0.00011度。
    expect(moved.latitude, closeTo(36.0750899, 0.000002));
    expect(moved.longitude, closeTo(140.205111, 0.000003));
  });

  test('選択した頂点だけを東西・南北補正できる', () {
    const source = [
      LatLng(36.075, 140.205),
      LatLng(36.076, 140.206),
    ];
    final moved = service.translatePoints(
      source,
      const FixedObstacleCalibration(
        vertexOffsets: {
          1: FixedObstacleVertexOffset(northMeters: 5, eastMeters: -3),
        },
      ),
    );

    expect(moved.first, source.first);
    expect(moved[1].latitude, greaterThan(source[1].latitude));
    expect(moved[1].longitude, lessThan(source[1].longitude));
  });

  test('頂点補正を保存して再読込できる', () async {
    const calibration = FixedObstacleCalibration(
      vertexOffsets: {
        4: FixedObstacleVertexOffset(northMeters: 1.5, eastMeters: -2),
      },
    );

    await service.save('shore_north', calibration);
    final loaded = await service.loadAll();

    expect(loaded['shore_north']?.vertexOffsetFor(4).northMeters, 1.5);
    expect(loaded['shore_north']?.vertexOffsetFor(4).eastMeters, -2);
  });

  test('上限を超える壊れた保存値は無視する', () async {
    SharedPreferences.setMockInitialValues({
      'fixed_obstacle_calibrations_v1':
          '{"bridge_suigo":{"northMeters":31,"eastMeters":0}}',
    });

    expect(await service.loadAll(), isEmpty);
  });

  test('型が壊れた項目だけを無視して正常な校正を維持する', () async {
    SharedPreferences.setMockInitialValues({
      'fixed_obstacle_calibrations_v1':
          '{"broken":{"northMeters":"north","eastMeters":[]},'
              '"valid":{"northMeters":1.5,"eastMeters":-2.0}}',
    });

    final loaded = await service.loadAll();

    expect(loaded, hasLength(1));
    expect(loaded['valid']?.northMeters, 1.5);
    expect(loaded['valid']?.eastMeters, -2);
  });
}
