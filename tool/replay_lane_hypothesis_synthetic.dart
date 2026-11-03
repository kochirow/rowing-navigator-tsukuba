// R9（実験）の合成シナリオ。実機ログの自艇の航跡に、合成した相手艇を走らせる。
//
//   flutter test tool/replay_lane_hypothesis_synthetic.dart \
//     --dart-define=LOGS=/path/A;/path/B \
//     --dart-define=OUT=/path/to/result.json
//
// 自艇がレーンを正しい向きに 2m/s 以上で漕いでいる時刻を起点に、相手艇を
// 中心線沿いに160m先から3.5m/sで向かわせる。
//
// - headOn : 自艇と同じ横位置（同じレーンを逆向き＝相手が逆走）。当たる
// - passing: 中心線をはさんだ反対側（正しいレーンどうしのすれ違い）。当たらない
//
// 相手が送ってくる値を3通りに壊す。
//
// - C0: 正常（方位・速度とも正しい）
// - C1: 方位が90度ずれて止まり、速度は実際の1/4（2026-10-28 に iOS で起きた型）
// - C2: 方位が90度ずれて止まり、速度は0.4m/s（「遅い艇」として扱われる）
//
// 方式 V0〜V3 と「鳴る秒」の決め方は replay_lane_hypothesis.dart と同じ。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/channel_lane.dart';
import 'package:rowing_navigator/services/channel_lane_resolver.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/conservative_position_estimator.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';

const _logs = String.fromEnvironment('LOGS');
const _out = String.fromEnvironment('OUT');

/// 受信した相手の位置に足す測位誤差の標準偏差 [m]（東西・南北それぞれ）。
const _noiseText = String.fromEnvironment('NOISE', defaultValue: '0');
final _noise = double.tryParse(_noiseText) ?? 0;

const _oppSpeed = 3.5;
const _startGap = 160.0;
const _reliableSpeed = 0.5;

class _Fix {
  final DateTime t;
  final double lat, lng;
  final double? acc;
  double speed = 0, heading = 0;
  _Fix(this.t, this.lat, this.lng, this.acc);
}

double? _num(List<String> f, int i) =>
    i >= 0 && i < f.length ? double.tryParse(f[i]) : null;

({BoatType type, List<_Fix> fixes}) _load(String dir) {
  final manifest =
      jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map;
  final rawType = (manifest['session'] as Map?)?['boatType'];
  final type = BoatType.values
      .firstWhere((t) => t.name == rawType, orElse: () => BoatType.r_1x);
  final lines = const LineSplitter()
      .convert(File('$dir/track.csv').readAsStringSync())
      .where((l) => l.trim().isNotEmpty)
      .toList();
  final h = lines.first.split(',');
  int c(String n) => h.indexOf(n);
  final est = ConservativePositionEstimator();
  final fixes = <_Fix>[];
  DateTime? start;
  var held = 0.0;
  for (final l in lines.skip(1)) {
    final f = l.split(',');
    final t = DateTime.tryParse(f[c('timestamp')])?.toUtc();
    final lat = _num(f, c('raw_lat')), lng = _num(f, c('raw_lng'));
    if (t == null || lat == null || lng == null) continue;
    start ??= t;
    final x = _Fix(t, lat, lng, _num(f, c('gnss_accuracy_m')));
    final out = est
        .update(
          fix: ConservativeFix(
            position: LatLng(lat, lng),
            timestamp: t,
            elapsed: t.difference(start),
            accuracyMeters: x.acc ?? 5,
            speedMetersPerSecond: _num(f, c('raw_gnss_speed_mps')),
            headingDegrees:
                _num(f, c('raw_course_deg')) ?? _num(f, c('heading_deg')),
            speedAccuracyMetersPerSecond: _num(f, c('speed_accuracy_mps')),
            headingAccuracyDegrees: _num(f, c('heading_accuracy_deg')),
          ),
        )
        .output;
    x.speed = out?.speedMetersPerSecond ?? (_num(f, c('speed_mps')) ?? 0);
    if (out != null && x.speed >= stoppedSpeedThreshold) {
      held = out.headingDegrees;
    }
    x.heading = held;
    fixes.add(x);
  }
  return (type: type, fixes: fixes);
}

