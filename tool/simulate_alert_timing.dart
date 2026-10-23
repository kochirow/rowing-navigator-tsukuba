// 複数艇の練習を数式で作り、アプリの判定コードへ通して
// 「警告の鳴り始め(秒)」ごとの過剰警告と余裕を比べる検証用ツール。
//
// 桜川で複数艇が同時に漕いだ実機ログは無い。そこで艇の動き・測位誤差・
// 通信を確率モデルで作り、真の位置を知っている状態で
// 「鳴ったのに実は当たらなかった」「当たる何秒前に鳴り始めたか」を数える。
// 判定はアプリと同じ部品をそのまま使う:
//   外挿(extrapolateToNow) → 衝突評価(assessRisk, laneResolver付き)
//   → 提示(SafetyOrchestrator)。
// 設計と結果は docs/design_notes/2026-10-23_警告の鳴り始め_シミュレーション.md。
//
// 使い方:
//
//   flutter test tool/simulate_alert_timing.dart \
//     --dart-define=SIM=calibrate            予測のずれを実測と照合する
//   flutter test tool/simulate_alert_timing.dart \
//     --dart-define=SIM=practice --dart-define=OUT=/tmp/practice.json
//   flutter test tool/simulate_alert_timing.dart \
//     --dart-define=SIM=conflict --dart-define=OUT=/tmp/conflict.json
//
// 追加の指定: SEED(既定 20261023)、MINUTES(練習の長さ、既定 60)、
// RUNS(危ない場面1種類あたりの試行数、既定 120)、WATERS(カンマ区切り)。
// SIM が無い場合はスキップする(CIでは走らない)。
//
// ## モデルの前提(数値の出どころ)
//
// - 速さ: 実機ログ15本(約13.2時間)の漕いでいる区間の中央値 2.8m/s・
//   90パーセンタイル 3.5m/s に合わせる。ピース・流し・休憩・回頭を繰り返す。
// - 横の揺れ: レーン中央へ戻ろうとする減衰振動(周期約60秒)+ 乱れ。
// - 測位: 位置は相関のある誤差(約1.8m・25秒)+ 白色(0.6m)。速度ベクトル
//   (方位・速さの元)は相関のある誤差(0.18m/s・4秒)。
// - 上の3つは `SIM=calibrate` で「T秒先の予測のずれ」を実機ログの値
//   (DESIGN_PRINCIPLES 3.3.1 の表の元データ)と照合して決めた。
// - 通信: 停止中10秒/周囲300m以内に艇がいれば2秒/それ以外5秒で送信し、
//   0.2〜1.0秒遅れて届く。6秒より古い艇は評価に使わない(アプリと同じ)。
// - 艇は警告を聞いても避けない。危ない場面は「避けなかった場合」である。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/config/alert_presentation_config.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';
import 'package:rowing_navigator/models/alert_candidate.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/models/channel_lane.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';
import 'package:rowing_navigator/services/channel_centerline.dart';
import 'package:rowing_navigator/services/channel_lane_resolver.dart';
import 'package:rowing_navigator/services/collision_risk_evaluator_service.dart';
import 'package:rowing_navigator/services/preset_obstacle_service.dart';
import 'package:rowing_navigator/services/safety_orchestrator.dart';
import 'package:rowing_navigator/services/ship_domain_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:rowing_navigator/utils/sat_algorithm.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mode = String.fromEnvironment('SIM');
const _outPath = String.fromEnvironment('OUT');
const _seed = int.fromEnvironment('SEED', defaultValue: 20261023);
const _minutes = int.fromEnvironment('MINUTES', defaultValue: 60);
const _runs = int.fromEnvironment('RUNS', defaultValue: 120);
const _watersArg = String.fromEnvironment('WATERS');

/// 比べる「鳴り始め」(確実な当たり予測)[秒]。予測地平も同じ値にする。
const _deadlines = <double>[9, 10, 11, 12, 13, 14, 16, 18, 20];

/// 比べる「不確かなとき」[秒]。鳴り始めは13秒に固定する。
const _lowConfidenceDeadlines = <double>[8.5, 10, 11.5, 13];

/// 他艇が「近くにいる」とみなす距離。遭遇の始まりと終わり。
const _encounterStartMeters = 120.0;

// 測位・推定の誤差と横の揺れ(SIM=calibrate で実機ログと照合して決める)。
const _velNoiseSd = 0.08; // 推定速度の誤差 [m/s]
const _velNoiseTau = 10.0; // その時定数 [s]
const _errReturnTau = 60.0; // 推定位置の誤差が戻る時定数 [s]
const _lateralNoise = 0.11; // 横の揺れの強さ
const _encounterEndMeters = 160.0;

final _simEpoch = DateTime.utc(2026, 1, 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('警告の鳴り始めをシミュレーションで比べる', () async {
    if (_mode.isEmpty) {
      markTestSkipped('SIM が未指定のためスキップ');
      return;
    }
    // 端末内の設定を読まず、同梱の既定値だけで評価する。
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final world = await _World.load();
    final summary = switch (_mode) {
      'calibrate' => _calibrate(world),
      'practice' => _runPractice(world),
      'conflict' => _runConflicts(world),
      _ => throw ArgumentError('SIM は calibrate / practice / conflict'),
    };
    final json = const JsonEncoder.withIndent('  ').convert(summary);
    if (_outPath.isNotEmpty) File(_outPath).writeAsStringSync(json);
    // ignore: avoid_print
    print(json);
  }, timeout: const Timeout(Duration(hours: 6)));
}

// =====================================================================
// 水域
// =====================================================================

class _Water {
  _Water({
    required this.key,
    required this.label,
    required this.centerline,
    required this.openWater,
    required this.lanes,
    required this.rightOffset,
  });

  /// 艇が漕ぐ横位置(進行方向の右が正、中心線から [m])の分布。
  /// 平均・標準偏差・下限・上限。実機ログ15本の、漕いでいる区間の分布に合わせた
  /// (桜川上流: 中央値7.2m・四分位1.1〜16.5m、霞ヶ浦: 中央値-38m・
  /// 四分位-53〜-20m)。桜川河口は実機ログが約19分しかなく、中央値が
  /// 中心線の左(-2.8m)という右側通行と合わない値だったので使わず、
  /// 運用前提(右側通行)に沿って上流と同じ考え方で幅を広げた値にした。
  final (double, double, double, double) rightOffset;

  final String key;
  final String label;
  final ChannelCenterline centerline;

  /// 霞ヶ浦のように、レーンが「推奨経路」でしかない水域。
  final bool openWater;
  final List<ChannelLane> lanes;

  /// along 10m ごとの、進行方向ごとのレーンの横範囲 [cross の min, max]。
  /// 進行方向 +1 = 中心線の向き、-1 = 逆向き。
  final Map<int, List<(double, double)?>> laneExtent = {};

  double get length => centerline.lengthMeters;

  void buildLaneExtents() {
    for (final dir in const [1, -1]) {
      final lane = lanes.firstWhere(
        (l) =>
            (dir == 1 && l.direction == LaneDirection.along) ||
            (dir == -1 && l.direction == LaneDirection.against),
      );
      final local = lane.points.map(_toLocal).toList();
      final extents = <(double, double)?>[];
      for (var s = 0.0; s <= length; s += 10) {
        double? lo, hi;
        for (var c = -150.0; c <= 150.0; c += 0.5) {
          final p =
              _toLocal(centerline.toLatLng(alongMeters: s, crossMeters: c));
          if (_pointInPolygon(p, local)) {
            lo = lo == null ? c : math.min(lo, c);
            hi = hi == null ? c : math.max(hi, c);
          }
        }
        extents.add(lo == null ? null : (lo, hi!));
      }
      laneExtent[dir] = extents;
    }
  }

