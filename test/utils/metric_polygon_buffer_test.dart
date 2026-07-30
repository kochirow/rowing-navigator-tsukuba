import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/utils/geo_math.dart';
import 'package:rowing_navigator/utils/metric_polygon_buffer.dart';

void main() {
  const buffer = MetricPolygonBuffer();

  test('矩形の各辺を指定した5mだけ外側へ広げる', () {
    const source = [
      LatLng(36.0750, 140.2050),
      LatLng(36.0750, 140.2052),
      LatLng(36.0752, 140.2052),
      LatLng(36.0752, 140.2050),
    ];

    final expanded = buffer.expand(source, 5);
    final sourceSouth =
        source.map((point) => point.latitude).reduce((a, b) => a < b ? a : b);
    final sourceNorth =
        source.map((point) => point.latitude).reduce((a, b) => a > b ? a : b);
    final sourceWest =
        source.map((point) => point.longitude).reduce((a, b) => a < b ? a : b);
    final sourceEast =
        source.map((point) => point.longitude).reduce((a, b) => a > b ? a : b);
    final expandedSouth =
        expanded.map((point) => point.latitude).reduce((a, b) => a < b ? a : b);
    final expandedNorth =
        expanded.map((point) => point.latitude).reduce((a, b) => a > b ? a : b);
    final expandedWest = expanded
        .map((point) => point.longitude)
        .reduce((a, b) => a < b ? a : b);
    final expandedEast = expanded
        .map((point) => point.longitude)
        .reduce((a, b) => a > b ? a : b);

    expect(
      distanceMeters(
        LatLng(sourceSouth, sourceWest),
        LatLng(expandedSouth, sourceWest),
      ),
      closeTo(5, 0.08),
    );
    expect(
      distanceMeters(
        LatLng(sourceNorth, sourceEast),
        LatLng(expandedNorth, sourceEast),
      ),
      closeTo(5, 0.08),
    );
    expect(
      distanceMeters(
        LatLng(sourceSouth, sourceWest),
        LatLng(sourceSouth, expandedWest),
      ),
      closeTo(5, 0.08),
    );
    expect(
      distanceMeters(
        LatLng(sourceNorth, sourceEast),
        LatLng(sourceNorth, expandedEast),
      ),
      closeTo(5, 0.08),
    );
  });

  test('時計回りの頂点順でも外側へ広げる', () {
    const clockwise = [
      LatLng(36.0750, 140.2050),
      LatLng(36.0752, 140.2050),
      LatLng(36.0752, 140.2052),
      LatLng(36.0750, 140.2052),
    ];

    final expanded = buffer.expand(clockwise, 5);

    expect(
      expanded.map((point) => point.latitude).reduce((a, b) => a < b ? a : b),
      lessThan(36.0750),
    );
    expect(
      expanded.map((point) => point.longitude).reduce((a, b) => a > b ? a : b),
      greaterThan(140.2052),
    );
  });

  test('細長い矩形でも長辺と短辺の両方から指定距離を確保する', () {
    const source = [
      LatLng(36.075000, 140.205000),
      LatLng(36.075000, 140.206100),
      LatLng(36.075018, 140.206100),
      LatLng(36.075018, 140.205000),
    ];
    const marginMeters = 7.5;

    final expanded = buffer.expand(source, marginMeters);
    final sourceSouth =
        source.map((point) => point.latitude).reduce((a, b) => a < b ? a : b);
    final sourceNorth =
        source.map((point) => point.latitude).reduce((a, b) => a > b ? a : b);
    final sourceWest =
        source.map((point) => point.longitude).reduce((a, b) => a < b ? a : b);
    final sourceEast =
        source.map((point) => point.longitude).reduce((a, b) => a > b ? a : b);
    final expandedSouth =
        expanded.map((point) => point.latitude).reduce((a, b) => a < b ? a : b);
    final expandedNorth =
        expanded.map((point) => point.latitude).reduce((a, b) => a > b ? a : b);
    final expandedWest = expanded
        .map((point) => point.longitude)
        .reduce((a, b) => a < b ? a : b);
    final expandedEast = expanded
        .map((point) => point.longitude)
        .reduce((a, b) => a > b ? a : b);
    final middleLatitude = (sourceSouth + sourceNorth) / 2;
    final middleLongitude = (sourceWest + sourceEast) / 2;

    // 約100mの長辺からの余白。
    expect(
      distanceMeters(
        LatLng(sourceNorth, middleLongitude),
        LatLng(expandedNorth, middleLongitude),
      ),
      closeTo(marginMeters, 0.08),
    );
    expect(
      distanceMeters(
        LatLng(sourceSouth, middleLongitude),
        LatLng(expandedSouth, middleLongitude),
      ),
      closeTo(marginMeters, 0.08),
    );
    // 約2mの短辺からの余白。重心放射拡大ではこの値を保証できない。
    expect(
      distanceMeters(
        LatLng(middleLatitude, sourceEast),
        LatLng(middleLatitude, expandedEast),
      ),
      closeTo(marginMeters, 0.08),
    );
    expect(
      distanceMeters(
        LatLng(middleLatitude, sourceWest),
        LatLng(middleLatitude, expandedWest),
      ),
      closeTo(marginMeters, 0.08),
    );
  });

  test('0mは重複した終端点だけを除いて形状を維持する', () {
    const source = [
      LatLng(36.0750, 140.2050),
      LatLng(36.0750, 140.2052),
      LatLng(36.0752, 140.2052),
      LatLng(36.0750, 140.2050),
    ];

    expect(buffer.expand(source, 0), source.take(3).toList());
  });
}
