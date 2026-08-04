import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/boat_model.dart';
import '../utils/geo_math.dart';
import 'channel_centerline.dart';
import 'channel_path_predictor.dart';

/// 自艇・他艇から前方へ伸びる「止まれない距離」のビーム(純Dart)。
///
/// **表示専用。** ここで作る形は安全判定にも他艇へも一切渡らない。
/// 判定は従来どおり [ChannelPathPredictor] の区間を連続掃引(SAT)へ渡す
/// 経路で行い、この描画が失敗しても警告は一切変わらない(不変条件4)。
class BoatPredictionBeam {
  /// 閉じたテーパー多角形。艇の位置で最も広く、先端へ向かって細くなる。
  final List<LatLng> outline;

  /// ビームの長さ [m]。= 停止距離。ログと表示の説明に使う。
  final double lengthMeters;

  const BoatPredictionBeam({
    required this.outline,
    required this.lengthMeters,
  });
}

/// ビーム先端の幅が、艇の位置での幅に対して占める割合。
///
/// 0にすると尖った三角形になり、地図上では先端が消えて長さが読めなくなる。
/// 少し残して「細くなっていく帯」に見せる。
const double _beamTipWidthFraction = 0.3;

/// これ未満の長さなら描かない [m]。
///
/// 停止中や極低速では、ごく短いビームが艇印と重なって団子になる。
/// 出さないほうが読みやすい。
const double _beamMinimumLengthMeters = 3.0;

/// 帯が「帯」に見える最小の縦横比(長さ ÷ 根元の幅)。
///
/// **根元の幅を排他領域の幅で固定してはいけない。** 長さは停止距離
/// (速度に比例)なのに幅が固定だと、遅いときに幅が長さを追い越し、
/// 先細りの帯ではなく**すぼまった器**に見える。実機では
/// 0.9m/s(9:28/500m)で長さ6.1mに対して幅9mとなり、方向が読めなかった。
///
/// 根元の幅を `長さ ÷ この値` で頭打ちにすると、遅くなるほど帯が細く
/// なるだけで、形の意味は変わらない。**閾値で消えたり現れたりしない**
/// のも大事で、境目で図形が明滅すると、そのこと自体が読み取りを乱す。
///
/// 通常の漕行速度(4m/s、停止距離27.8m)では 27.8/2.5 = 11.1m > 9m なので
/// 頭打ちに掛からず、根元は艇の幅のままになる。効くのは低速のときだけ。
const double _beamMinimumAspectRatio = 2.5;

/// 折れ線を作るときの最小分割数。カーブでもテーパーが滑らかに見える程度。
const int _beamMinimumSamples = 6;

/// 「いま止まろうとしても、ここまでは行ってしまう」範囲を作る。
///
/// ## なぜ線ではなく先細りの帯なのか
///
/// 初版は「均一な太さの折れ線 + 停止距離の位置に横棒」だった。実機で
/// **「何を示している図なのか分からない」**という判断で作り直した。
///
///   1. **均一な太さの線は方向を伝えない。** 経路可視化の比較研究では、
///      先細り(tapered)の帯が経路の向きを伝える性能で他を上回る。
///      線はどちらが起点かを形で示せず、艇印との位置関係を毎回読み直す
///      ことになる。
///   2. **横棒1本には意味の手がかりが無い。** 「止まれる距離」という
///      読み方は、記号を覚えていないと出てこない。
///   3. Google マップの位置ビーム(懐中電灯の比喩)が広く理解されるのは、
///      精度が高いからではなく**比喩が身についているから**である。
///      「前へ光が伸びている」は説明が要らない。
///
/// そこで**図形を1つに減らし、その長さ自体に意味を持たせた**。
/// ビームの長さ = 停止距離なので、横棒で位置を指す必要がない。
/// 図が伝えるのは1文だけ:「いま止まろうとしても、ここまでは行く」。
///
/// 幅は排他領域の幅から始めて先端で [_beamTipWidthFraction] まで絞る。
/// 根元の幅が艇の占める幅と一致するので、帯が艇から生えて見える。
///
/// **長さに予測地平(10秒)を使わない。** 10秒先は「app が何秒先まで見て
/// いるか」という内部事情であって、漕手が行動に移せる量ではない。
/// 停止距離は物理量で、艇を止める判断に直結する。
BoatPredictionBeam? buildBoatPredictionBeam({
  required Boat boat,
  required double stoppingDistanceMeters,
  required double halfWidthMeters,
  ChannelCenterline? centerline,
  ChannelPathPredictor predictor = const ChannelPathPredictor(),
}) {
  if (!boat.lat.isFinite ||
      !boat.lng.isFinite ||
      boat.lat.abs() > 90 ||
      boat.lng.abs() > 180) {
    return null;
  }
  if (!halfWidthMeters.isFinite || halfWidthMeters <= 0) return null;
  if (!stoppingDistanceMeters.isFinite ||
      stoppingDistanceMeters < _beamMinimumLengthMeters) {
    return null;
  }
  final speed = boat.speed.isFinite && boat.speed > 0 ? boat.speed : 0.0;
  if (speed <= 0) return null;

  // 予測地平を「停止するまでの時間」にすると、経路の全長がそのまま
  // 停止距離になる。中心線があれば川なりに曲がる。
  final segments = predictor.predict(
    boat: boat,
    horizonSeconds: stoppingDistanceMeters / speed,
    centerline: centerline,
  );
  if (segments.isEmpty) return null;

  // 経路上の点・その点での進行方位・始点からの累積距離を集める。
  //
  // 1区間が長いと、テーパーが折れ線の節でしか変わらず角ばって見える。
  // 区間を等分して、幅が滑らかに絞られるようにする。
  final centers = <LatLng>[segments.first.origin];
  final headings = <double>[];
  final cumulative = <double>[0];
  var total = 0.0;
  final stepsPerSegment =
      math.max(1, (_beamMinimumSamples / segments.length).ceil());
  for (final segment in segments) {
    final length = segment.lengthMeters;
    if (!length.isFinite || length <= 0) continue;
    final stepLength = length / stepsPerSegment;
    for (var step = 0; step < stepsPerSegment; step++) {
      centers.add(computeOffset(
        centers.last,
        stepLength,
        segment.headingDegrees,
      ));
      headings.add(segment.headingDegrees);
      total += stepLength;
      cumulative.add(total);
    }
  }
  if (centers.length < 2 || total < _beamMinimumLengthMeters) return null;
  // 方位は辺ごとに1つなので、先頭の点には最初の辺の方位を使う。
  headings.insert(0, headings.first);

  // 根元の幅は「艇の幅」と「長さ ÷ 最小縦横比」の小さいほう。
  // 遅いときに幅が長さを追い越して器のように見えるのを防ぐ。
  final rootHalfWidth = math.min(
    halfWidthMeters,
    total / (2 * _beamMinimumAspectRatio),
  );

  final left = <LatLng>[];
  final right = <LatLng>[];
  for (var index = 0; index < centers.length; index++) {
    final progress = (cumulative[index] / total).clamp(0.0, 1.0);
    final halfWidth =
        rootHalfWidth * (1 - progress * (1 - _beamTipWidthFraction));
    final heading = headings[index];
    left.add(computeOffset(centers[index], halfWidth, heading - 90));
    right.add(computeOffset(centers[index], halfWidth, heading + 90));
  }

  return BoatPredictionBeam(
    outline: [...left, ...right.reversed],
    lengthMeters: total,
  );
}
