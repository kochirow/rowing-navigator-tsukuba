import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/hazard_profile_config.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/models/fixed_obstacle_calibration.dart';
import 'package:rowing_navigator/models/shared_safety_calibration.dart';

void main() {
  test('共有校正をFirestore形式と端末cache形式で往復できる', () {
    final dangerZones = DangerZoneSettings.defaults().withOffsets(
      DangerZoneKind.bridge,
      const DangerZoneOffsets(
        waterSideMeters: 7.5,
        landSideMeters: 6,
      ),
    );
    final state = SharedSafetyCalibrationState(
      calibrations: const {
        'bridge_suigo': FixedObstacleCalibration(
          northMeters: 2.5,
          eastMeters: -1,
          vertexOffsets: {
            2: FixedObstacleVertexOffset(northMeters: 1, eastMeters: -0.5),
          },
        ),
      },
      dangerZoneSettings: dangerZones,
      disabledWarningSourceIds: const {'bridge_suigo'},
      primaryWarningLeadSeconds: 11,
      advanceWarningLeadSeconds: 15,
      revision: 3,
      updatedAt: DateTime.utc(2026, 7, 23),
      updatedBy: 'owner',
    );

    final firestore = state.toFirestoreMap(
      updatedBy: 'owner',
      updatedAt: Timestamp.fromDate(DateTime.utc(2026, 7, 23)),
      previousState: state.toPreviousStateMap(),
    );
    final restored = SharedSafetyCalibrationState.fromFirestoreMap(firestore);
    final cached = SharedSafetyCalibrationState.fromCacheMap(
      jsonDecode(jsonEncode(state.toCacheMap())) as Map<String, dynamic>,
    );

    expect(restored.revision, 3);
    expect(restored.calibrations['bridge_suigo']?.northMeters, 2.5);
    expect(
      restored.calibrations['bridge_suigo']?.vertexOffsetFor(2).eastMeters,
      -0.5,
    );
    expect(
      restored.dangerZoneSettings[DangerZoneKind.bridge].waterSideMeters,
      7.5,
    );
    expect(restored.disabledWarningSourceIds, {'bridge_suigo'});
    expect(restored.primaryWarningLeadSeconds, 11);
    expect(restored.advanceWarningLeadSeconds, 15);
    expect(cached.disabledWarningSourceIds, {'bridge_suigo'});
    expect(cached.baseProfileSha256, currentHazardProfileSha256);
    expect(cached.updatedAt, DateTime.utc(2026, 7, 23));
  });

  test('未知ID、範囲外の位置補正、不正な危険範囲を拒否する', () {
    expect(
      () => SharedSafetyCalibrationState(
        calibrations: const {
          'unknown': FixedObstacleCalibration(northMeters: 1),
        },
      ),
      throwsFormatException,
    );
    expect(
      () => SharedSafetyCalibrationState.fromCacheMap({
        'baseProfileVersion': currentHazardProfileDataVersion,
        'baseProfileSha256': currentHazardProfileSha256,
        'calibrations': {
          'bridge_suigo': {'northMeters': 31, 'eastMeters': 0},
        },
        'dangerZoneOffsets':
            SharedSafetyCalibrationState().toCacheMap()['dangerZoneOffsets'],
        'revision': 1,
      }),
      throwsFormatException,
    );
    final invalidDangerZones = DangerZoneSettings.defaults().withOffsets(
      DangerZoneKind.shore,
      const DangerZoneOffsets(
        waterSideMeters: 31,
        landSideMeters: 5,
      ),
    );
    expect(
      () => SharedSafetyCalibrationState(
        dangerZoneSettings: invalidDangerZones,
      ),
      throwsFormatException,
    );
    expect(
      () => SharedSafetyCalibrationState(
        disabledWarningSourceIds: const {'unknown'},
      ),
      throwsFormatException,
    );
  });

  test('警告対象がない旧共有文書は初期設定として読み込む', () {
    final legacy = SharedSafetyCalibrationState().toFirestoreMap(
      updatedBy: 'owner',
      updatedAt: Timestamp.fromDate(DateTime.utc(2026, 7, 25)),
    )..remove('disabledWarningSourceIds');

    final restored = SharedSafetyCalibrationState.fromFirestoreMap(legacy);

    expect(
      restored.disabledWarningSourceIds,
      SharedSafetyCalibrationState.defaultDisabledWarningSourceIds,
    );
  });

  test('v3は未知IDと壊れた頂点配列だけを無視して他の校正を保つ', () {
    final state = SharedSafetyCalibrationState(
      calibrations: const {
        'bridge_suigo': FixedObstacleCalibration(
          northMeters: 2,
          vertexOffsets: {
            0: FixedObstacleVertexOffset(eastMeters: 1),
          },
        ),
        'bridge_nioi': FixedObstacleCalibration(
          eastMeters: 3,
          vertexOffsets: {
            1: FixedObstacleVertexOffset(northMeters: -1),
          },
        ),
      },
      revision: 1,
    );
    final firestore = state.toFirestoreMap(
      updatedBy: 'owner',
      updatedAt: Timestamp.fromDate(DateTime.utc(2026, 7, 28)),
    );
    final offsets = Map<String, dynamic>.from(
      firestore['scaledOffsets'] as Map,
    )..['unknown_source'] = const GeoPoint(9, 9);
    final vertexOffsets = Map<String, dynamic>.from(
      firestore['scaledVertexOffsets'] as Map,
    )..['bridge_suigo'] = const [GeoPoint(0, 0)];
    firestore['scaledOffsets'] = offsets;
    firestore['scaledVertexOffsets'] = vertexOffsets;

    final restored = SharedSafetyCalibrationState.fromFirestoreMap(firestore);

    expect(restored.calibrations['unknown_source'], isNull);
    expect(restored.calibrations['bridge_suigo']?.northMeters, 2);
    expect(restored.calibrations['bridge_suigo']?.vertexOffsets, isEmpty);
    expect(restored.calibrations['bridge_nioi']?.eastMeters, 3);
    expect(
      restored.calibrations['bridge_nioi']?.vertexOffsetFor(1).northMeters,
      -1,
    );
  });

  test('モデルのsourceId allowlistは同梱プロフィールと一致する', () {
    final profile = jsonDecode(
      File('assets/data/sakuragawa_obstacles.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final ids = <String>{
      for (final item in profile['obstacles'] as List)
        (item as Map<String, dynamic>)['id'] as String,
      for (final item in profile['dangerZoneBaselines'] as List)
        (item as Map<String, dynamic>)['id'] as String,
    };

    expect(ids, SharedSafetyCalibrationState.allowedSourceIds);
    expect(
      {
        for (final item in profile['obstacles'] as List)
          (item as Map<String, dynamic>)['id'] as String:
              (item['points'] as List).length,
        for (final item in profile['dangerZoneBaselines'] as List)
          (item as Map<String, dynamic>)['id'] as String:
              (item['points'] as List).length,
      },
      SharedSafetyCalibrationState.vertexPointCounts,
    );
    expect(profile['version'], currentHazardProfileDataVersion);
  });
}
