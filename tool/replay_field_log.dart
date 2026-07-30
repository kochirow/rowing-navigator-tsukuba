// 実機ログの航跡を警告パイプラインへ再生し、警告音が何回鳴るかを数える検証用ツール。
//
// 単体テストは「この条件で鳴る/鳴らない」を固定するが、
// **1回の練習で実際に何回鳴るか**は測れない。過剰警告は総量の問題なので、
// 実機ログを丸ごと通して総量を確認する経路を残しておく。
//
// 使い方(診断パッケージのフォルダを渡す):
//
//   flutter test tool/replay_field_log.dart \
//     --dart-define=LOG_DIR=/path/to/rowing_diagnostics_20260726
//
// LOG_DIR が無い場合はスキップする(CIでは走らない)。
// 診断パッケージは個人の航跡を含むためリポジトリには入れない。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/danger_zone_settings.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/ashore_detector.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/legacy_danger_zone_generator.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/services/safety_orchestrator.dart';
import 'package:rowing_navigator/types/boat_type.dart';

const _logDir = String.fromEnvironment('LOG_DIR');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('実機ログの航跡を再生して警告音の総量を数える', () async {
    if (_logDir.isEmpty) {
      markTestSkipped('LOG_DIR が未指定のためスキップ');
      return;
    }
    final trackFile = File('$_logDir/track.csv');
    if (!trackFile.existsSync()) {
      markTestSkipped('track.csv が見つからない: ${trackFile.path}');
      return;
    }

    final service = PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
      useLocalFixedObstacleCalibrations: false,
    );
    final centerline = await service.loadChannelCenterline();

    // 実機の運用設定(manifest確認済み)を再現する。
    // DangerZoneSettings.defaults() は岸の水面側も15mで別物。
    var settings = DangerZoneSettings.defaults();
    for (final kind in DangerZoneKind.values) {
      settings = settings.withOffsets(
        kind,
        DangerZoneOffsets(
          waterSideMeters: 5,
          landSideMeters: kind == DangerZoneKind.shore ? 15 : 5,
        ),
      );
    }
    final targets = await service.loadCalibrationTargets();
    final obstacles = <StaticObstacle>[
      ...LegacyDangerZoneGenerator().generate(
        baselines: targets
            .map((target) => DangerZoneBaseline(
                  id: target.sourceId,
                  name: target.name,
                  kind: switch (target.kind) {
                    StaticObstacleKind.shore => DangerZoneKind.shore,
                    StaticObstacleKind.bridge => DangerZoneKind.bridge,
                    StaticObstacleKind.island => DangerZoneKind.island,
                    StaticObstacleKind.driftwood => DangerZoneKind.driftwood,
                    _ => DangerZoneKind.testZone,
                  },
                  points: target.sourcePoints,
                ))
            .where((baseline) => baseline.kind != DangerZoneKind.testZone)
            .toList(growable: false),
        settings: settings,
      ),
      // カーブ・逆走は完成ポリゴンなので基準線展開の対象外。
      ...await _guidanceZones(),
    ];

    final ashoreDetector = AshoreDetector(
      shoreBaselines: await service.loadShoreBaselines(),
    );
    final evaluator = CollisionRiskEvaluatorService();
    final orchestrator = SafetyOrchestrator(
      sessionId: 'replay',
      sessionGeneration: 1,
    );

    final rows = const LineSplitter().convert(trackFile.readAsStringSync());
    final header = rows.first.split(',');
    int col(String name) => header.indexOf(name);
    final iLat = col('filtered_lat');
    final iLng = col('filtered_lng');
    final iSpeed = col('speed_mps');
    final iHeading = col('heading_deg');
    final iAccuracy = col('gnss_accuracy_m');
    final iElapsed = col('elapsed_ms');

    final origin = DateTime.utc(2026, 1, 1);
    final loopSecondsByCategory = <String, int>{};
    final playsByCategory = <String, int>{};
    final cuesByCategory = <String, int>{};
    String? previousDirectiveKey;
    var ashoreSamples = 0;
    final mutedByAshore = <String, int>{};

    for (final line in rows.skip(1)) {
      if (line.trim().isEmpty) continue;
      final f = line.split(',');
      final elapsedMs = int.parse(f[iElapsed]);
      final at = origin.add(Duration(milliseconds: elapsedMs));
      final boat = Boat(
        boatId: 'own',
        boatType: BoatType.r_1x,
        lat: double.parse(f[iLat]),
        lng: double.parse(f[iLng]),
        heading: double.parse(f[iHeading]),
        speed: double.parse(f[iSpeed]),
        timestamp: at,
        accuracy: double.tryParse(f[iAccuracy]),
      );
      final ashore = ashoreDetector.update(AshoreObservation(
        position: LatLng(boat.lat, boat.lng),
        at: at,
        accuracyMeters: boat.accuracy,
        gpsQualityUsable: true,
      ));
      if (ashore.isAshore) ashoreSamples++;
      final assessment = evaluator.assessRisk(
        boat,
        const [],
        obstacles,
        warningTimeSeconds: 10,
        centerline: centerline,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment,
        evaluatedAt: at,
        ownSpeedMetersPerSecond: boat.speed,
        capabilities: const CapabilitySnapshot(
          gpsUsable: true,
          staticProfileUsable: true,
          insideSupportedCoverage: true,
          audioUsable: true,
        ),
      );
      final directive = result.snapshot.audioDirective;
      final categoryById = {
        for (final alert in result.snapshot.activeAlerts)
          alert.candidate.alertId: alert.candidate.category,
      };
      if (directive != null) {
        final category = categoryById[directive.alertId] ?? '?';
        final key = '${directive.alertId}:${directive.mode.name}:'
            '${directive.eventId}';
        if (key != previousDirectiveKey) {
          previousDirectiveKey = key;
          playsByCategory[category] = (playsByCategory[category] ?? 0) + 1;
        }
      } else {
        previousDirectiveKey = null;
      }
      // 実機ログの alerts.jsonl と同じ軸で数える。音声チャンネルを
      // 取れたかに関係なく、その候補へ割り当てられた提示の重さを見る。
      // 実機ログでは shore の PRESENTATION_EMERGENCY が488サンプルだった。
      for (final alert in result.snapshot.activeAlerts) {
        final candidate = alert.candidate;
        for (final code in candidate.reasonCodes) {
          if (!code.startsWith('PRESENTATION_')) continue;
          final key = '${candidate.category}/$code';
          if (ashore.isAshore) {
            // 陸上判定中は持続音を止める。表示・記録は続いている。
            mutedByAshore[key] = (mutedByAshore[key] ?? 0) + 1;
            continue;
          }
          loopSecondsByCategory[key] = (loopSecondsByCategory[key] ?? 0) + 1;
        }
      }
      for (final cue in result.snapshot.oneShotAudioCues) {
        cuesByCategory[cue.category] = (cuesByCategory[cue.category] ?? 0) + 1;
      }
    }

    int total(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);
    // ignore: avoid_print
    print('''
==== 実機ログ再生結果 (${rows.length - 1} 点) ====
持続音の開始回数 (合計 ${total(playsByCategory)}):
${_format(playsByCategory)}
提示の内訳サンプル数 (合計 ${total(loopSecondsByCategory)}):
${_format(loopSecondsByCategory)}
単発キュー (合計 ${total(cuesByCategory)}):
${_format(cuesByCategory)}
陸上判定だったサンプル: $ashoreSamples / ${rows.length - 1}
陸上判定で無音化した提示 (合計 ${total(mutedByAshore)}):
${_format(mutedByAshore)}
''');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

String _format(Map<String, int> counts) {
  if (counts.isEmpty) return '  (なし)';
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.map((e) => '  ${e.key}: ${e.value}').join('\n');
}

Future<List<StaticObstacle>> _guidanceZones() async {
  final raw = jsonDecode(
    File('assets/data/sakuragawa_obstacles.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final zones = <StaticObstacle>[];
  for (final item in raw['obstacles'] as List<dynamic>) {
    final map = item as Map<String, dynamic>;
    final kind = StaticObstacleKind.fromJson(map['kind'] as String?);
    if (!kind.isEntryGuidance) continue;
    zones.add(StaticObstacle(
      id: map['id'] as String,
      sourceId: map['id'] as String,
      name: map['name'] as String?,
      points: (map['points'] as List<dynamic>)
          .map<LatLng>((p) => LatLng(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ))
          .toList(),
      isDefault: true,
      kind: kind,
    ));
  }
  return zones;
}
