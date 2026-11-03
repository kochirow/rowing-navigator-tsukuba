// R9（実験）：方位が信頼できない他艇に「レーンの向きに進む」仮説を足したら、
// 他艇の警告の鳴り方がどう変わるかを、同じ時刻の実機ログ2本で数える。
//
// 使い方（組は `;`、組の中の2本は `,` で区切る）:
//
//   flutter test tool/replay_lane_hypothesis.dart \
//     --dart-define=PAIRS=/path/A,/path/B;/path/C,/path/D \
//     --dart-define=OUT=/path/to/result.json
//
// 各組を両方向（A を自艇・B を他艇、その逆）で再生する。
//
// ## 比べる方式
//
// - V0: 今のアプリ（観測した方位・速度だけ）
// - V1: 相手の速さが方位を信頼できる閾値（0.5m/s）未満のときだけ、
//       レーンの向き × 届いた位置から求めた速さの仮説を足す
// - V2: 相手が送ってきた方位・速度と、届いた位置の動き（6秒）が食い違うときに、
//       レーンの仮説を足す
// - V3: V2 と同じ条件で、レーンを使わず「届いた位置の動きの向き」の仮説を足す（対照）
//
// 仮説だけで当たる候補は、確度の低い当たり方として鳴り始めを10秒にする。
//
// ## 相手の状態の出どころ
//
// - logged: track.csv の `speed_mps` / `heading_deg`（当時のアプリが採用し、共有した値）
// - reest : 生の測位から今の推定器で求め直した値（今のアプリが共有する値）
//
// ## 簡略化（結果を読むときの注意）
//
// - 提示の状態機械（確定・解除の待ち）は通さず、鳴り始めの規則（確実13秒・
//   確度が低い10秒）と桟橋の静音（両者0.4m/s未満）だけで「鳴る秒」を決める。
// - 受信は毎秒・遅れなしとして扱う（実際は2〜10秒ごと＋外挿）。
// - 固定の危険区域は入れない。他艇の警告だけを数える。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/navigator_config.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/channel_lane.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/channel_lane_resolver.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/conservative_position_estimator.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/utils/winding_algorithm.dart';

const _pairs = String.fromEnvironment('PAIRS');
const _out = String.fromEnvironment('OUT');

/// 方位を信頼できる最低速度（`shipDomainReliableHeadingSpeedMetersPerSecond`）。
const _reliableSpeed = 0.5;

/// 桟橋の静音で「停止」とみなす速度（`stableStopSpeedMetersPerSecond`）。
const _mooringRestSpeed = 0.4;

/// 届いた位置の動きを求める窓 [秒] と、向きを信じる最小移動量 [m]。
const _derivedWindowSec = 6;
const _derivedMinDisplacement = 5.0;

/// 送られてきた方位と位置の動きが「食い違う」とみなす角度 [度]。
const _inconsistentHeadingDeg = 60.0;

/// 実際に近かった、とみなす中心間距離 [m]（艇長と船体領域の目安）。
const _closeMeters = 12.0;

class _Fix {
  final DateTime t;
  final double lat;
  final double lng;
  final double? acc;
  final double? rawSpeed;
  final double? speedAcc;
  final double? rawCourse;
  final double? headingAcc;
  final double loggedSpeed;
  final double loggedHeading;
  double estSpeed = 0;
  double estHeading = 0;
  _Fix(this.t, this.lat, this.lng, this.acc, this.rawSpeed, this.speedAcc,
      this.rawCourse, this.headingAcc, this.loggedSpeed, this.loggedHeading);
}

class _Track {
  final String id;
  final BoatType type;
  final List<_Fix> fixes;
  late final List<int> ms =
      fixes.map((f) => f.t.millisecondsSinceEpoch).toList();
  _Track(this.id, this.type, this.fixes);