  /// 進行方向 [dir] の艇が along [s] で保つレーンの横範囲。
  (double, double) laneAt(double s, int dir) {
    final list = laneExtent[dir]!;
    final i = (s / 10).round().clamp(0, list.length - 1);
    for (var k = 0; k < list.length; k++) {
      for (final j in [i - k, i + k]) {
        if (j >= 0 && j < list.length && list[j] != null) return list[j]!;
      }
    }
    return dir == 1 ? (2.0, 15.0) : (-15.0, -2.0);
  }

  static (double, double) _toLocal(LatLng p) => (
        (p.longitude - 140.2) * 111320 * math.cos(36.08 * math.pi / 180),
        (p.latitude - 36.08) * 111320,
      );

  static bool _pointInPolygon((double, double) p, List<(double, double)> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i], b = poly[j];
      if ((a.$2 > p.$2) != (b.$2 > p.$2) &&
          p.$1 < (b.$1 - a.$1) * (p.$2 - a.$2) / (b.$2 - a.$2) + a.$1) {
        inside = !inside;
      }
    }
    return inside;
  }
}

class _World {
  _World(this.waters, this.obstacles, this.resolver, this.mooringAreas);

  final Map<String, _Water> waters;
  final List<StaticObstacle> obstacles;
  final ChannelLaneResolver resolver;
  final List<List<LatLng>> mooringAreas;

  static Future<_World> load() async {
    final service = PresetObstacleService(
      includeTestZones: false,
      useLocalDangerZoneSettings: false,
      useLocalFixedObstacleCalibrations: false,
    );
    // アプリと同じ読み込み(岸・橋・橋脚・杭・流木・中州・カーブ・逆走)。
    final obstacles = await service.loadPresets();
    final centerlines = await service.loadChannelCenterlines();
    final lanes = await service.loadChannelLanes();
    final mooring = await service.loadMooringAreas();
    final resolver = ChannelLaneResolver(lanes, centerlines: centerlines);
    final labels = {
      'centerline_sakuragawa_upstream': (
        'sakuragawa_upstream',
        '桜川上流',
        false,
        (8.0, 7.0, -4.0, 20.0)
      ),
      'centerline_sakuragawa_estuary': (
        'sakuragawa_estuary',
        '桜川河口',
        false,
        (10.0, 8.0, -4.0, 30.0)
      ),
      'centerline_kasumikagaura': (
        'kasumigaura',
        '霞ヶ浦',
        true,
        (-37.0, 24.0, -90.0, 10.0)
      ),
    };
    final waters = <String, _Water>{};
    for (final entry in centerlines.entries) {
      final label = labels[entry.key];
      if (label == null) continue;
      final water = _Water(
        key: label.$1,
        label: label.$2,
        centerline: entry.value,
        openWater: label.$3,
        rightOffset: label.$4,
        lanes: lanes.where((l) => l.centerlineId == entry.key).toList(),
      )..buildLaneExtents();
      waters[water.key] = water;
    }
    return _World(
      waters,
      obstacles,
      resolver,
      mooring.map((m) => m.points).toList(),
    );
  }

  Iterable<_Water> selectedWaters() {
    if (_watersArg.isEmpty) return waters.values;
    final keys = _watersArg.split(',');
    return waters.values.where((w) => keys.contains(w.key));
  }
}

// =====================================================================
// 乱数
// =====================================================================

class _Rng {
  _Rng(int seed) : _r = math.Random(seed);
  final math.Random _r;
  double? _spare;

  double uniform(double a, double b) => a + (b - a) * _r.nextDouble();
  bool chance(double p) => _r.nextDouble() < p;
  int nextInt(int n) => _r.nextInt(n);

  double normal([double mean = 0, double sd = 1]) {
    if (_spare != null) {
      final v = _spare!;
      _spare = null;
      return mean + sd * v;
    }
    double u, v, s;
    do {
      u = _r.nextDouble() * 2 - 1;
      v = _r.nextDouble() * 2 - 1;
      s = u * u + v * v;
    } while (s >= 1 || s == 0);
    final m = math.sqrt(-2 * math.log(s) / s);
    _spare = v * m;
    return mean + sd * u * m;
  }
}

/// 平均0・標準偏差 [sd]・時定数 [tau] のOrnstein-Uhlenbeck過程(1次元)。
class _Ou {
  _Ou(this.sd, this.tau, _Rng rng) : value = rng.normal(0, sd);
  final double sd, tau;
  double value;

  void step(double dt, _Rng rng) {
    final a = math.exp(-dt / tau);
    value = a * value + sd * math.sqrt(1 - a * a) * rng.normal();
  }
}

// =====================================================================
// 艇の動き(真の状態)
// =====================================================================

enum _Phase { rowing, stopping, resting, turning }

class _Plan {
  /// 練習らしい漕ぎ方を繰り返す。false なら場面で決めた動きだけをする。
  bool practice = true;
  double? fixedSpeed;
  double? fixedCross;
  bool holdStill = false;
}

class _Boat {
  _Boat({
    required this.id,
    required this.type,
    required this.water,
    required this.s,
    required this.dir,
    required _Rng rng,
  })  : _velE = _Ou(_velNoiseSd, _velNoiseTau, rng),
        _velN = _Ou(_velNoiseSd, _velNoiseTau, rng),
        _speedJitter = _Ou(0.3, 15, rng),
        _speedNoise = _Ou(0.2, 3, rng) {
    rightOffset = _drawOffset(rng);
    turnMargin = rng.uniform(50, 160);
    c = _clampToLane(dir * rightOffset, s, dir);
    spm = 20;
  }

  /// 横位置をレーンの中へ収める。外側(岸側)の端からは8m内側まで、
  /// 内側(中心線側)は反対レーンへ6mまではみ出してよい
  /// (実機ログでも桜川上流の10%は中心線より4m以上左を漕いでいた)。
  double _clampToLane(double cross, double along, int direction) {
    final (lo, hi) = water.laneAt(along, direction);
    final outerIsHi = hi.abs() >= lo.abs();
    final min = outerIsHi ? lo - 6 : lo + 8;
    final max = outerIsHi ? hi - 8 : hi + 6;
    if (min > max) return (lo + hi) / 2;
    return cross.clamp(min, max).toDouble();
  }

  final String id;
  final BoatType type;
  final _Water water;
  final plan = _Plan();

  // 真の状態(曲線座標)
  double s; // along [m]
  double c = 0; // cross [m](中心線の右が正)
  int dir; // +1: 中心線の向き、-1: 逆向き
  double v = 0; // 前進の速さ [m/s]
  double u = 0; // 横方向の速さ [m/s]
  double turnAngle = 0; // 回頭中の向き(進行方向から) [rad]
  double cruise = 2.6;
  double spm = 20;

  /// この艇が漕ぐ横位置(進行方向の右が正)。回頭のたびに選び直す。
  double rightOffset = 0;

  /// 見張りによるよけ(進行方向の右が正)。
  double avoidShift = 0;

