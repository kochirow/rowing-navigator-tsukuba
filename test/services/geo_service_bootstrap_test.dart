import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/services/geo_service.dart';

Position _position() => Position(
      latitude: 36.08,
      longitude: 140.2,
      timestamp: DateTime.utc(2026, 9, 26),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  // 初回位置が無いことを理由に航行開始を止めない(原則1・不変条件5)。
  test('OSの最後の位置があればそれを航行開始の足掛かりにする', () async {
    final last = _position();
    final service = GeoService(lastKnownPosition: () async => last);
    expect(await service.getNavigationBootstrapPosition(), same(last));
  });

  test('位置が1つも無ければ、新しい測位を待たずに null を返す', () async {
    final service = GeoService(lastKnownPosition: () async => null);
    expect(await service.getNavigationBootstrapPosition(), isNull);
  });

  test('OSの最後の位置の取得が失敗しても例外を出さず null を返す', () async {
    final service = GeoService(
      lastKnownPosition: () async => throw Exception('位置サービス停止'),
    );
    expect(await service.getNavigationBootstrapPosition(), isNull);
  });
}
