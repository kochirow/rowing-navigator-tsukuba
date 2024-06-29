import 'package:cloud_firestore/cloud_firestore.dart';

class Boat {
  String _boatId;
  int _boatType;
  int _seatPos; // 要enum定義
  double _lat;
  double _lng;
  double _heading;
  DateTime _timestamp;

  String get boatId => _boatId;
  int get boatType => _boatType;
  int get seatPos => _seatPos;
  double get lat => _lat;
  double get lng => _lng;
  double get heading => _heading;
  DateTime get timestamp => _timestamp;

  Boat({
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

  factory Boat.fromJson(Map<String, dynamic> json) {
    final b = Boat(
      boatId: json['boatId'],
      boatType: json['boatType'],
      seatPos: json['seatPos'],
      lat: json['lat'],
      lng: json['lng'],
      heading: json['heading'],
      timestamp: json['timestamp'],
    );
    return b;
  }
}