  /// 航路の端から何m手前で回頭するか(艇ごと・往復ごとに違う)。
  double turnMargin = 100;
  double? matchSpeed;

  /// 同じ水域の艇(見張りの対象)。
  List<_Boat> fleet = const [];
  double t = 0;

  _Phase phase = _Phase.rowing;
  double phaseUntil = 0;
  bool inPiece = false;

  // 推定の誤差。推定位置の誤差 e は推定速度の誤差 w を積分したもの
  // (+ ゆっくり戻る)とし、推定位置と推定速度が食い違わないようにする。
  // アプリの Kalman の出力は滑らかで、位置だけが細かく跳ねることはない。
  final _Ou _velE, _velN;
  double _errE = 0, _errN = 0;
  final _Ou _speedJitter;

  /// 推定の速さの誤差(進行方向だけ)。ストローク中の速さの増減を拾うため大きい。
  final _Ou _speedNoise;
  double _surge = 1;

  // 通信
  double nextSendAt = 0;

  double _drawOffset(_Rng rng) {
    final (mean, sd, lo, hi) = water.rightOffset;
    return rng.normal(mean, sd).clamp(lo, hi).toDouble();
  }

  /// 予定どおりの横位置(よけを含まない)。
  double get lineCross => dir * rightOffset;

  /// 見張り。実際の漕手はアプリとは別に前方(振り返り)を見て、
  /// 正面から来る艇とは互いに右へよけ、遅い艇・止まっている艇は追い越すか
  /// 速さを合わせる。これが無いと、正常な練習なのに艇が素通りでぶつかる。
  void _lookout() {
    avoidShift = 0;
    matchSpeed = null;
    if (!plan.practice) return;
    for (final o in fleet) {
      if (identical(o, this)) continue;
      final gap = (o.s - s) * dir; // 前方が正
      final lateral = (o.c - c) * dir; // 自艇の右が正
      if (o.dir != dir && o.phase == _Phase.rowing) {
        if (gap > 0 && gap < 70 && (o.c - c).abs() < 12) {
          avoidShift = math.max(avoidShift, 5);
        }
        continue;
      }
      if (lateral.abs() >= 10) continue;
      final oncoming = fleet.any((x) =>
          x.dir != dir && ((x.s - s) * dir) > 0 && ((x.s - s) * dir) < 150);
      if (gap > 0 && gap < 45) {
        // 前の艇: 遅い・止まっていれば追い越す。反対から艇が来ていれば、
        // 追い越さずに後ろ30mを保つ。
        final slower = o.v < v - 0.2 || o.phase != _Phase.rowing;
        if (o.phase != _Phase.rowing || (slower && !oncoming)) {
          avoidShift = lateral >= 0 ? -12 : 12;
        } else if (gap < 30) {
          matchSpeed = math.max(0.6, o.v - 0.3);
        }
      } else if (gap.abs() <= 8 &&
          o.phase == _Phase.rowing &&
          id.compareTo(o.id) > 0) {
        // 横並び: 片方(IDの大きい方)が下がって間を空ける。
        matchSpeed = math.max(0.6, o.v - 0.6);
      }
    }
  }

  double get _typeBonus => switch (type) {
        BoatType.r_8p => 0.6,
        BoatType.r_4x || BoatType.r_4m || BoatType.r_4p => 0.3,
        BoatType.r_2x || BoatType.r_2m || BoatType.r_2p => 0.15,
        _ => 0.0,
      };

  /// 漕ぎ方の予定を進める(ピース → 流し → 時々休憩)。
  void _schedule(_Rng rng) {
    if (!plan.practice || t < phaseUntil) return;
    if (phase == _Phase.resting) {
      phase = _Phase.rowing;
    }
    if (phase == _Phase.rowing) {
      inPiece = !inPiece && rng.chance(0.45);
      if (!inPiece && rng.chance(0.15)) {
        // 航路の端で休む(岸側へ寄せてから止まる)。
        phase = _Phase.stopping;
        phaseUntil = t + rng.uniform(15, 25);
        return;
      }
      cruise = (inPiece ? rng.normal(3.3, 0.25) : rng.normal(2.55, 0.25)) +
          _typeBonus;
      spm = inPiece ? rng.uniform(28, 32) : rng.uniform(18, 23);
      phaseUntil = t + (inPiece ? rng.uniform(60, 180) : rng.uniform(60, 240));
    } else if (phase == _Phase.stopping) {
      phase = _Phase.resting;
      phaseUntil = t + rng.uniform(60, 180);
    }
  }

  void step(double dt, _Rng rng) {
    t += dt;
    _schedule(rng);
    _lookout();
    final tangentSign = dir.toDouble();
    final lane = water.laneAt(s, dir);

    // 回頭: 航路の端に近づいたら止まって180度回る(その場で回る)。
    if (plan.practice && phase != _Phase.turning) {
      final remaining =
          dir > 0 ? water.length - turnMargin - s : s - turnMargin;
      // 近くで別の艇が回頭している間は、端の手前30mまで待つ。
      final someoneTurning = fleet.any((o) =>
          !identical(o, this) &&
          o.phase == _Phase.turning &&
          (o.s - s).abs() < 25);
      final hardLimit = dir > 0 ? water.length - 30 - s : s - 30;
      if (remaining < 0 && (!someoneTurning || hardLimit < 0)) {
        phase = _Phase.turning;
        turnAngle = 0;
        phaseUntil = t + rng.uniform(35, 50);
        turnMargin = rng.uniform(50, 160);
      } else if (remaining < 0) {
        matchSpeed = 0.8;
      }
    }

    double targetSpeed;
    double targetCross;
    switch (phase) {
      case _Phase.rowing:
        targetSpeed = plan.fixedSpeed ?? matchSpeed ?? cruise;
        targetCross = plan.fixedCross ??
            _clampToLane(dir * (rightOffset + avoidShift), s, dir);
      case _Phase.stopping:
        targetSpeed = 1.2;
        // 進行方向の右へ寄せて止まる(レーンの外側の端から4m内側まで)。
        final edge = dir > 0 ? lane.$2 - 4 : -(lane.$1 + 4);
        targetCross = dir * math.min(rightOffset + 6, edge);
      case _Phase.resting:
        targetSpeed = 0;
        targetCross = c;
      case _Phase.turning:
        targetSpeed = 0;
        targetCross = c;
    }
    if (plan.holdStill) {
      targetSpeed = 0;
      targetCross = c;
    }

    if (phase == _Phase.turning) {
      // その場で回る。向きを0→πへ回し、終わったら向きを反転して反対レーンへ。
      final duration = 42.0;
      v = math.max(0, v - 0.5 * dt);
      turnAngle = math.min(math.pi, turnAngle + math.pi * dt / duration);
      if (turnAngle == math.pi * dt / duration) rightOffset = _drawOffset(rng);
      final next = _clampToLane(-dir * rightOffset, s, -dir);
      c += (next - c) * math.min(1, dt / 30) * 0.5;
      u = 0;
      if (turnAngle >= math.pi - 1e-6 || t >= phaseUntil) {
        dir = -dir;
        turnAngle = 0;
        phase = _Phase.rowing;
        inPiece = false;
        cruise = rng.normal(2.55, 0.25) + _typeBonus;
        phaseUntil = t + rng.uniform(60, 200);
      }
      return;
    }

    // 前進の速さ: 加速は穏やか、止めるときは速い。
    if (phase == _Phase.rowing && targetSpeed > 0.5) {
      // 漕ぎの強さは一定でない(声掛け・ばらつき)。
      targetSpeed = math.max(0.8, targetSpeed + _speedJitter.value);
    }
    final accel = targetSpeed > v ? 0.15 : 0.35;
    final dv = (targetSpeed - v).clamp(-accel * dt, accel * dt);
    v = math.max(0, v + dv);

    // 横: レーン中央へ戻ろうとする減衰振動 + 乱れ(周期約60秒)。
    const omega = 2 * math.pi / 60;
    const zeta = 0.55;
    final noise = v > 0.5 ? _lateralNoise : 0.01;
    final a = -omega * omega * (c - targetCross) -
        2 * zeta * omega * u +
        noise * rng.normal() / math.sqrt(dt);
    u += a * dt;
    // 止まっている艇は横へもほとんど動かない(風で少し流れる)。
    if (v < 0.3) u *= 0.8;
    c += u * dt;

    // ストロークごとの艇速の増減(前進方向の位置だけに効かせる)。
    // ストロークの中で艇速は ±20% ほど増減する(キャッチで落ち、ドライブで伸びる)。
    _surge = v > 1.0 ? 1 + 0.2 * math.sin(2 * math.pi * spm / 60 * t) : 1.0;
    s += tangentSign * v * _surge * dt;
    s = s.clamp(1.0, water.length - 1.0);

    _velE.step(dt, rng);
    _velN.step(dt, rng);
    _errE += (_velE.value - _errE / _errReturnTau) * dt;
    _errN += (_velN.value - _errN / _errReturnTau) * dt;
    _speedJitter.step(dt, rng);
    _speedNoise.step(dt, rng);
  }

