import 'package:geolocator/geolocator.dart';

class NavConfig {
  final String _boatId;
  final int _boatType;
  final int _seatPos; // 要enum定義
  final LocationAccuracy _accuracy;
  static final init = NavConfig(
    boatId: 'init',
    boatType: 0,
    seatPos: 0,
    accuracy: LocationAccuracy.bestForNavigation,
  );

  String get boatId => _boatId;
  int get boatType => _boatType;
  int get seatPos => _seatPos;
  LocationAccuracy get accuracy => _accuracy;

  NavConfig({
    required String boatId,
    required int boatType,
    required int seatPos,
    required LocationAccuracy accuracy,
  })  : _boatId = boatId,
        _boatType = boatType,
        _seatPos = seatPos,
        _accuracy = accuracy;
}
