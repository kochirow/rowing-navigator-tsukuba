import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/types/boat_type.dart';

import 'message_model.dart';

class Boat {
  String _boatId;
  BoatType _boatType;
  double _lat;
  double _lng;
  double _heading;
  DateTime _timestamp;

  static final init = Boat(
    boatId: 'init',
    boatType: BoatType.r_1x,
    lat: 35.681236,
    lng: 139.767125,
    heading: 0,
    timestamp: DateTime.now(),
  );

  String get boatId => _boatId;
  BoatType get boatType => _boatType;
  double get lat => _lat;
  double get lng => _lng;
  double get heading => _heading;
  DateTime get timestamp => _timestamp;

  Boat({
    required String boatId,
    required BoatType boatType,
    required double lat,
    required double lng,
    required double heading,
    required DateTime timestamp,
  })  : _boatId = boatId,
        _boatType = boatType,
        _lat = lat,
        _lng = lng,
        _heading = heading,
        _timestamp = timestamp;

  Message toMessage() {
    final m = Message(
      boatId: init.boatId,
      boatType: init.boatType,
      lat: init.lat,
      lng: init.lng,
      heading: init.heading,
      timestamp: init.timestamp,
    );
    return m;
  }

  factory Boat.fromMessage(Message message) {
    final b = Boat(
      boatId: message.boatId,
      boatType: message.boatType,
      lat: message.lat,
      lng: message.lng,
      heading: message.heading,
      timestamp: message.timestamp,
    );
    return b;
  }

  static double getSeatOffset(BoatType type, SeatPosition pos) {
    final seatCount = boatConfigs.byBoatType(type).seatPosList.length;
    final seatIndex = pos.position; // 船首側からの座席位置
    final offset = ((seatCount - 2 * seatIndex + 1) / 2) *
        seatSpan; // 艇の中心を原点とし船首方向を正とする座標系での座席位置
    return offset;
  }
}