  // ---- 真の位置・向き ----

  LatLng get truePosition =>
      water.centerline.toLatLng(alongMeters: s, crossMeters: c);

  /// 真の艇首方位 [度]。
  double get trueHeading {
    final tangent = water.centerline.tangentBearingAt(s);
    final travel = dir > 0 ? tangent : tangent + 180;
    if (phase == _Phase.turning) {
      return (travel + turnAngle * 180 / math.pi) % 360;
    }
    final lateral = math.atan2(u, math.max(v, 0.3)) * 180 / math.pi;
    return (travel + lateral * dir.toDouble()) % 360;
  }

  /// 真の速度ベクトル [m/s](東, 北)。
  (double, double) get trueVelocity {
    if (phase == _Phase.turning) return (0, 0);
    final h = trueHeading * math.pi / 180;
    final forward = v * _surge;
    final speed = math.sqrt(forward * forward + u * u);
    return (speed * math.sin(h), speed * math.cos(h));
  }

  Boat trueBoat(DateTime stamp) => Boat(
        boatId: id,
        boatType: type,
        lat: truePosition.latitude,
        lng: truePosition.longitude,
        heading: trueHeading,
        speed: math.sqrt(v * v + u * u),
        timestamp: stamp,
        accuracy: 3,
      );

  /// アプリが自艇について持つ値(推定位置・方位・速さ)。
  Boat measuredBoat(DateTime stamp, _Rng rng) {
    final p = truePosition;
    final eE = _errE;
    final eN = _errN;
    final lat = p.latitude + eN / 111320;
    final lng =
        p.longitude + eE / (111320 * math.cos(p.latitude * math.pi / 180));
    final (ve, vn) = trueVelocity;
    final me = ve + _velE.value - _errE / _errReturnTau + rng.normal(0, 0.04);
    final mn = vn + _velN.value - _errN / _errReturnTau + rng.normal(0, 0.04);
    final rawSpeed = math.sqrt(me * me + mn * mn);
    final speed =
        rawSpeed < 0.3 ? rawSpeed : math.max(0.0, rawSpeed + _speedNoise.value);
    // 遅いときの方位は速度ベクトルから決まらないので、真の向き+大きな誤差。
    final heading = speed > 0.6
        ? (math.atan2(me, mn) * 180 / math.pi) % 360
        : (trueHeading + rng.normal(0, 40)) % 360;
    return Boat(
      boatId: id,
      boatType: type,
      lat: lat,
      lng: lng,
      heading: heading < 0 ? heading + 360 : heading,
      speed: speed,
      timestamp: stamp,
      accuracy: 4 + rng.normal(0, 1).abs() * 1.5,
    );
  }
}

// =====================================================================
// 照合: 予測のずれを実機ログの値と比べる
// =====================================================================

Map<String, dynamic> _calibrate(_World world) {
  final rng = _Rng(_seed);
  const horizons = [3, 5, 8, 10, 13, 16, 20, 25];
  final out = <String, dynamic>{};
  for (final water in world.selectedWaters()) {
    final cross = {for (final h in horizons) h: <double>[]};
    final along = {for (final h in horizons) h: <double>[]};
    final speeds = <double>[];
    final relHeading = <double>[];
    for (var k = 0; k < 6; k++) {
      final boat = _Boat(
        id: 'cal$k',
        type: BoatType.values[rng.nextInt(4)],
        water: water,
        s: rng.uniform(100, water.length - 100),
        dir: rng.chance(0.5) ? 1 : -1,
        rng: rng,
      );
      // 1秒ごとの (時刻, 推定値) を貯めて、T秒後の推定位置と比べる。
      final samples = <(double, Boat)>[];
      for (var i = 0; i < _minutes * 60; i++) {
        boat.step(1, rng);
        samples.add((boat.t, boat.measuredBoat(_simEpoch, rng)));
      }
      for (var i = 0; i < samples.length; i++) {
        final b = samples[i].$2;
        if (b.speed < 1.5) continue;
        speeds.add(b.speed);
        final f = water.centerline.project(LatLng(b.lat, b.lng));
        final rel = ((b.heading - f.tangentBearingDegrees + 540) % 360 - 180) *
            math.pi /
            180;
        if (math.cos(rel).abs() < 0.5) continue;
        relHeading.add(math.atan2(math.sin(rel), math.cos(rel).abs()).abs() *
            180 /
            math.pi);
        for (final h in horizons) {
          final j = i + h;
          if (j >= samples.length) continue;
          final g = water.centerline
              .project(LatLng(samples[j].$2.lat, samples[j].$2.lng));
          final pa = f.alongMeters + b.speed * math.cos(rel) * h;
          final pc = f.crossMeters + b.speed * math.sin(rel) * h;
          along[h]!.add((g.alongMeters - pa).abs());
          cross[h]!.add((g.crossMeters - pc).abs());
        }
      }
    }
    out[water.key] = {
      'laneExtentEvery200m': [
        for (var x = 0.0; x <= water.length; x += 200)
          '${x.round()}: +1 ${water.laneAt(x, 1)} / -1 ${water.laneAt(x, -1)}',
      ],
      'speed': _percentiles(speeds),
      'relHeadingDeg': _percentiles(relHeading),
      'cross': {for (final h in horizons) '$h': _percentiles(cross[h]!)},
      'along': {for (final h in horizons) '$h': _percentiles(along[h]!)},
    };
  }
  return out;
}

