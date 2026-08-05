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
// 追加の指定:
//
//   --dart-define=SCENARIO=/path/to/scenario.json   他艇を注入する(下記)
//   --dart-define=OUT=/path/to/result.json          機械可読の結果を書き出す
//
// LOG_DIR が無い場合はスキップする(CIでは走らない)。
// 診断パッケージは個人の航跡を含むためリポジトリには入れない。
//
// ## 実機との対応
//
// 再生の忠実度が低いと、総量の比較そのものが意味を失う。次の3点は
// **実機ログから読み取って再現する**。固定値で代用しない。
//
// - `track.csv` の `gnss_quality`。GPS品質は警告の確度・解除証拠・
//   陸上判定のすべてに効く。`true` 固定だと欠測が再現されない。
// - `manifest.json` の `boatType`。船体領域の寸法が変わる。
// - `manifest.json` の `dangerZoneOffsets`。岸の水面側5m/陸側15mなど、
//   端末ごとの実運用設定を再現しない比較は回帰確認にならない。
//
// アプリの1秒ウォッチドッグは、1ティックにつき**1回だけ**安全評価を適用する
// (`use_navigator.dart` の `runGpsWatchdogTick`)。ここでも1行につき1回だけ
// `processAssessment` を呼ぶ。2回呼ぶと、候補のある評価と候補のない評価が
// 同じティックで衝突し、実機には無い alerting⇄clearing の往復が生まれる。
//
// ## シナリオJSON(他艇の注入)
//
// `track.csv` には他艇が入っていないため、桟橋での着艇のような
// 「他艇が近くに停まっている」状況は実ログだけでは再生できない。
//
// ```json
// {
//   "otherBoats": [
//     {
//       "boatId": "other-1",
//       "boatType": "r_4x",
//       "samples": [
//         {"elapsedMs": 7490000, "lat": 36.0833, "lng": 140.2144,
//          "heading": 90, "speed": 0.2},
//         {"elapsedMs": 7990000, "lat": 36.0833, "lng": 140.2144,
//          "heading": 90, "speed": 0.2}
//       ]
//     }
//   ]
// }
// ```
//
// `samples` の間は線形補間し、範囲外の時刻には艇を出さない。
//
// シナリオには桟橋エリアも書ける。座標をプロットする前に、抑制ポリシーを
// 実ログの航跡で確かめるために使う。プロファイル側の `mooringAreas` へ
// **追加**される(置き換えではない)。
//
// ```json
// { "mooringAreas": [ { "points": [ {"lat": .., "lng": ..}, ... ] } ] }
// ```
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
const _scenarioPath = String.fromEnvironment('SCENARIO');
const _outPath = String.fromEnvironment('OUT');
const _defaultScenarioPath = 'test/replay/mooring_scenario.json';

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

    final manifest = _readManifest('$_logDir/manifest.json');
    final boatType = _boatTypeFrom(manifest);
    final settings = _dangerZoneSettingsFrom(manifest);

    final service = PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
      useLocalFixedObstacleCalibrations: false,
    );
    final centerline = await service.loadChannelCenterline();
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

    final ashoreAreas = await service.loadAshoreAreas();
    final mooringAreas = await service.loadMooringAreas();
    final ashoreDetector = AshoreDetector(
      ashoreAreas: ashoreAreas.map((area) => area.points).toList(),
    );
    final scenario = _readScenario(
      _scenarioPath.isEmpty ? _defaultScenarioPath : _scenarioPath,
    );
    final evaluator = CollisionRiskEvaluatorService();
    final orchestrator = SafetyOrchestrator(
      sessionId: 'replay',
      sessionGeneration: 1,
      mooringAreas: [
        ...mooringAreas.map((area) => area.points),
        ...scenario.mooringAreas,
      ],
    );

    final rows = const LineSplitter().convert(trackFile.readAsStringSync());
    final header = rows.first.split(',');
    int col(String name) => header.indexOf(name);
    final iLat = col('filtered_lat');
    final iLng = col('filtered_lng');
    final iSpeed = col('speed_mps');
    final iHeading = col('heading_deg');
    final iAccuracy = col('gnss_accuracy_m');
    final iElapsed = header.indexOf('elapsed_ms');
    final iTimestamp = header.indexOf('timestamp');
    if (iElapsed < 0 && iTimestamp < 0) {
      markTestSkipped(
        'replay skipped: track.csv に elapsed_ms も timestamp もありません',
      );
      return;
    }
    final iQuality = header.indexOf('gnss_quality');

    final origin = DateTime.utc(2026, 1, 1);
    DateTime? legacyOrigin;
    final presentationSamples = <String, int>{};
    final playsByCategory = <String, int>{};
    final cuesByCategory = <String, int>{};
    // 音声エピソードの新規発行。実機の `audio_directive_changed` に相当する。
    final audioEpisodesByCategory = <String, int>{};
    // 同一 alertId の clearing→alerting 往復。フラッピングの指標。
    final reArmByAlertId = <String, int>{};
    final phaseByAlertId = <String, AlertPhase>{};
    final seenEventIds = <String>{};
    final audioStartTimeline = <String>[];
    String? previousDirectiveKey;
    var ashoreSamples = 0;
    var unusableSamples = 0;
    final mutedByAshore = <String, int>{};

    for (final line in rows.skip(1)) {
      if (line.trim().isEmpty) continue;
      final f = line.split(',');
      DateTime? timestamp;
      if (iTimestamp >= 0 && f[iTimestamp].trim().isNotEmpty) {
        timestamp = DateTime.tryParse(f[iTimestamp].trim())?.toUtc();
        if (timestamp == null) {
          markTestSkipped('replay skipped: timestamp を解釈できない行があります');
          return;
        }
      }
      final rowTimestamp = timestamp;
      final elapsedMs = iElapsed >= 0
          ? int.tryParse(f[iElapsed].trim())
          : rowTimestamp == null
              ? null
              : () {
                  final start = legacyOrigin ??= rowTimestamp;
                  return rowTimestamp.difference(start).inMilliseconds;
                }();
      if (elapsedMs == null) {
        markTestSkipped(
          'replay skipped: elapsed_ms のない行に timestamp がありません',
        );
        return;
      }
      final at = timestamp ?? origin.add(Duration(milliseconds: elapsedMs));
      final quality = iQuality >= 0 ? f[iQuality] : 'good';
      // track.csv は「採用された測位」の列なので、`unusable` は
      // 「この測位の時点でGPS品質監視が利用不可と判定していた」を意味する。
      final gpsUsable = quality != 'unusable';
      final dataQuality = switch (quality) {
        'good' => AlertDataQuality.good,
        'degraded' => AlertDataQuality.degraded,
        _ => AlertDataQuality.unusable,
      };
      if (!gpsUsable) unusableSamples++;
      final boat = Boat(
        boatId: 'own',
        boatType: boatType,
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
        gpsQualityUsable: gpsUsable,
      ));
      if (ashore.isAshore) ashoreSamples++;
      final otherBoats = scenario.boatsAt(elapsedMs, at);
      final otherBoatSpeedById = scenario.speedsAt(elapsedMs);
      final assessment = evaluator.assessRisk(
        boat,
        otherBoats,
        obstacles,
        warningTimeSeconds: 10,
        centerline: centerline,
      );
      final result = orchestrator.processAssessment(
        assessment: assessment,
        evaluatedAt: at,
        dataQuality: dataQuality,
        ownSpeedMetersPerSecond: boat.speed,
        ownPosition: LatLng(boat.lat, boat.lng),
        otherBoatSpeedById: otherBoatSpeedById,
        healthyBoatIds: otherBoats.map((other) => other.boatId).toSet(),
        capabilities: CapabilitySnapshot(
          gpsUsable: gpsUsable,
          staticProfileUsable: true,
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
          // どこで鳴ったかが分からないと、総量が減った理由を確かめられない。
          audioStartTimeline.add('${elapsedMs ~/ 1000}s $category');
        }
      } else {
        previousDirectiveKey = null;
      }
      for (final alert in result.state.alerts) {
        final id = alert.candidate.alertId;
        final previous = phaseByAlertId[id];
        if (previous == AlertPhase.clearing &&
            alert.phase == AlertPhase.alerting) {
          reArmByAlertId[id] = (reArmByAlertId[id] ?? 0) + 1;
        }
        phaseByAlertId[id] = alert.phase;
        final eventId = alert.candidate.audioEventId;
        if (eventId != null && seenEventIds.add(eventId)) {
          final category = alert.candidate.category;
          audioEpisodesByCategory[category] =
              (audioEpisodesByCategory[category] ?? 0) + 1;
        }
      }
      // 実機ログの alerts.jsonl と同じ軸で数える。音声チャンネルを
      // 取れたかに関係なく、その候補へ割り当てられた提示の重さを見る。
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
          presentationSamples[key] = (presentationSamples[key] ?? 0) + 1;
        }
      }
      for (final cue in result.snapshot.oneShotAudioCues) {
        cuesByCategory[cue.category] = (cuesByCategory[cue.category] ?? 0) + 1;
      }
    }

    int total(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);
    final summary = <String, dynamic>{
      'logDir': _logDir,
      'boatType': boatType.name,
      'points': rows.length - 1,
      'gpsUnusableSamples': unusableSamples,
      'ashoreSamples': ashoreSamples,
      'otherBoatsInjected': scenario.boatCount,
      'scenarioCases': scenario.cases,
      'mooringAreasInjected': scenario.mooringAreas.length,
      'audioStarts': playsByCategory,
      'audioStartTimeline': audioStartTimeline,
      'audioEpisodes': audioEpisodesByCategory,
      'reArmByAlertId': reArmByAlertId,
      'presentationSamples': presentationSamples,
      'oneShotCues': cuesByCategory,
      'mutedByAshore': mutedByAshore,
    };
    if (_outPath.isNotEmpty) {
      File(_outPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(summary),
      );
    }
    // ignore: avoid_print
    print('''
==== 実機ログ再生結果 (${rows.length - 1} 点 / $boatType) ====
GPS利用不可だった測位: $unusableSamples
他艇の注入: ${scenario.boatCount} 艇
持続音の開始回数 (合計 ${total(playsByCategory)}):
${_format(playsByCategory)}
鳴った時刻:
${_formatList(audioStartTimeline)}
音声エピソードの新規発行 (合計 ${total(audioEpisodesByCategory)}):
${_format(audioEpisodesByCategory)}
clearing→alerting の往復 (合計 ${total(reArmByAlertId)}):
${_format(reArmByAlertId)}
提示の内訳サンプル数 (合計 ${total(presentationSamples)}):
${_format(presentationSamples)}
単発キュー (合計 ${total(cuesByCategory)}):
${_format(cuesByCategory)}
陸上判定だったサンプル: $ashoreSamples / ${rows.length - 1}
陸上判定で無音化した提示 (合計 ${total(mutedByAshore)}):
${_format(mutedByAshore)}
''');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

