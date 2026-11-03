import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/hazard_profile_config.dart';
import 'package:rowing_navigator/models/fixed_obstacle_calibration.dart';
import 'package:rowing_navigator/models/shared_safety_calibration.dart';
import 'package:rowing_navigator/services/shared_safety_calibration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('共有確定版cacheはチーム単位に分離して保存する', () async {
    final teamA = SharedSafetyCalibrationService(teamId: 'team-a');
    final teamB = SharedSafetyCalibrationService(teamId: 'team-b');
    final state = SharedSafetyCalibrationState(
      calibrations: const {
        'bridge_suigo': FixedObstacleCalibration(northMeters: 2),
      },
      revision: 4,
    );

    await teamA.cache(state);

    expect((await teamA.loadCached())?.revision, 4);
    expect((await teamB.loadCached()), isNull);
  });

  test('v11の共有校正をv12へ持ち越さず、旧cacheを破棄する', () async {
    final old = SharedSafetyCalibrationState(
      baseProfileVersion: 11,
      baseProfileSha256:
          '5bef0edfe2785b357cc2be4014a610430900526c9363e7474b637f102de9e413',
      calibrations: const {
        'pile_3eacc519': FixedObstacleCalibration(
          vertexOffsets: {0: FixedObstacleVertexOffset(northMeters: 4)},
        ),
      },
      revision: 7,
    );
    const key = 'shared_safety_calibration_v2_team-a';
    SharedPreferences.setMockInitialValues({key: jsonEncode(old.toCacheMap())});

    final service = SharedSafetyCalibrationService(teamId: 'team-a');
    expect(await service.loadCached(), isNull);
    expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
    await service.cache(SharedSafetyCalibrationState(revision: 1));
    expect((await service.loadCached())?.revision, 1);
  });

  test('壊れたcacheは削除し、他チームへ波及させない', () async {
    SharedPreferences.setMockInitialValues({
      'shared_safety_calibration_v2_team-a': '{"revision":"broken"}',
      // 同梱プロファイルを更新するたびに書き換えずに済むよう、
      // checksumは設定値から取る(literalを置くと更新漏れで赤くなる)。
      'shared_safety_calibration_v2_team-b':
          '{"baseProfileVersion":$currentHazardProfileDataVersion,'
              '"baseProfileSha256":"$currentHazardProfileSha256",'
              '"calibrations":{},'
              '"dangerZoneOffsets":{'
              '"shore":{"waterSideMeters":5,"landSideMeters":15},'
              '"bridge":{"waterSideMeters":5,"landSideMeters":5},'
              '"island":{"waterSideMeters":5,"landSideMeters":5},'
              '"driftwood":{"waterSideMeters":5,"landSideMeters":5},'
              '"testZone":{"waterSideMeters":5,"landSideMeters":5}},'
              '"primaryWarningLeadSeconds":10,'
              '"advanceWarningLeadSeconds":13,'
              '"revision":2}',
    });

    expect(
      await SharedSafetyCalibrationService(teamId: 'team-a').loadCached(),
      isNull,
    );
    expect(
      (await SharedSafetyCalibrationService(teamId: 'team-b').loadCached())
          ?.revision,
      2,
    );
  });
}