Map<String, double> _percentiles(List<double> xs) {
  if (xs.isEmpty) return const {};
  final s = [...xs]..sort();
  double p(double q) => s[math.min(s.length - 1, (s.length * q).floor())];
  return {
    'p10': _round(p(.1)),
    'p50': _round(p(.5)),
    'p90': _round(p(.9)),
    'p95': _round(p(.95)),
    'n': s.length.toDouble(),
  };
}

double _round(double x) => (x * 10).roundToDouble() / 10;

// =====================================================================
// 判定(アプリと同じ部品)と集計
// =====================================================================

/// 比べる設定1つ。鳴り始め [deadline] と、確度が低いときの鳴り始め [lowConfidence]。
class _Variant {
  const _Variant(this.deadline, this.lowConfidence);
  final double deadline;
  final double lowConfidence;
  String get key => 'D${_fmt(deadline)}_L${_fmt(lowConfidence)}';
  static String _fmt(double x) =>
      x == x.roundToDouble() ? x.toStringAsFixed(0) : x.toStringAsFixed(1);
}

List<_Variant> _variants() => [
      for (final d in _deadlines) _Variant(d, math.min(10, d - 0.5)),
      for (final l in _lowConfidenceDeadlines)
        if (l != 10) _Variant(13, l),
    ];

class _Message {
  _Message(this.boat, this.sentAt, this.arrivesAt);
  final Boat boat;
  final double sentAt;
  final double arrivesAt;
}

/// 1艇ぶんの判定器(設定ごとに提示の状態を持つ)。
class _Judge {
  _Judge(this.boat, List<_Variant> variants, _World world)
      : orchestrators = {
          for (final v in variants)
            v.key: SafetyOrchestrator(
              sessionId: 'sim-${boat.id}-${v.key}',
              sessionGeneration: 1,
              mooringAreas: world.mooringAreas,
              presentationConfig: AlertPresentationConfig(
                audioStartDeadline:
                    Duration(milliseconds: (v.deadline * 1000).round()),
                lowConfidenceAudioStartDeadline:
                    Duration(milliseconds: (v.lowConfidence * 1000).round()),
              ),
            ),
        };
  final _Boat boat;
  final Map<String, SafetyOrchestrator> orchestrators;

  /// 受信した他艇の最新メッセージ。
  final inbox = <String, _Message>{};
}

/// ある設定で、ある時刻に鳴っていた音。
class _Sound {
  _Sound(this.category, this.targetId, this.mode, this.eventId);
  final String category;
  final String? targetId;
  final AudioDirectiveMode mode;
  final String? eventId;
}

class _Simulation {
  _Simulation(this.world, this.boats, this.variants, this.rng) {
    for (final b in boats) {
      b.fleet = boats;
    }
  }

  final _World world;
  final List<_Boat> boats;
  final List<_Variant> variants;
  final _Rng rng;
  final evaluator = CollisionRiskEvaluatorService();
  final domains = ShipDomainService();
  late final judges = {for (final b in boats) b.id: _Judge(b, variants, world)};
  final pending = <_Message>[];

  /// 直前の音(設定 → 艇 → 音)。新しい鳴り始めの判定に使う。
  final lastEvent = <String, Map<String, String?>>{};

  /// その秒に「音を出す提示」になっていた警告の対象(設定 → 艇 → 対象ID)。
  /// 音声は1本なので、警告が立っていても別の音が鳴っていることがある。
  final audibleTargets = <String, Map<String, Set<String>>>{};

  /// 1秒進め、全艇を判定する。戻り値: 設定 → 艇ID → 鳴っていた音。
  Map<String, Map<String, _Sound?>> tick() {
    for (final b in boats) {
      b.step(0.5, rng);
      b.step(0.5, rng);
    }
    final now = boats.first.t;
    // 送信(アプリの適応送信を簡略化)
    for (final b in boats) {
      if (now < b.nextSendAt) continue;
      final p = b.truePosition;
      final near =
          boats.any((o) => o != b && _distance(o.truePosition, p) < 300);
      final interval = b.v < 0.5 ? 10.0 : (near ? 2.0 : 5.0);
      b.nextSendAt = now + interval;
      pending.add(_Message(
        b.measuredBoat(
            _simEpoch.add(Duration(milliseconds: (now * 1000).round())), rng),
        now,
        now + rng.uniform(0.2, 1.0),
      ));
    }
    // 受信
    pending.removeWhere((m) {
      if (m.arrivesAt > now) return false;
      for (final j in judges.values) {
        if (j.boat.id != m.boat.boatId) j.inbox[m.boat.boatId] = m;
      }
      return true;
    });

    final result = <String, Map<String, _Sound?>>{
      for (final v in variants) v.key: {},
    };
    final evaluatedAt =
        _simEpoch.add(Duration(milliseconds: (now * 1000).round()));
    for (final judge in judges.values) {
      final wallNow = DateTime.now();
      final own = judge.boat.measuredBoat(wallNow, rng);
      // アプリと同じく、6秒より古い艇を落としてから現在まで外挿する。
      final others = <Boat>[];
      final speedById = <String, double?>{};
      for (final m in judge.inbox.values) {
        final age = now - m.sentAt;
        if (age >= boatPredictionTimeoutSeconds) continue;
        final stamped = Boat(
          boatId: m.boat.boatId,
          boatType: m.boat.boatType,
          lat: m.boat.lat,
          lng: m.boat.lng,
          heading: m.boat.heading,
          speed: m.boat.speed,
          timestamp:
              wallNow.subtract(Duration(milliseconds: (age * 1000).round())),
          accuracy: m.boat.accuracy,
        );
        others.add(evaluator.extrapolateToNow(stamped, now: wallNow));
        speedById[m.boat.boatId] = m.boat.speed;
      }
      final assessments = <double, RiskAssessment>{};
      for (final v in variants) {
        final assessment = assessments.putIfAbsent(
          v.deadline,
          () => evaluator.assessRisk(
            own,
            others,
            world.obstacles,
            warningTimeSeconds: v.deadline,
            laneResolver: world.resolver,
          ),
        );
        final r = judge.orchestrators[v.key]!.processAssessment(
          assessment: assessment,
          evaluatedAt: evaluatedAt,
          capabilities: const CapabilitySnapshot(
            gpsUsable: true,
            staticProfileUsable: true,
            audioUsable: true,
          ),
          ownSpeedMetersPerSecond: own.speed,
          ownPosition: LatLng(own.lat, own.lng),
          otherBoatSpeedById: speedById,
          healthyBoatIds: speedById.keys.toSet(),
        );
        (audibleTargets[v.key] ??= {})[judge.boat.id] = {
          for (final alert in r.snapshot.activeAlerts)
            if (alert.candidate.behavior == AlertBehavior.continuousAction ||
                alert.candidate.behavior == AlertBehavior.singleAction)
              alert.candidate.targetId ?? alert.candidate.category,
        };
        final d = r.snapshot.audioDirective;
        if (d == null) {
          result[v.key]![judge.boat.id] = null;
          continue;
        }
        final candidate = r.snapshot.activeAlerts
            .map((a) => a.candidate)
            .where((c) => c.alertId == d.alertId)
            .firstOrNull;
        result[v.key]![judge.boat.id] = _Sound(
          candidate?.category ?? '?',
          candidate?.targetId,
          d.mode,
          d.eventId,
        );
      }
    }
    return result;
  }