String _formatList(List<String> lines) {
  if (lines.isEmpty) return '  (なし)';
  return lines.map((line) => '  $line').join('\n');
}

String _format(Map<String, int> counts) {
  if (counts.isEmpty) return '  (なし)';
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return entries.map((e) => '  ${e.key}: ${e.value}').join('\n');
}

Map<String, dynamic> _readManifest(String path) {
  final file = File(path);
  if (!file.existsSync()) return const {};
  try {
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return const {};
  }
}

BoatType _boatTypeFrom(Map<String, dynamic> manifest) {
  final raw = (manifest['session'] as Map<String, dynamic>?)?['boatType'] ??
      (manifest['settings'] as Map<String, dynamic>?)?['boatType'];
  if (raw is! String) return BoatType.r_1x;
  for (final type in BoatType.values) {
    if (type.name == raw) return type;
  }
  return BoatType.r_1x;
}

/// manifest の `dangerZoneOffsets` を再現する。
///
/// `DangerZoneSettings.defaults()` は岸の水面側も15mで実運用と別物なので、
/// manifest が無い場合だけ実機で使っている 5m / 15m へ寄せる。
DangerZoneSettings _dangerZoneSettingsFrom(Map<String, dynamic> manifest) {
  final raw =
      (manifest['settings'] as Map<String, dynamic>?)?['dangerZoneOffsets'];
  var settings = DangerZoneSettings.defaults();
  for (final kind in DangerZoneKind.values) {
    final entry = raw is Map<String, dynamic> ? raw[kind.name] : null;
    final water = entry is Map<String, dynamic>
        ? (entry['waterSideMeters'] as num?)?.toDouble()
        : null;
    final land = entry is Map<String, dynamic>
        ? (entry['landSideMeters'] as num?)?.toDouble()
        : null;
    settings = settings.withOffsets(
      kind,
      DangerZoneOffsets(
        waterSideMeters: water ?? 5,
        landSideMeters: land ?? (kind == DangerZoneKind.shore ? 15 : 5),
      ),
    );
  }
  return settings;
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

_Scenario _readScenario(String path) {
  if (path.isEmpty) return const _Scenario([], []);
  final file = File(path);
  if (!file.existsSync()) return const _Scenario([], []);
  final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final mooringAreas = <List<LatLng>>[];
  for (final item in (raw['mooringAreas'] as List<dynamic>? ?? const [])) {
    final points = <LatLng>[];
    for (final p
        in ((item as Map<String, dynamic>)['points'] as List<dynamic>? ??
            const [])) {
      final point = p as Map<String, dynamic>;
      points.add(LatLng(
        (point['lat'] as num).toDouble(),
        (point['lng'] as num).toDouble(),
      ));
    }
    if (points.length >= 3) mooringAreas.add(points);
  }
  final boats = <_ScenarioBoat>[];
  for (final item in (raw['otherBoats'] as List<dynamic>? ?? const [])) {
    final map = item as Map<String, dynamic>;
    final samples = <_ScenarioSample>[];
    for (final s in (map['samples'] as List<dynamic>? ?? const [])) {
      final sample = s as Map<String, dynamic>;
      samples.add(_ScenarioSample(
        elapsedMs: (sample['elapsedMs'] as num).toInt(),
        lat: (sample['lat'] as num).toDouble(),
        lng: (sample['lng'] as num).toDouble(),
        heading: (sample['heading'] as num?)?.toDouble() ?? 0,
        speed: (sample['speed'] as num?)?.toDouble(),
      ));
    }
    samples.sort((a, b) => a.elapsedMs.compareTo(b.elapsedMs));
    if (samples.isEmpty) continue;
    boats.add(_ScenarioBoat(
      boatId: map['boatId'] as String? ?? 'other',
      caseName: map['case'] as String?,
      boatType: BoatType.values.firstWhere(
        (type) => type.name == map['boatType'],
        orElse: () => BoatType.r_1x,
      ),
      samples: samples,
    ));
  }
  return _Scenario(boats, mooringAreas);
}

class _Scenario {
  final List<_ScenarioBoat> boats;
  final List<List<LatLng>> mooringAreas;

  const _Scenario(this.boats, this.mooringAreas);

  int get boatCount => boats.length;

  List<String> get cases => boats
      .map((boat) => boat.caseName)
      .whereType<String>()
      .toList(growable: false);

  List<Boat> boatsAt(int elapsedMs, DateTime at) {
    if (boats.isEmpty) return const [];
    final result = <Boat>[];
    for (final boat in boats) {
      final sample = boat.sampleAt(elapsedMs);
      if (sample == null) continue;
      result.add(Boat(
        boatId: boat.boatId,
        boatType: boat.boatType,
        lat: sample.lat,
        lng: sample.lng,
        heading: sample.heading,
        // Boatの安全評価モデルは速度を必須とするため、速度不明は幾何計算
        // では0へ縮退する。ただし提示判定へは下記speedsAtでnullを渡す。
        speed: sample.speed ?? 0,
        timestamp: at,
        serverUpdatedAt: at,
      ));
    }
    return result;
  }

  Map<String, double?> speedsAt(int elapsedMs) {
    final result = <String, double?>{};
    for (final boat in boats) {
      final sample = boat.sampleAt(elapsedMs);
      if (sample != null) result[boat.boatId] = sample.speed;
    }
    return result;
  }
}

class _ScenarioBoat {
  final String boatId;
  final String? caseName;
  final BoatType boatType;
  final List<_ScenarioSample> samples;

  const _ScenarioBoat({
    required this.boatId,
    required this.caseName,
    required this.boatType,
    required this.samples,
  });

  /// 指定時刻の位置を線形補間で返す。範囲外では艇を出さない。
  _ScenarioSample? sampleAt(int elapsedMs) {
    if (elapsedMs < samples.first.elapsedMs) return null;
    if (elapsedMs > samples.last.elapsedMs) return null;
    for (var i = 0; i < samples.length - 1; i++) {
      final a = samples[i];
      final b = samples[i + 1];
      if (elapsedMs < a.elapsedMs || elapsedMs > b.elapsedMs) continue;
      final span = b.elapsedMs - a.elapsedMs;
      final t = span == 0 ? 0.0 : (elapsedMs - a.elapsedMs) / span;
      final speed = a.speed != null && b.speed != null
          ? a.speed! + (b.speed! - a.speed!) * t
          : null;
      return _ScenarioSample(
        elapsedMs: elapsedMs,
        lat: a.lat + (b.lat - a.lat) * t,
        lng: a.lng + (b.lng - a.lng) * t,
        heading: a.heading + (b.heading - a.heading) * t,
        speed: speed,
      );
    }
    return samples.last;
  }
}

class _ScenarioSample {
  final int elapsedMs;
  final double lat;
  final double lng;
  final double heading;
  final double? speed;

  const _ScenarioSample({
    required this.elapsedMs,
    required this.lat,
    required this.lng,
    required this.heading,
    required this.speed,
  });
}
