import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/config/display_name_config.dart';
import 'package:rowing_navigator/types/boat_type.dart';

import 'message_model.dart';

class Boat {
  String _boatId;
  String _displayName;
  BoatType _boatType;
  double _lat;
  double _lng;
  double _heading;
  double _speed;
  DateTime _timestamp;
  int? _battery; // 電池残量 [%]
  double? _accuracy; // GPS推定誤差半径 [m](取得できない場合はnull)
  String? _sessionId;
  DateTime? _serverUpdatedAt;

  static final init = Boat(
    boatId: 'init',
    boatType: BoatType.r_1x,
    lat: 35.681236,
    lng: 139.767125,
    heading: 0,
    speed: 0,
    timestamp: DateTime.now(),
  );

  String get boatId => _boatId;
  String get displayName => _displayName;
  BoatType get boatType => _boatType;
  double get lat => _lat;
  double get lng => _lng;
  double get heading => _heading;
  double get speed => _speed;
  DateTime get timestamp => _timestamp;
  int? get battery => _battery;
  double? get accuracy => _accuracy;
  String? get sessionId => _sessionId;
  DateTime? get serverUpdatedAt => _serverUpdatedAt;

  Boat({
    required String boatId,
    String displayName = fallbackDisplayName,
    required BoatType boatType,
    required double lat,
    required double lng,
    required double heading,
    required double speed,
    required DateTime timestamp,
    int? battery,
    double? accuracy,
    String? sessionId,
    DateTime? serverUpdatedAt,
  })  : _boatId = boatId,
        _displayName = displayName,
        _boatType = boatType,
        _lat = lat,
        _lng = lng,
        _heading = heading,
        _speed = speed,
        _timestamp = timestamp,
        _battery = battery,
        _accuracy = accuracy,
        _sessionId = sessionId,
        _serverUpdatedAt = serverUpdatedAt;

  Message toMessage() {
    final m = Message(
      boatId: _boatId,
      displayName: _displayName,
      boatType: _boatType,
      lat: _lat,
      lng: _lng,
      heading: _heading,
      speed: _speed,
      timestamp: _timestamp,
      battery: _battery,
      accuracy: _accuracy,
      sessionId: _sessionId ?? 'legacy-session',
      serverUpdatedAt: _serverUpdatedAt,
    );
    return m;
  }

  factory Boat.fromMessage(Message message) {
    final b = Boat(
      boatId: message.boatId,
      displayName: message.displayName,
      boatType: message.boatType,
      lat: message.lat,
      lng: message.lng,
      heading: message.heading,
      speed: message.speed,
      timestamp: message.timestamp,
      battery: message.battery,
      accuracy: message.accuracy,
      sessionId: message.sessionId,
      serverUpdatedAt: message.serverUpdatedAt,
    );
    return b;
  }

  /// 位置・タイムスタンプだけ差し替えたコピーを作る(推測航法の補間用)
  Boat copyWithPosition({
    required double lat,
    required double lng,
    DateTime? timestamp,
  }) {
    return Boat(
      boatId: _boatId,
      displayName: _displayName,
      boatType: _boatType,
      lat: lat,
      lng: lng,
      heading: _heading,
      speed: _speed,
      timestamp: timestamp ?? _timestamp,
      battery: _battery,
      accuracy: _accuracy,
      sessionId: _sessionId,
      serverUpdatedAt: _serverUpdatedAt,
    );
  }

  static double getSeatOffset(BoatType type, SeatPosition pos) {
    final seatCount = boatConfigs.byBoatType(type).seatPosList.length;
    final seatIndex = pos.position; // 船首側からの座席位置
    final offset = ((seatCount - 2 * seatIndex + 1) / 2) *
        seatSpan; // 艇の中心を原点とし船首方向を正とする座標系での座席位置
    return offset;
  }
}