  /// 真の状態で、a の排他領域が b の船体に掛かっているか(= 危険接近)、
  /// 船体どうしが重なっているか(= 接触)。
  (bool, bool) trueConflict(_Boat a, _Boat b) {
    if (_distance(a.truePosition, b.truePosition) > 40) return (false, false);
    final stamp = _simEpoch;
    final da = domains.getShipDomains(a.trueBoat(stamp), headingReliable: true);
    final db = domains.getShipDomains(b.trueBoat(stamp), headingReliable: true);
    final danger = polygonsOverlap(da.exclusiveDomain, db.shipBodyDomain);
    final contact = polygonsOverlap(da.shipBodyDomain, db.shipBodyDomain);
    return (danger, contact);
  }

  /// 真の船体が静的危険区域 [obstacle] に掛かっているか。
  bool trueHazardContact(_Boat a, StaticObstacle obstacle) {
    final da =
        domains.getShipDomains(a.trueBoat(_simEpoch), headingReliable: true);
    return polygonsOverlap(da.shipBodyDomain,
        Polygon(polygonId: const PolygonId('h'), points: obstacle.points));
  }
}

/// 2艇が重ならないための中心間距離(横)。排他領域の半幅 + 相手の船体半幅 +
/// 通常のGPS・データ齢の上乗せ2.2m(risk_evaluator_config の表と同じ考え方)。
double _noOverlapDistance(_Boat a, _Boat b) {
  double exclusiveHalf(BoatType t) => t == BoatType.r_8p ? 5.25 : 4.5;
  double bodyHalf(BoatType t) => t == BoatType.r_8p ? 3.75 : 3.0;
  return exclusiveHalf(a.type) + bodyHalf(b.type) + 2.2;
}

double _distance(LatLng a, LatLng b) {
  final dy = (a.latitude - b.latitude) * 111320;
  final dx = (a.longitude - b.longitude) *
      111320 *
      math.cos(a.latitude * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

// =====================================================================
// 練習(正常な運用)
// =====================================================================

const _boatTypes = [BoatType.r_1x, BoatType.r_2x, BoatType.r_4x, BoatType.r_8p];

/// 遭遇1件の記録(自艇 a から見た他艇 b)。
class _Encounter {
  _Encounter(this.a, this.b, this.start,
      {required this.sameDirection, required this.collisionCourse});
  final String a, b;
  final double start;

  /// 同じ向きに進む艇(追い越し・追従)か。
  final bool sameDirection;

  /// 遭遇の始まりの時点で、互いの予定の横位置が
  /// 「重ならないための中心間距離 + 2m」より近いか。
  /// よけなければ当たる遭遇。false なら、よけなくても当たらない遭遇で、
  /// 鳴ったらそれは過剰警告である。
  final bool collisionCourse;
  double? firstDanger;
  double? firstContact;
  double minDistance = double.infinity;
  final firstSound = <String, double>{};
  final soundSeconds = <String, int>{};
}

Map<String, dynamic> _runPractice(_World world) {
  final variants = _variants();
  final out = <String, dynamic>{};
  final configs = <(String, int)>[];
  for (final water in world.selectedWaters()) {
    for (final n in const [6, 12]) {
      configs.add((water.key, n));
    }
  }
  for (final (waterKey, n) in configs) {
    final water = world.waters[waterKey]!;
    final rng = _Rng(_seed + n * 7 + waterKey.hashCode % 1000);
    // 出艇位置は互いに前後60m以上離す(同じ場所から一斉には出ない)。
    final starts = <double>[];
    while (starts.length < n) {
      final x = rng.uniform(80, water.length - 80);
      if (starts.every((y) => (x - y).abs() >= 60)) starts.add(x);
    }
    final boats = [
      for (var i = 0; i < n; i++)
        _Boat(
          id: 'b$i',
          type: _boatTypes[i % _boatTypes.length],
          water: water,
          s: starts[i],
          dir: rng.chance(0.5) ? 1 : -1,
          rng: rng,
        ),
    ];
    final sim = _Simulation(world, boats, variants, rng);
    final loopSeconds = {for (final v in variants) v.key: <String, int>{}};
    final onceCount = {for (final v in variants) v.key: <String, int>{}};
    final lastEventId = {for (final v in variants) v.key: <String, String?>{}};
    final active = <String, _Encounter>{};
    final done = <_Encounter>[];
    final breakdown = <String, int>{};
    final stopwatch = Stopwatch()..start();
    for (var sec = 0; sec < _minutes * 60; sec++) {
      final sounds = sim.tick();
      final now = boats.first.t;
      for (final v in variants) {
        for (final b in boats) {
          final s = sounds[v.key]![b.id];
          if (s == null) {
            lastEventId[v.key]![b.id] = null;
            continue;
          }
          if (s.mode == AudioDirectiveMode.loop) {
            loopSeconds[v.key]![s.category] =
                (loopSeconds[v.key]![s.category] ?? 0) + 1;
            if (v.key == 'D13_L10') {
              final target = boats.where((o) => o.id == s.targetId).firstOrNull;
              final relation = target == null
                  ? '-'
                  : '${target.dir == b.dir ? 'same' : 'oncoming'}/${target.phase.name}'
                      '/d${(_distance(target.truePosition, b.truePosition) / 20).floor() * 20}';
              final k = '${s.category}/${b.phase.name}/$relation';
              breakdown[k] = (breakdown[k] ?? 0) + 1;
            }
          } else if (s.eventId != lastEventId[v.key]![b.id]) {
            onceCount[v.key]![s.category] =
                (onceCount[v.key]![s.category] ?? 0) + 1;
          }
          lastEventId[v.key]![b.id] = s.eventId;
        }
      }
      // 遭遇の追跡と真の危険接近
      for (final a in boats) {
        for (final b in boats) {
          if (a == b) continue;
          final key = '${a.id}>${b.id}';
          final d = _distance(a.truePosition, b.truePosition);
          var e = active[key];
          if (e == null && d < _encounterStartMeters) {
            final sameDirection = a.dir == b.dir;
            final lateral = (a.lineCross - b.lineCross).abs();
            final closing = sameDirection
                ? ((b.s - a.s) * a.dir > 0 && a.cruise > b.cruise + 0.2) ||
                    b.phase != _Phase.rowing
                : (b.s - a.s) * a.dir > 0;
            e = active[key] = _Encounter(
              a.id,
              b.id,
              now,
              sameDirection: sameDirection,
              collisionCourse:
                  closing && lateral < _noOverlapDistance(a, b) + 2,
            );
          }
          if (e == null) continue;
          e.minDistance = math.min(e.minDistance, d);
          final (danger, contact) = sim.trueConflict(a, b);
          if (danger) e.firstDanger ??= now;
          if (contact) e.firstContact ??= now;
          for (final v in variants) {
            final s = sounds[v.key]![a.id];
            if (s != null && s.category == 'other_boat' && s.targetId == b.id) {
              e.firstSound[v.key] ??= now;
              e.soundSeconds[v.key] = (e.soundSeconds[v.key] ?? 0) + 1;
            }
          }
          if (d > _encounterEndMeters) {
            done.add(e);
            active.remove(key);
          }
        }
      }
    }
    done.addAll(active.values);
    final boatHours = n * _minutes / 60;
    final perVariant = <String, dynamic>{};
    for (final v in variants) {
      final safe = done.where((e) => !e.collisionCourse).toList();
      final safeOncoming = safe.where((e) => !e.sameDirection).toList();
      final course = done.where((e) => e.collisionCourse).toList();
      final danger = done.where((e) => e.firstDanger != null).toList();
      final falseAlerts =
          safe.where((e) => e.firstSound.containsKey(v.key)).length;
      final falseAlertsOncoming =
          safeOncoming.where((e) => e.firstSound.containsKey(v.key)).length;
      final leads = [
        for (final e in danger)
          if (e.firstSound[v.key] != null &&
              e.firstSound[v.key]! <= e.firstDanger!)
            e.firstDanger! - e.firstSound[v.key]!,
      ];
      final missed = danger
          .where((e) =>
              e.firstSound[v.key] == null ||
              e.firstSound[v.key]! > e.firstDanger!)
          .length;
      perVariant[v.key] = {
        'loopSecondsPerBoatHour': {
          for (final entry in loopSeconds[v.key]!.entries)
            entry.key: _round(entry.value / boatHours),
        },
        'loopSecondsPerBoatHourTotal': _round(
            loopSeconds[v.key]!.values.fold(0, (a, b) => a + b) / boatHours),
        'onceUtterancesPerBoatHour': {
          for (final entry in onceCount[v.key]!.entries)
            entry.key: _round(entry.value / boatHours),
        },
        'safeEncounters': safe.length,
        'safeEncountersAlerted': falseAlerts,
        'safeEncounterAlertRate':
            safe.isEmpty ? null : _round(100 * falseAlerts / safe.length),
        'safeOncomingEncounters': safeOncoming.length,
        'safeOncomingAlertRate': safeOncoming.isEmpty
            ? null
            : _round(100 * falseAlertsOncoming / safeOncoming.length),
        'collisionCourseEncounters': course.length,
        'collisionCourseAlertRate': course.isEmpty
            ? null
            : _round(100 *
                course.where((e) => e.firstSound.containsKey(v.key)).length /
                course.length),
        'dangerEncounters': danger.length,
        'dangerLeadSeconds': _percentiles(leads),
        'dangerNotAlertedBeforeDanger': missed,
      };
    }
    out['${water.key}_n$n'] = {
      'water': water.label,
      'boats': n,
      'minutes': _minutes,
      'boatHours': boatHours,
      'encounters': done.length,
      'wallSeconds': stopwatch.elapsed.inSeconds,
      'loopBreakdownD13': Map.fromEntries(breakdown.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value))),
      'variants': perVariant,
    };
    // ignore: avoid_print
    print('done ${water.label} n=$n in ${stopwatch.elapsed.inSeconds}s, '
        'encounters ${done.length}');
  }
  return out;
}

