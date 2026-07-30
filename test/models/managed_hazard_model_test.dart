import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/managed_hazard_model.dart';
import 'package:rowing_navigator/utils/geo_math.dart';

void main() {
  const base = [
    LatLng(36.075432, 140.21382),
    LatLng(36.075152, 140.21382),
    LatLng(36.075267, 140.21482),
    LatLng(36.075354, 140.21500),
    LatLng(36.075431, 140.21481),
    LatLng(36.075432, 140.21382),
  ];
  const transformer = ManagedHazardTransformer();

  test('固定流木の重複した閉じ点を除き1ポリゴンにする', () {
    final state = ManagedHazardState.forBaseShape(base);
    final transformed = transformer.transform(base, state);
    expect(transformed, hasLength(5));
    expect(distanceMeters(transformed.first, transformed.last), greaterThan(1));
  });

  test('中心の移動と長さ・幅・回転を小さな変形値で再現できる', () {
    final initial = ManagedHazardState.forBaseShape(base);
    final moved = initial.copyWith(
      center: const LatLng(36.0755, 140.2145),
      lengthScale: 1.2,
      widthScale: 0.8,
      rotationDegrees: 15,
      outwardMarginMeters: 2,
    );
    final transformed = transformer.transform(base, moved);
    final meanLat = transformed.map((p) => p.latitude).reduce((a, b) => a + b) /
        transformed.length;
    final meanLng =
        transformed.map((p) => p.longitude).reduce((a, b) => a + b) /
            transformed.length;
    expect(meanLat, closeTo(moved.center.latitude, 0.00001));
    expect(meanLng, closeTo(moved.center.longitude, 0.00001));
  });

  test('危険な過大スケールは拒否する', () {
    final initial = ManagedHazardState.forBaseShape(base);
    expect(
      () => initial.copyWith(lengthScale: 10).validate(),
      throwsFormatException,
    );
  });

  test('固定流木を桜川の許可範囲外へ移動できない', () {
    final initial = ManagedHazardState.forBaseShape(base);
    expect(
      () => initial.copyWith(center: const LatLng(35.0, 139.0)).validate(),
      throwsFormatException,
    );
  });
}
