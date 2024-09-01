import 'package:rowing_navigator/types/boat_type.dart';

import 'message_model.dart';

class Boat {
  String _boatId;
  BoatType _boatType;
  int _seatPos; // 要enum定義
  double _lat;
  double _lng;
  double _heading;
  DateTime _timestamp;
  static final init = Boat(
    boatId: 'init',
    boatType: BoatType.r_1x,
    seatPos: 0,
    lat: 35.681236,
    lng: 139.767125,
    heading: 0,
    timestamp: DateTime.now(),
  );

  String get boatId => _boatId;
  BoatType get boatType => _boatType;
  int get seatPos => _seatPos;
  double get lat => _lat;
  double get lng => _lng;
  double get heading => _heading;
  DateTime get timestamp => _timestamp;

  Boat({
    required String boatId,
    required BoatType boatType,
    required int seatPos,
    required double lat,
    required double lng,
    required double heading,
    required DateTime timestamp,
  })  : _boatId = boatId,
        _boatType = boatType,
        _seatPos = seatPos,
        _lat = lat,
        _lng = lng,
        _heading = heading,
        _timestamp = timestamp;

  Message toMessage() {
    final m = Message(
      boatId: init.boatId,
      boatType: init.boatType,
      seatPos: init.seatPos,
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
      seatPos: message.seatPos,
      lat: message.lat,
      lng: message.lng,
      heading: message.heading,
      timestamp: message.timestamp,
    );
    return b;
  }
}