// =====================================================================
// 危ない場面(避けなかった場合)
// =====================================================================

typedef _Setup = (List<_Boat>, String?) Function(_Water, _Rng);

Map<String, dynamic> _runConflicts(_World world) {
  final variants = _variants();
  final out = <String, dynamic>{};
  for (final water in world.selectedWaters()) {
    final scenarios = <String, _Setup>{
      'head_on_same_lane': (w, r) =>
          _headOn(w, r, lateralOffset: r.uniform(-2, 2)),
      'head_on_offset_3_7m': (w, r) => _headOn(w, r,
          lateralOffset: r.uniform(3, 7) * (r.chance(.5) ? 1 : -1)),
      'stopped_boat_in_lane': _stoppedInLane,
      'overtaking': _overtaking,
      'turning_in_lane': _turningInLane,
      if (!water.openWater) 'bridge_pier': (w, r) => _pierApproach(w, r, world),
    };
    for (final entry in scenarios.entries) {
      final leads = {for (final v in variants) v.key: <double>[]};
      final missed = {for (final v in variants) v.key: 0};
      final silentMissed = {for (final v in variants) v.key: 0};
      final alertMissed = {for (final v in variants) v.key: 0};
      final alertLeads = {for (final v in variants) v.key: <double>[]};
      final missDetails = <Map<String, dynamic>>[];
      var straightRuns = 0;
      bool v13Missed(Map<String, double> first, double danger) {
        final s = first['D13_L10'];
        return s == null || s > danger || danger - s < 5;
      }

      var dangerRuns = 0;
      var runs = 0;
      final rng = _Rng(_seed + entry.key.hashCode % 10000 + water.key.length);
      final stopwatch = Stopwatch()..start();
      for (var k = 0; k < _runs; k++) {
        final (boats, hazardId) = entry.value(water, rng);
        if (boats.isEmpty) continue;
        runs++;
        final sim = _Simulation(world, boats, variants, rng);
        final a = boats.first;
        final hazard = hazardId == null
            ? null
            : world.obstacles.firstWhere((o) => o.id == hazardId);
        double? firstDanger;
        final firstSound = <String, double>{};
        final firstAnySound = <String, double>{};
        final firstAlert = <String, double>{};
        var straightPredictionTicks = 0;
        for (var sec = 0; sec < 110; sec++) {
          final sounds = sim.tick();
          final now = a.t;
          if (world.resolver.centerlineFor(a.truePosition) == null) {
            straightPredictionTicks++;
          }
          for (final v in variants) {
            if (sounds[v.key]![a.id] != null) firstAnySound[v.key] ??= now;
            final targets = sim.audibleTargets[v.key]?[a.id] ?? const {};
            final alerted = hazard == null
                ? targets.contains(boats[1].id)
                : targets.any((t) =>
                    t == hazard.sourceId ||
                    t == hazard.id ||
                    t == hazard.bridgeId);
            if (alerted) firstAlert[v.key] ??= now;
          }
          for (final v in variants) {
            final s = sounds[v.key]![a.id];
            // 橋脚の場面では、その橋脚かその橋への音だけを数える(別の橋は数えない)。
            final targeted = s != null &&
                (hazard == null
                    ? s.category == 'other_boat'
                    : ((s.category == 'bridgePier' &&
                            (s.targetId == hazard.sourceId ||
                                s.targetId == hazard.id)) ||
                        (s.category == 'bridge' &&
                            s.targetId != null &&
                            s.targetId == hazard.bridgeId)));
            if (targeted) firstSound[v.key] ??= now;
          }
          final danger = hazard == null
              ? sim.trueConflict(a, boats[1]).$1
              : sim.trueHazardContact(a, hazard);
          if (danger) {
            firstDanger = now;
            break;
          }
        }
        if (firstDanger == null) continue;
        dangerRuns++;
        if (straightPredictionTicks > 0) straightRuns++;
        for (final v in variants) {
          final s = firstSound[v.key];
          if (s == null || s > firstDanger) {
            missed[v.key] = missed[v.key]! + 1;
          } else {
            leads[v.key]!.add(firstDanger - s);
          }
          final any = firstAnySound[v.key];
          if (any == null || any > firstDanger) {
            silentMissed[v.key] = silentMissed[v.key]! + 1;
          }
          final al = firstAlert[v.key];
          if (al == null || al > firstDanger) {
            alertMissed[v.key] = alertMissed[v.key]! + 1;
          } else {
            alertLeads[v.key]!.add(firstDanger - al);
          }
        }
        if (v13Missed(firstSound, firstDanger)) {
          missDetails.add({
            'along': a.s.round(),
            'otherAlong': boats.length > 1 ? boats[1].s.round() : null,
            'straightPredictionTicks': straightPredictionTicks,
            'alertAt': firstAlert['D13_L10'],
            'anySoundAt': firstAnySound['D13_L10'],
            'dangerAt': firstDanger,
          });
        }
      }
      out['${water.key}/${entry.key}'] = {
        'water': water.label,
        'runs': runs,
        'dangerRuns': dangerRuns,
        'wallSeconds': stopwatch.elapsed.inSeconds,
        'variants': {
          for (final v in variants)
            v.key: {
              'lead': _percentiles(leads[v.key]!),
              'notAlertedBeforeDanger': missed[v.key],
              // 何の音も鳴らないまま危険接近した数(別の対象の音も無い)。
              'noSoundAtAllBeforeDanger': silentMissed[v.key],
              // この相手への警告(音を出す提示)が立たないまま危険接近した数。
              // 立っていても別の音が鳴っていれば notAlertedBeforeDanger に入る。
              'noAudibleAlertBeforeDanger': alertMissed[v.key],
              'alertLead': _percentiles(alertLeads[v.key]!),
            },
        },
        'runsWithStraightPrediction': straightRuns,
        'lateOrMissedD13': missDetails.take(12).toList(),
      };
      // ignore: avoid_print
      print('done ${water.label} ${entry.key}: $dangerRuns/$runs '
          'in ${stopwatch.elapsed.inSeconds}s');
    }
  }
  return out;
}

