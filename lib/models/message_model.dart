import '../models/boat_model.dart';
import '../types/boat_type.dart';

class Message {
  String _boatId;
  BoatType _boatType;
  double _lat;
  double _lng;
  double _heading;
  double _speed;
  DateTime _timestamp;

  Message({
    required String boatId,
    required BoatType boatType,
    required double lat,
    required double lng,
    required double heading,
    required double speed,
    required DateTime timestamp,
  })  : _boatId = boatId,
        _boatType = boatType,
        _lat = lat,
        _lng = lng,
        _heading = heading,
        _speed = speed,
        _timestamp = timestamp;

  String get boatId => _boatId;
  BoatType get boatType => _boatType;
  double get lat => _lat;
  double get lng => _lng;
  double get heading => _heading;
  double get speed => _speed;
  DateTime get timestamp => _timestamp;

  Map<String, dynamic> toJson() {
    return {
      'boatId': _boatId,
      'boatType': _boatType.toString().split('.').last,
      'lat': _lat,
      'lng': _lng,
      'heading': _heading,
      'speed': _speed,
      'timestamp': _timestamp,
    };
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      boatId: json['boatId'],
      boatType: BoatType.values
              .any((elm) => elm.toString().split('.').last == json['boatType'])
          ? BoatType.values.byName(json['boatType'])
          : BoatType.r_1x, // 艇種の識別子が不正な場合は1xとする
      lat: json['lat'].toDouble(),
      lng: json['lng'].toDouble(),
      heading: json['heading'].toDouble(),
      speed: json['speed'].toDouble(),
      timestamp: json['timestamp'].toDate(),
    );
  }
}
