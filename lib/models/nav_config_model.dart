import 'package:geolocator/geolocator.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/types/boat_type.dart';

class NavConfig {
  final String _boatId;
  final String _displayName;
  final BoatType _boatType;
  final SeatPosition _seatPos;
  final LocationAccuracy _accuracy;
  final bool _strokeRateEnabled;
  static final init = NavConfig(
    boatId: 'init',
    displayName: '名前未設定',
    boatType: BoatType.r_1x,
    seatPos: boatConfigs.r_1x.seatPosList[0],
    accuracy: LocationAccuracy.bestForNavigation,
    strokeRateEnabled: false,
  );

  String get boatId => _boatId;
  String get displayName => _displayName;
  BoatType get boatType => _boatType;
  SeatPosition get seatPos => _seatPos;
  LocationAccuracy get accuracy => _accuracy;
  bool get strokeRateEnabled => _strokeRateEnabled;

  NavConfig({
    required String boatId,
    required String displayName,
    required BoatType boatType,
    required SeatPosition seatPos,
    required LocationAccuracy accuracy,
    bool strokeRateEnabled = false,
  })  : _boatId = boatId,
        _displayName = displayName,
        _boatType = boatType,
        _seatPos = seatPos,
        _accuracy = accuracy,
        _strokeRateEnabled = strokeRateEnabled;
}