BoatType _randomType(_Rng r) => _boatTypes[r.nextInt(_boatTypes.length)];

_Boat _scenarioBoat(String id, _Water w, _Rng r,
    {required double s, required int dir, double? speed, double? cross}) {
  final b =
      _Boat(id: id, type: _randomType(r), water: w, s: s, dir: dir, rng: r)
        ..plan.practice = false
        ..plan.fixedSpeed = speed
        ..plan.fixedCross = cross
        ..v = speed ?? 0
        ..spm = r.uniform(20, 30);
  if (cross != null) b.c = cross;
  return b;
}

/// 自艇 a(レーンを守って進む)と、正面から来る b。
/// b は a のレーン上を、横に [lateralOffset] ずれて逆向きに進む(逆走)。
(List<_Boat>, String?) _headOn(_Water w, _Rng r,
    {required double lateralOffset}) {
  final va = r.normal(2.9, 0.35), vb = r.normal(2.9, 0.35);
  final dirA = r.chance(.5) ? 1 : -1;
  final meetIn = r.uniform(45, 70);
  final gap = (va + vb) * meetIn;
  final sa = dirA > 0
      ? r.uniform(80, w.length - gap - 80)
      : r.uniform(gap + 80, w.length - 80);
  if (sa < 60 || sa > w.length - 60) return (const [], null);
  final laneA = w.laneAt(sa, dirA);
  final ca = (laneA.$1 + laneA.$2) / 2;
  final a = _scenarioBoat('a', w, r, s: sa, dir: dirA, speed: va, cross: ca);
  final b = _scenarioBoat('b', w, r,
      s: sa + dirA * gap, dir: -dirA, speed: vb, cross: ca + lateralOffset);
  return ([a, b], null);
}

/// a のレーン上に止まっている艇 b(カーブの先を含む)。
(List<_Boat>, String?) _stoppedInLane(_Water w, _Rng r) {
  final va = r.normal(3.0, 0.35);
  final dirA = r.chance(.5) ? 1 : -1;
  final gap = va * r.uniform(45, 70);
  final sa = dirA > 0
      ? r.uniform(80, w.length - gap - 80)
      : r.uniform(gap + 80, w.length - 80);
  if (sa < 60 || sa > w.length - 60) return (const [], null);
  final laneA = w.laneAt(sa, dirA);
  final ca = (laneA.$1 + laneA.$2) / 2;
  final a = _scenarioBoat('a', w, r, s: sa, dir: dirA, speed: va, cross: ca);
  final b = _scenarioBoat('b', w, r,
      s: sa + dirA * gap,
      dir: r.chance(.5) ? dirA : -dirA,
      speed: 0,
      cross: ca + r.uniform(-2, 2))
    ..plan.holdStill = true;
  return ([a, b], null);
}

/// 同じレーンを遅く進む b に、後ろから a が追いつく。
(List<_Boat>, String?) _overtaking(_Water w, _Rng r) {
  final va = r.normal(3.4, 0.2);
  final vb = va - r.uniform(0.7, 1.3);
  final dirA = r.chance(.5) ? 1 : -1;
  final gap = (va - vb) * r.uniform(40, 60);
  final travel = va * 75;
  final sa = dirA > 0
      ? r.uniform(80, w.length - travel - 80)
      : r.uniform(travel + 80, w.length - 80);
  if (sa < 60 || sa > w.length - 60) return (const [], null);
  final laneA = w.laneAt(sa, dirA);
  final ca = (laneA.$1 + laneA.$2) / 2;
  final a = _scenarioBoat('a', w, r, s: sa, dir: dirA, speed: va, cross: ca);
  final b = _scenarioBoat('b', w, r,
      s: sa + dirA * gap, dir: dirA, speed: vb, cross: ca + r.uniform(-2, 2));
  return ([a, b], null);
}

/// a の前方、a のレーン上で b が回頭している(その場で180度回る)。
(List<_Boat>, String?) _turningInLane(_Water w, _Rng r) {
  final va = r.normal(3.0, 0.35);
  final dirA = r.chance(.5) ? 1 : -1;
  final gap = va * r.uniform(45, 65);
  final sa = dirA > 0
      ? r.uniform(80, w.length - gap - 80)
      : r.uniform(gap + 80, w.length - 80);
  if (sa < 60 || sa > w.length - 60) return (const [], null);
  final laneA = w.laneAt(sa, dirA);
  final ca = (laneA.$1 + laneA.$2) / 2;
  final a = _scenarioBoat('a', w, r, s: sa, dir: dirA, speed: va, cross: ca);
  final b = _scenarioBoat('b', w, r,
      s: sa + dirA * gap, dir: -dirA, speed: 0, cross: ca + r.uniform(-2, 2));
  b.plan.practice = true; // 回頭の動きだけ使う
  b.phase = _Phase.turning;
  b.phaseUntil = 1e9;
  return ([a, b], null);
}

/// a の進路の先に橋脚がある(レーンを守ったまま橋脚へ向かう)。
(List<_Boat>, String?) _pierApproach(_Water w, _Rng r, _World world) {
  final piers = world.obstacles
      .where((o) => o.kind == StaticObstacleKind.bridgePier)
      .where((o) {
    final f = w.centerline.project(o.points.first);
    return f.isInsideCoverage && f.crossMeters.abs() < 40;
  }).toList();
  if (piers.isEmpty) return (const [], null);
  final pier = piers[r.nextInt(piers.length)];
  final center = LatLng(
    pier.points.map((p) => p.latitude).reduce((a, b) => a + b) /
        pier.points.length,
    pier.points.map((p) => p.longitude).reduce((a, b) => a + b) /
        pier.points.length,
  );
  final f = w.centerline.project(center);
  final va = r.normal(3.0, 0.35);
  final dirA = r.chance(.5) ? 1 : -1;
  final sa = f.alongMeters - dirA * va * r.uniform(45, 70);
  if (sa < 40 || sa > w.length - 40) return (const [], null);
  final a = _scenarioBoat('a', w, r,
      s: sa, dir: dirA, speed: va, cross: f.crossMeters + r.uniform(-1.5, 1.5));
  return ([a], pier.id);
}
