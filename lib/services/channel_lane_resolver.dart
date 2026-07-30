import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/channel_lane.dart';
import '../utils/winding_algorithm.dart';

/// 現在位置を、検証済みの航路レーンの規定進行方向へ解決する。
///
/// レーン間の隙間・重なり・レーン不在はすべて `null` にする。誤った
/// 180度反転より「この位置では判定しない」を選ぶための最後の安全弁である。
class ChannelLaneResolver {
  final List<ChannelLane> _lanes;

  ChannelLaneResolver(Iterable<ChannelLane> lanes)
      : _lanes = List.unmodifiable(lanes);

  /// ポリゴン内包方式を有効にするために必要な、2枚以上のレーンがあるか。
  ///
  /// 1枚だけのプロファイルは不完全なので、呼出側は従来の `cross` 符号方式へ
  /// 縮退する。
  bool get hasCompleteLaneSet => _lanes.length >= 2;

  /// 自艇位置から、その位置での規定進行方向を決める。
  ///
  /// レーンが無い・どのレーンにも入っていない・複数のレーンが重なる場合は
  /// `null` を返す。
  LaneDirection? resolve(LatLng position) {
    ChannelLane? match;
    for (final lane in _lanes) {
      if (!isPointInPolygon(position, lane.points)) continue;
      if (match != null) return null;
      match = lane;
    }
    return match?.direction;
  }
}