double _distM(LatLng a, LatLng b) {
  final dy = (b.latitude - a.latitude) * 110574.0;
  final dx = (b.longitude - a.longitude) *
      111320.0 *
      math.cos(a.latitude * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

double _bearing(LatLng a, LatLng b) {
  final dy = (b.latitude - a.latitude) * 110574.0;
  final dx = (b.longitude - a.longitude) *
      111320.0 *
      math.cos(a.latitude * math.pi / 180);
  return (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
}

double _angleDiff(double a, double b) {
  final d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

double? _median(List<double> v) {
  if (v.isEmpty) return null;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('合成シナリオでレーン仮説の効果と誤報を数える', () async {
    if (_logs.isEmpty) {
      markTestSkipped('LOGS が未指定のためスキップ');
      return;
    }
    final service = PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
      useLocalFixedObstacleCalibrations: false,
    );
    final fallback = await service.loadChannelCenterline();
    final resolver = ChannelLaneResolver(
      await service.loadChannelLanes(),
      centerlines: await service.loadChannelCenterlines(),
    );
    final evaluator = CollisionRiskEvaluatorService();

    // key: scenario/corruption/variant -> 結果の配列
    final leads = <String, List<double>>{};
    final alerted = <String, int>{};
    final total = <String, int>{};
    final audibleSec = <String, int>{};

    for (final dir in _logs.split(';').where((s) => s.trim().isNotEmpty)) {
      final log = _load(dir.trim());
      final fixes = log.fixes;
      var nextStart = fixes.first.t;
      for (var i = 0; i < fixes.length; i++) {
        final f0 = fixes[i];
        if (f0.t.isBefore(nextStart) || f0.speed < 2.0) continue;
        final p0 = LatLng(f0.lat, f0.lng);
        final lane = resolver.resolveLane(p0);
        final cl = resolver.centerlineFor(p0) ?? fallback;
        if (lane == null || cl == null) continue;
        final fr0 = cl.project(p0);
        if (!fr0.isInsideCoverage || fr0.crossMeters.abs() < 5) continue;
        final laneDir = lane.direction == LaneDirection.along
            ? fr0.tangentBearingDegrees
            : (fr0.tangentBearingDegrees + 180) % 360;
        if (_angleDiff(laneDir, f0.heading) > 45) continue;
        final s = lane.direction == LaneDirection.along ? 1.0 : -1.0;
        if (fr0.alongMeters + s * (_startGap + 10) < 0 ||
            fr0.alongMeters + s * (_startGap + 10) > cl.lengthMeters) {
          continue;
        }
        nextStart = f0.t.add(const Duration(seconds: 60));

        for (final scenario in ['headOn', 'passing']) {
          final cross =
              scenario == 'headOn' ? fr0.crossMeters : -fr0.crossMeters;
          LatLng oppAt(double tau) => cl.toLatLng(
                alongMeters:
                    fr0.alongMeters + s * (_startGap - _oppSpeed * tau),
                crossMeters: cross,
              );
          double oppTrueHeading(double tau) {
            final along = fr0.alongMeters + s * (_startGap - _oppSpeed * tau);
            final tangent = cl.tangentBearingAt(along);
            return s > 0 ? (tangent + 180) % 360 : tangent;
          }

          // 受信した位置には測位誤差を足す（正解の距離には足さない）。
          // 同じ遭遇では方式・壊し方をまたいで同じ誤差を使う。
          final rng = math.Random(i * 7 + (scenario == 'headOn' ? 1 : 2));
          double gauss() {
            final u1 = math.max(1e-12, rng.nextDouble()), u2 = rng.nextDouble();
            return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
          }

          final noiseEN = [
            for (var k = 0; k <= 70; k++) (gauss() * _noise, gauss() * _noise)
          ];
          LatLng recvAt(double tau) {
            final p = oppAt(tau);
            final n = noiseEN[tau.round().clamp(0, 70)];
            return LatLng(
              p.latitude + n.$2 / 110574.0,
              p.longitude +
                  n.$1 / (111320.0 * math.cos(p.latitude * math.pi / 180)),
            );
          }

          // 実際の距離（正解）と最接近の時刻。
          final ownAt = <int, _Fix>{};
          var minDist = double.infinity;
          var tMin = 0;
          for (var tau = 0; tau <= 60; tau++) {
            final j = i + tau;
            if (j >= fixes.length) break;
            final fx = fixes[j];
            if (fx.t.difference(f0.t).inSeconds > tau + 2) break;
            ownAt[tau] = fx;
            final d = _distM(LatLng(fx.lat, fx.lng), oppAt(tau.toDouble()));
            if (d < minDist) {
              minDist = d;
              tMin = tau;
            }
          }
          if (ownAt.length < 30) continue;
          // 正解で絞る。自艇は実際の航跡なので、途中で曲がる・止まると
          // 合成の相手と当たらない（または近すぎる）場面が混ざる。
          if (scenario == 'headOn' ? minDist >= 6 : minDist < 10) continue;

          for (final corruption in ['C0', 'C1', 'C2']) {
            final firstAudible = <String, int?>{
              for (final v in ['V0', 'V1', 'V2', 'V3', 'V4']) v: null
            };
            for (final entry in ownAt.entries) {
              final tau = entry.key.toDouble();
              if (tau > tMin + 3) break;
              final o = entry.value;
              final now = DateTime.now();
              final own = Boat(
                boatId: 'own',
                boatType: log.type,
                lat: o.lat,
                lng: o.lng,
                heading: o.heading,
                speed: o.speed,
                timestamp: now,
                accuracy: o.acc,
              );
              final pos = recvAt(tau);
              final trueHeading = oppTrueHeading(tau);
              final (repHeading, repSpeed) = switch (corruption) {
                'C0' => (trueHeading, _oppSpeed),
                'C1' => ((trueHeading + 90) % 360, _oppSpeed * 0.25),
                _ => ((trueHeading + 90) % 360, 0.4),
              };
              Boat boat(String id, double heading, double speed) => Boat(
                    boatId: id,
                    boatType: BoatType.r_4x,
                    lat: pos.latitude,
                    lng: pos.longitude,
                    heading: heading,
                    speed: speed,
                    timestamp: now,
                    accuracy: 4,
                  );
              final other = boat('other', repHeading, repSpeed);
              final past = recvAt(math.max(0, tau - 6));
              final dtPast = math.min(6.0, tau);
              final derivedSpeed =
                  dtPast >= 3 ? _distM(past, pos) / dtPast : null;
              final derivedCourse = dtPast >= 3 ? _bearing(past, pos) : null;
              final laneHere = resolver.resolveLane(pos);
              final clHere = resolver.centerlineFor(pos) ?? fallback;
              double? laneDirHere;
              if (laneHere != null && clHere != null) {
                final t = clHere.project(pos).tangentBearingDegrees;
                laneDirHere = laneHere.direction == LaneDirection.along
                    ? t
                    : (t + 180) % 360;
              }
              final slow = repSpeed < _reliableSpeed;
              final usable =
                  derivedSpeed != null && derivedSpeed >= _reliableSpeed;
              final inconsistent = derivedCourse != null &&
                  (slow ||
                      _angleDiff(repHeading, derivedCourse) > 60 ||
                      derivedSpeed! > 2 * repSpeed + 0.5);
              final variants = <String, List<Boat>>{
                'V0': [other],
                'V1': [
                  other,
                  if (slow && laneDirHere != null && usable)
                    boat('other#h', laneDirHere, derivedSpeed),
                ],
                'V2': [
                  other,
                  if (inconsistent && laneDirHere != null && usable)
                    boat('other#h', laneDirHere, derivedSpeed),
                ],
                'V3': [
                  other,
                  if (inconsistent && usable)
                    boat('other#h', derivedCourse, derivedSpeed),
                ],
                // 足すのではなく、食い違う値を届いた位置の動きで置き換える。
                'V4': [
                  if (inconsistent && usable)
                    boat('other', derivedCourse, derivedSpeed)
                  else
                    other,
                ],
              };
              for (final v in variants.entries) {
                final a = evaluator.assessRisk(own, v.value, const [],
                    warningTimeSeconds: advanceWarningLeadSeconds,
                    centerline: fallback,
                    laneResolver: resolver);
                var ring = false;
                for (final rt in a.threats) {
                  final th = rt.threat;
                  final ci = th.continuousIntersection;
                  if (th.kind != ThreatKind.boat ||
                      ci == null ||
                      !ci.intersects) {
                    continue;
                  }
                  final tte =
                      ci.currentOverlap ? 0.0 : (ci.firstEntryTimeSeconds ?? 0);
                  final low = th.boatId == 'other#h' ||
                      ci.reasonCodes.contains('heading_uncertainty_entry');
                  if (tte <= (low ? 10.0 : advanceWarningLeadSeconds)) {
                    ring = true;
                  }
                }
                if (ring) {
                  firstAudible[v.key] ??= entry.key;
                  final k = '$scenario/$corruption/${v.key}';
                  audibleSec[k] = (audibleSec[k] ?? 0) + 1;
                }
              }
            }
            for (final v in firstAudible.keys) {
              final k = '$scenario/$corruption/$v';
              total[k] = (total[k] ?? 0) + 1;
              final fa = firstAudible[v];
              if (fa != null) {
                alerted[k] = (alerted[k] ?? 0) + 1;
                (leads[k] ??= []).add((tMin - fa).toDouble());
              }
            }
          }
        }
      }
    }

    final rows = <Map<String, dynamic>>[];
    for (final k in total.keys.toList()..sort()) {
      final l = leads[k] ?? const <double>[];
      final row = {
        'case': k,
        'encounters': total[k],
        'alerted': alerted[k] ?? 0,
        'leadMedianSec': _median(l),
        'leadAtLeast10s': l.where((x) => x >= 10).length,
        'audibleSeconds': audibleSec[k] ?? 0,
      };
      rows.add(row);
      // ignore: avoid_print
      print(jsonEncode(row));
    }
    if (_out.isNotEmpty) {
      File(_out)
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(rows));
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
