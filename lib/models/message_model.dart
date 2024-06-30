import '../models/boat_model.dart';

class Message {
  String _boatId;
  int _boatType;
  int _seatPos;
  double _lat;
  double _lng;
  double _heading;
  DateTime _timestamp;

  Message({
    required String boatId,
    required int boatType,
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

  String get boatId => _boatId;
  int get boatType => _boatType;
  int get seatPos => _seatPos;
  double get lat => _lat;
  double get lng => _lng;
  double get heading => _heading;
  DateTime get timestamp => _timestamp;

  Map<String, dynamic> toJson() {
    return {
      'boatId': _boatId,
      'boatType': _boatType,
      'seatPos': _seatPos,
      'lat': _lat,
      'lng': _lng,
      'heading': _heading,
      'timestamp': _timestamp,
    };
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      boatId: json['boatId'],
      boatType: json['boatType'],
      seatPos: json['seatPos'],
      lat: json['lat'],
      lng: json['lng'],
      heading: json['heading'],
      timestamp: json['timestamp'].toDate(),
    );
  }

  factory Message.fromBoat(Boat boat) {
    return Message(
      boatId: boat.boatId,
      boatType: boat.boatType,
      seatPos: boat.seatPos,
      lat: boat.lat,
      lng: boat.lng,
      heading: boat.heading,
      timestamp: boat.timestamp,
    );
  }
}
