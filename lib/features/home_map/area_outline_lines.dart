import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/harbor_area.dart';
import '../../models/mooring_area.dart';
import '../../services/preset_obstacle_service.dart';
import '../../theme/map_layer_spec.dart';

/// 桟橋エリアと港の中の輪郭(破線)を地図に描く線。**表示専用。**
///
/// どちらも危険区域ではなく「ここは港」という宣言なので、**塗らない**
/// (塗り = 実在する危険、の対応を崩さない。`map_layer_spec.dart`)。
/// 音を控えめにする判断は、同じプロファイルを `use_navigator` が独立に読んで行う。
/// 読めなければ描かないだけで、航行も警告も従来どおり動く(原則1)。
Set<Polyline> useAreaOutlineLines({required bool isSatellite}) {
  final mooring = useState<List<MooringArea>>(const []);
  final harbor = useState<List<HarborArea>>(const []);
  useEffect(() {
    var disposed = false;
    final service = PresetObstacleService();
    unawaited(service.loadMooringAreas().then((areas) {
      if (!disposed) mooring.value = areas;
    }).catchError((Object error) {
      if (kDebugMode) debugPrint('Mooring areas not displayed: $error');
    }));
    unawaited(service.loadHarborAreas().then((areas) {
      if (!disposed) harbor.value = areas;
    }).catchError((Object error) {
      if (kDebugMode) debugPrint('Harbor areas not displayed: $error');
    }));
    return () => disposed = true;
  }, const []);
  return useMemoized(
    () => areaOutlinePolylines(
      mooringAreas: mooring.value,
      harborAreas: harbor.value,
      isSatellite: isSatellite,
    ),
    [mooring.value, harbor.value, isSatellite],
  );
}

/// 輪郭の線を作る。縁取りと芯の2本で1本の破線にする(中央線と同じ描き方)。
@visibleForTesting
Set<Polyline> areaOutlinePolylines({
  required List<MooringArea> mooringAreas,
  required List<HarborArea> harborAreas,
  required bool isSatellite,
}) {
  final lines = <Polyline>{};
  void addRing({
    required String idPrefix,
    required String id,
    required List<LatLng> points,
    required MooringAreaStyle style,
    required int zIndex,
  }) {
    if (points.length < 3) return;
    final pattern = <PatternItem>[
      PatternItem.dash(style.dashLengthPixels.toDouble()),
      PatternItem.gap(style.gapLengthPixels.toDouble()),
    ];
    // ポリゴンではなくポリラインで閉じる。塗りを持たせないため。
    final ring = <LatLng>[...points, points.first];
    lines.add(Polyline(
      polylineId: PolylineId('${idPrefix}_casing_$id'),
      points: ring,
      color: style.casingColor,
      width: style.casingWidth,
      patterns: pattern,
      zIndex: zIndex,
      consumeTapEvents: false,
    ));
    lines.add(Polyline(
      polylineId: PolylineId('${idPrefix}_core_$id'),
      points: ring,
      color: style.coreColor,
      width: style.coreWidth,
      patterns: pattern,
      zIndex: zIndex,
      consumeTapEvents: false,
    ));
  }

  final harborStyle = harborAreaStyleFor(isSatellite: isSatellite);
  for (final area in harborAreas) {
    addRing(
      idPrefix: 'harbor_area',
      id: area.id,
      points: area.points,
      style: harborStyle,
      zIndex: harborAreaZIndex,
    );
  }
  final mooringStyle = mooringAreaStyleFor(isSatellite: isSatellite);
  for (final area in mooringAreas) {
    addRing(
      idPrefix: 'mooring_area',
      id: area.id,
      points: area.points,
      style: mooringStyle,
      zIndex: mooringAreaZIndex,
    );
  }
  return lines;
}
