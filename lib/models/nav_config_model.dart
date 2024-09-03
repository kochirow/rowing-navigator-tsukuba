import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/types/boat_type.dart';

class NavConfig {
  final String _boatId;
  final BoatType _boatType;
  final SeatPosition _seatPos;
  final LocationAccuracy _accuracy;
  static final init = NavConfig(
    boatId: 'init',
    boatType: BoatType.r_1x,
    seatPos: SeatPosition(label: 'init', position: 0),
    accuracy: LocationAccuracy.bestForNavigation,
  );

  String get boatId => _boatId;
  BoatType get boatType => _boatType;
  SeatPosition get seatPos => _seatPos;
  LocationAccuracy get accuracy => _accuracy;

  NavConfig({
    required String boatId,
    required BoatType boatType,
    required SeatPosition seatPos,
    required LocationAccuracy accuracy,
  })  : _boatId = boatId,
        _boatType = boatType,
        _seatPos = seatPos,
        _accuracy = accuracy;
}