  _Fix? at(int t, {int toleranceMs = 1500}) {
    var lo = 0, hi = ms.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ms[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _Fix? best;
    var bestD = toleranceMs + 1;
    for (final i in [lo - 1, lo]) {
      if (i < 0 || i >= ms.length) continue;
      final d = (ms[i] - t).abs();
      if (d < bestD) {
        bestD = d;
        best = fixes[i];
      }
    }
    return best;
  }
}

double? _num(List<String> f, int i) =>
    i >= 0 && i < f.length ? double.tryParse(f[i]) : null;

_Track _load(String dir) {
  final manifest =
      jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map;
  final rawType = (manifest['session'] as Map?)?['boatType'] ??
      (manifest['settings'] as Map?)?['boatType'];
  final type = BoatType.values
      .firstWhere((t) => t.name == rawType, orElse: () => BoatType.r_1x);
  final lines = const LineSplitter()
      .convert(File('$dir/track.csv').readAsStringSync())
      .where((l) => l.trim().isNotEmpty)
      .toList();
  final h = lines.first.split(',');
  int c(String n) => h.indexOf(n);
  final iT = c('timestamp'), iLat = c('raw_lat'), iLng = c('raw_lng');
  final fixes = <_Fix>[];
  for (final l in lines.skip(1)) {
    final f = l.split(',');
    final t = DateTime.tryParse(f[iT])?.toUtc();
    final lat = _num(f, iLat), lng = _num(f, iLng);
    if (t == null || lat == null || lng == null) continue;
    fixes.add(_Fix(
      t,
      lat,
      lng,
      _num(f, c('gnss_accuracy_m')),
      _num(f, c('raw_gnss_speed_mps')),
      _num(f, c('speed_accuracy_mps')),
      _num(f, c('raw_course_deg')),
      _num(f, c('heading_accuracy_deg')),
      _num(f, c('speed_mps')) ?? 0,
      _num(f, c('heading_deg')) ?? 0,
    ));
  }
  // 今のアプリの推定器で速度・方位を求め直す（replay_field_log の REESTIMATE と同じ）。
  final est = ConservativePositionEstimator();
  final start = fixes.first.t;
  var held = fixes.first.loggedHeading;
  for (final x in fixes) {
    final out = est
        .update(
          fix: ConservativeFix(
            position: LatLng(x.lat, x.lng),
            timestamp: x.t,
            elapsed: x.t.difference(start),
            accuracyMeters: x.acc ?? 5,
            speedMetersPerSecond: x.rawSpeed,
            headingDegrees: x.rawCourse ?? x.loggedHeading,
            speedAccuracyMetersPerSecond: x.speedAcc,
            headingAccuracyDegrees: x.headingAcc,
          ),
        )
        .output;
    if (out != null) {
      x.estSpeed = out.speedMetersPerSecond;
      if (x.estSpeed >= stoppedSpeedThreshold) held = out.headingDegrees;
    } else {
      x.estSpeed = x.loggedSpeed;
    }
    x.estHeading = held;
  }
  return _Track(dir.split('/').last, type, fixes);
}

double _distM(double lat1, double lng1, double lat2, double lng2) {
  final dy = (lat2 - lat1) * 110574.0;
  final dx = (lng2 - lng1) * 111320.0 * math.cos(lat1 * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

double _bearing(double lat1, double lng1, double lat2, double lng2) {
  final dy = (lat2 - lat1) * 110574.0;
  final dx = (lng2 - lng1) * 111320.0 * math.cos(lat1 * math.pi / 180);
  return (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
}

double _angleDiff(double a, double b) {
  final d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

/// 届いた位置から求めた動き（相手の端末が送った位置だけを使う）。
({double speed, double course})? _derived(_Track tr, int t) {
  final now = tr.at(t);
  final past = tr.at(t - _derivedWindowSec * 1000);
  if (now == null || past == null) return null;
  final dt = now.t.difference(past.t).inMilliseconds / 1000;
  if (dt < 3) return null;
  final d = _distM(past.lat, past.lng, now.lat, now.lng);
  if (d < _derivedMinDisplacement) return null;
  return (
    speed: d / dt,
    course: _bearing(past.lat, past.lng, now.lat, now.lng)
  );
}

/// 実際の進み方（前後3秒の生の位置）。正解の判定にだけ使う。
double? _trueCourse(_Track tr, int t) {
  final a = tr.at(t - 3000), b = tr.at(t + 3000);
  if (a == null || b == null) return null;
  if (_distM(a.lat, a.lng, b.lat, b.lng) < 4) return null;
  return _bearing(a.lat, a.lng, b.lat, b.lng);
}

double? _laneDirection(ChannelLaneResolver r, ChannelCenterline? fallback,
    double lat, double lng) {
  final p = LatLng(lat, lng);
  final lane = r.resolveLane(p);
  if (lane == null) return null;
  final cl = r.centerlineFor(p) ?? fallback;
  if (cl == null) return null;
  final frame = cl.project(p);
  final tangent = frame.tangentBearingDegrees;
  return lane.direction == LaneDirection.along
      ? tangent
      : (tangent + 180) % 360;
}

/// 'correct' / 'wrong' / 'cross' / 'none'（レーン外・動いていない）。
String _laneUse(
    ChannelLaneResolver r, ChannelCenterline? fb, _Track tr, int t) {
  final f = tr.at(t);
  if (f == null) return 'none';
  final dir = _laneDirection(r, fb, f.lat, f.lng);
  final course = _trueCourse(tr, t);
  if (dir == null || course == null) return 'none';
  final d = _angleDiff(dir, course);
  if (d <= 60) return 'correct';
  if (d >= 120) return 'wrong';
  return 'cross';
}

class _Episode {
  final int start;
  int end;
  _Episode(this.start, this.end);
  int get seconds => ((end - start) ~/ 1000) + 1;
}

List<_Episode> _episodes(List<int> audibleMs) {
  final out = <_Episode>[];
  for (final t in audibleMs) {
    if (out.isNotEmpty && t - out.last.end <= 3000) {
      out.last.end = t;
    } else {
      out.add(_Episode(t, t));
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('レーン仮説の効果を実機ログの組で数える', () async {
    if (_pairs.isEmpty) {
      markTestSkipped('PAIRS が未指定のためスキップ');
      return;
    }
    final service = PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
      useLocalFixedObstacleCalibrations: false,
    );
    final fallbackCenterline = await service.loadChannelCenterline();
    final resolver = ChannelLaneResolver(
      await service.loadChannelLanes(),
      centerlines: await service.loadChannelCenterlines(),
    );
    final mooring =
        (await service.loadMooringAreas()).map((a) => a.points).toList();
    bool inMooring(double lat, double lng) =>
        mooring.any((poly) => isPointInPolygon(LatLng(lat, lng), poly));
    final evaluator = CollisionRiskEvaluatorService();

    final results = <Map<String, dynamic>>[];
    final pairSpecs = _pairs.split(';').where((s) => s.trim().isNotEmpty);
    for (final spec in pairSpecs) {
      final dirs = spec.split(',');
      final a = _load(dirs[0].trim()), b = _load(dirs[1].trim());
      for (final (own, other) in [(a, b), (b, a)]) {
        for (final source in ['logged', 'reest']) {
          final audible = {
            for (final v in ['V0', 'V1', 'V2', 'V3']) v: <int>[]
          };
          final hypothesisTicks = {
            for (final v in ['V1', 'V2', 'V3']) v: 0
          };
          // 実際に近づいた区間（中心間 _closeMeters 未満）を正解として数える。
          final closeMs = <int>[];
          final lo = math.max(own.ms.first, other.ms.first);
          final hi = math.min(own.ms.last, other.ms.last);
          for (var t = lo; t <= hi; t += 1000) {
            final o = own.at(t), x = other.at(t);
            if (o == null || x == null) continue;
            final dist = _distM(o.lat, o.lng, x.lat, x.lng);
            if (dist < _closeMeters) closeMs.add(t);
            if (dist > 400) continue; // 予測の届く範囲の外
            final now = DateTime.now();
            final ownBoat = Boat(
              boatId: 'own',
              boatType: own.type,
              lat: o.lat,
              lng: o.lng,
              heading: o.estHeading,
              speed: o.estSpeed,
              timestamp: now,
              accuracy: o.acc,
            );
            final reportedSpeed =
                source == 'logged' ? x.loggedSpeed : x.estSpeed;
            final reportedHeading =
                source == 'logged' ? x.loggedHeading : x.estHeading;
            final otherBoat = Boat(
              boatId: 'other',
              boatType: other.type,
              lat: x.lat,
              lng: x.lng,
              heading: reportedHeading,
              speed: reportedSpeed,
              timestamp: now,
              accuracy: x.acc,
            );
            final derived = _derived(other, t);
            final laneDir =
                _laneDirection(resolver, fallbackCenterline, x.lat, x.lng);
            final slow = reportedSpeed < _reliableSpeed;
            final inconsistent = derived != null &&
                (slow ||
                    _angleDiff(reportedHeading, derived.course) >
                        _inconsistentHeadingDeg ||
                    derived.speed > 2 * reportedSpeed + 0.5);
            Boat hyp(double heading, double speed) => Boat(
                  boatId: 'other#h',
                  boatType: other.type,
                  lat: x.lat,
                  lng: x.lng,
                  heading: heading,
                  speed: speed,
                  timestamp: now,
                  accuracy: x.acc,
                );
            final usableDerived =
                derived != null && derived.speed >= _reliableSpeed;
            final variants = <String, List<Boat>>{
              'V0': [otherBoat],
              'V1': [
                otherBoat,
                if (slow && laneDir != null && usableDerived)
                  hyp(laneDir, derived.speed),
              ],
              'V2': [
                otherBoat,
                if (inconsistent && laneDir != null && usableDerived)
                  hyp(laneDir, derived.speed),
              ],
              'V3': [
                otherBoat,
                if (inconsistent && usableDerived)
                  hyp(derived.course, derived.speed),
              ],
            };
            final muted = inMooring(o.lat, o.lng) &&
                o.estSpeed < _mooringRestSpeed &&
                reportedSpeed < _mooringRestSpeed;
            for (final entry in variants.entries) {
              if (entry.value.length > 1) {
                hypothesisTicks[entry.key] = hypothesisTicks[entry.key]! + 1;
              }
              final assessment = evaluator.assessRisk(
                ownBoat,
                entry.value,
                const [],
                warningTimeSeconds: advanceWarningLeadSeconds,
                centerline: fallbackCenterline,
                laneResolver: resolver,
              );
              var ring = false;
              for (final rt in assessment.threats) {
                final th = rt.threat;
                if (th.kind != ThreatKind.boat) continue;
                final ci = th.continuousIntersection;
                if (ci == null || !ci.intersects) continue;
                final tte =
                    ci.currentOverlap ? 0.0 : (ci.firstEntryTimeSeconds ?? 0);
                final isHyp = th.boatId == 'other#h';
                final lowConfidence = isHyp ||
                    ci.reasonCodes.contains('heading_uncertainty_entry');
                final lead = lowConfidence ? 10.0 : advanceWarningLeadSeconds;
                if (tte <= lead) ring = true;
              }
              if (ring && !muted) audible[entry.key]!.add(t);
            }
          }
          final eps = {
            for (final e in audible.entries) e.key: _episodes(e.value)
          };
          final closeEps = _episodes(closeMs);
          // 実際の接近ごとに、最接近の前15秒以内に鳴っていたか。
          Map<String, dynamic> coverage(String v) {
            var warned = 0, total = 0;
            final details = <Map<String, dynamic>>[];
            for (final ce in closeEps) {
              // 動いていない接近（桟橋で並ぶなど）は対象外。
              final o = own.at(ce.start), x = other.at(ce.start);
              if (o == null || x == null) continue;
              if (o.estSpeed < 1.0 && x.estSpeed < 1.0) continue;
              total++;
              final hit =
                  audible[v]!.any((t) => t >= ce.start - 15000 && t <= ce.end);
              if (hit) warned++;
              details.add({
                'at': DateTime.fromMillisecondsSinceEpoch(ce.start, isUtc: true)
                    .toIso8601String(),
                'warned': hit,
                'ownLane':
                    _laneUse(resolver, fallbackCenterline, own, ce.start),
                'otherLane':
                    _laneUse(resolver, fallbackCenterline, other, ce.start),
              });
            }
            return {
              'movingCloseApproaches': total,
              'warned': warned,
              'details': details
            };
          }

          // V0 に無い新しい鳴り方を分類する。
          List<Map<String, dynamic>> newEpisodes(String v) {
            final out = <Map<String, dynamic>>[];
            for (final e in eps[v]!) {
              final overlap =
                  eps['V0']!.any((b) => b.start <= e.end && e.start <= b.end);
              final earlierThan = eps['V0']!
                  .where((b) => b.start <= e.end + 15000 && e.start <= b.end)
                  .map((b) => (b.start - e.start) / 1000)
                  .where((d) => d > 0)
                  .fold<double>(0, math.max);
              if (overlap && earlierThan <= 0) continue;
              var minFuture = double.infinity;
              for (var t = e.start; t <= e.end + 20000; t += 1000) {
                final o = own.at(t), x = other.at(t);
                if (o == null || x == null) continue;
                minFuture =
                    math.min(minFuture, _distM(o.lat, o.lng, x.lat, x.lng));
              }
              final ownLane =
                  _laneUse(resolver, fallbackCenterline, own, e.start);
              final otherLane =
                  _laneUse(resolver, fallbackCenterline, other, e.start);
              final kind = overlap
                  ? 'earlier'
                  : minFuture < _closeMeters
                      ? 'new_real_close'
                      : (ownLane == 'correct' && otherLane == 'correct')
                          ? 'new_false_correct_lanes'
                          : 'new_other';
              out.add({
                'at': DateTime.fromMillisecondsSinceEpoch(e.start, isUtc: true)
                    .toIso8601String(),
                'seconds': e.seconds,
                'kind': kind,
                if (overlap) 'earlierBySec': earlierThan,
                'minActualDistanceNext20s': minFuture.isFinite
                    ? double.parse(minFuture.toStringAsFixed(1))
                    : null,
                'ownLane': ownLane,
                'otherLane': otherLane,
              });
            }
            return out;
          }

          final r = <String, dynamic>{
            'own': own.id,
            'other': other.id,
            'source': source,
            'audibleSeconds': {
              for (final e in audible.entries) e.key: e.value.length
            },
            'episodes': {for (final e in eps.entries) e.key: e.value.length},
            'hypothesisTicks': hypothesisTicks,
            'coverage': {for (final v in audible.keys) v: coverage(v)},
            'newOrEarlier': {
              for (final v in ['V1', 'V2', 'V3']) v: newEpisodes(v)
            },
          };
          results.add(r);
          // ignore: avoid_print
          print('${own.id} <- ${other.id} [$source] '
              'audibleSec=${r['audibleSeconds']} episodes=${r['episodes']} '
              'hyp=${r['hypothesisTicks']} '
              'close=${(r['coverage'] as Map).map((k, v) => MapEntry(k, '${v['warned']}/${v['movingCloseApproaches']}'))}');
          for (final v in ['V1', 'V2', 'V3']) {
            for (final n in (r['newOrEarlier'] as Map)[v] as List) {
              // ignore: avoid_print
              print('  $v ${jsonEncode(n)}');
            }
          }
        }
      }
    }
    if (_out.isNotEmpty) {
      File(_out).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(results));
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
