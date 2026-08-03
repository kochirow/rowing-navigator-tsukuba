import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/channel_lane.dart';
import '../utils/winding_algorithm.dart';
import 'channel_centerline.dart';

/// 現在位置を、検証済みの航路レーンの規定進行方向へ解決する。
///
/// レーン間の隙間・重なり・レーン不在はすべて `null` にする。誤った
/// 180度反転より「この位置では判定しない」を選ぶための最後の安全弁である。
class ChannelLaneResolver {
  final List<ChannelLane> _lanes;
  final Map<String, ChannelCenterline> _centerlines;

  ChannelLaneResolver(
    Iterable<ChannelLane> lanes, {
    Map<String, ChannelCenterline> centerlines = const {},
  })  : _lanes = List.unmodifiable(lanes),
        _centerlines = Map.unmodifiable(centerlines);

  /// ポリゴン内包方式を有効にするために必要な、2枚以上のレーンがあるか。
  ///
  /// 1枚だけのプロファイルは不完全なので、呼出側は従来の `cross` 符号方式へ
  /// 縮退する。
  bool get hasCompleteLaneSet => hasLinkedCenterlines || _lanes.length >= 2;

  /// レーンと中心線の明示的な関連を使えるか。
  ///
  /// 一部だけ紐付いた移行途中データで旧逆走区域を止めないよう、全レーンの
  /// 参照が解決できる場合だけtrueにする。
  bool get hasLinkedCenterlines =>
      _lanes.isNotEmpty &&
      _lanes.every(
        (lane) =>
            lane.centerlineId != null &&
            _centerlines.containsKey(lane.centerlineId),
      );

  /// 自艇位置から、その位置での規定進行方向を決める。
  ///
  /// レーンが無い・どのレーンにも入っていない・複数のレーンが重なる場合は
  /// `null` を返す。
  ChannelLane? resolveLane(LatLng position) {
    ChannelLane? match;
    for (final lane in _lanes) {
      if (!isPointInPolygon(position, lane.points)) continue;
      if (match != null) return null;
      match = lane;
    }
    return match;
  }

  LaneDirection? resolve(LatLng position) => resolveLane(position)?.direction;

  /// 現在位置を含むレーンに紐付いた中心線を返す。
  ///
  /// レーン外・重複・参照切れはnull。別水域の中心線を「近そうだから」と
  /// 推測採用すると規定方位が反転しうるため、明示参照だけを使う。
  ChannelCenterline? centerlineFor(LatLng position) {
    final centerlineId = resolveLane(position)?.centerlineId;
    return centerlineId == null ? null : _centerlines[centerlineId];
  }
}
