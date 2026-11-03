import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/features/home_map/area_outline_lines.dart';
import 'package:rowing_navigator/models/harbor_area.dart';
import 'package:rowing_navigator/models/mooring_area.dart';
import 'package:rowing_navigator/theme/map_layer_spec.dart';

void main() {
  const square = [
    LatLng(36.0810, 140.2130),
    LatLng(36.0810, 140.2180),
    LatLng(36.0830, 140.2180),
  ];

  test('桟橋エリアと港の中を、塗らない破線の輪郭(縁取りと芯の2本)で描く', () {
    final lines = areaOutlinePolylines(
      mooringAreas: const [MooringArea(id: 'm', name: '桟橋', points: square)],
      harborAreas: const [HarborArea(id: 'h', name: '港', points: square)],
      isSatellite: false,
    );
    final ids = lines.map((line) => line.polylineId.value).toSet();
    expect(ids, {
      'mooring_area_casing_m',
      'mooring_area_core_m',
      'harbor_area_casing_h',
      'harbor_area_core_h',
    });
    for (final line in lines) {
      // 輪郭を閉じる(最初の点へ戻る)。
      expect(line.points.first, line.points.last);
      expect(line.patterns, isNotEmpty, reason: '破線でない');
      expect(line.consumeTapEvents, isFalse);
    }
    final harborCore = lines
        .firstWhere((line) => line.polylineId.value == 'harbor_area_core_h');
    expect(harborCore.zIndex, harborAreaZIndex);
  });

  test('3点未満の区域は描かない', () {
    final lines = areaOutlinePolylines(
      mooringAreas: const [],
      harborAreas: const [
        HarborArea(
            id: 'h', name: '港', points: [LatLng(36, 140), LatLng(36.001, 140)])
      ],
      isSatellite: true,
    );
    expect(lines, isEmpty);
  });
}
