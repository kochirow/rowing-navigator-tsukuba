import '../types/boat_type.dart';
import '../config/protocol_config.dart';
import '../config/display_name_config.dart';
import 'remote_boat_message.dart';
import 'presentation_state_protocol.dart';

class Message {
  static const currentProtocolVersion = currentPositionProtocolVersion;
  static const currentAppVersion = currentPositionAppVersion;
  // assets/data/sakuragawa_obstacles.json のversionと必ず同時更新する。
  static const currentProfileVersion = currentHazardProfileVersion;

  int _protocolVersion;
  String _appVersion;
  String _profileVersion;
  String _boatId;
  String _displayName;
  String _sessionId;
  int _sequence;
  BoatType _boatType;
  double _lat;
  double _lng;
  double _heading;
  double _speed;
  DateTime _timestamp;
  int? _battery; // 電池残量 [%](取得できない場合はnull)
  double? _accuracy; // GPS推定誤差半径 [m](取得できない場合はnull)
  DateTime? _serverUpdatedAt;
  double? _courseAccuracy;
  double? _speedAccuracy;
  String? _presentationState;
  String? _safetyRunMode;
  bool _audioSuppressedAshore;

  Message({
    required String boatId,
    String displayName = fallbackDisplayName,
    required BoatType boatType,
    required double lat,
    required double lng,
    required double heading,
    required double speed,
    required DateTime timestamp,
    int protocolVersion = currentProtocolVersion,
    String appVersion = currentAppVersion,
    String profileVersion = currentProfileVersion,
    String sessionId = 'legacy-session',
    int sequence = 0,
    int? battery,
    double? accuracy,
    DateTime? serverUpdatedAt,
    double? courseAccuracy,
    double? speedAccuracy,
    String? presentationState,
    String? safetyRunMode,
    bool audioSuppressedAshore = false,
  })  : _protocolVersion = protocolVersion,
        _appVersion = appVersion,
        _profileVersion = profileVersion,
        _boatId = boatId,
        _displayName = displayName,
        _sessionId = sessionId,
        _sequence = sequence,
        _boatType = boatType,
        _lat = lat,
        _lng = lng,
        _heading = heading,
        _speed = speed,
        _timestamp = timestamp,
        _battery = battery,
        _accuracy = accuracy,
        _serverUpdatedAt = serverUpdatedAt,
        _courseAccuracy = courseAccuracy,
        _speedAccuracy = speedAccuracy,
        _presentationState = presentationState,
        _safetyRunMode = safetyRunMode,
        _audioSuppressedAshore = audioSuppressedAshore;

  int get protocolVersion => _protocolVersion;
  String get appVersion => _appVersion;
  String get profileVersion => _profileVersion;
  String get boatId => _boatId;
  String get displayName => _displayName;
  String get sessionId => _sessionId;
  int get sequence => _sequence;
  BoatType get boatType => _boatType;
  double get lat => _lat;
  double get lng => _lng;
  double get heading => _heading;
  double get speed => _speed;
  DateTime get timestamp => _timestamp;
  int? get battery => _battery;
  double? get accuracy => _accuracy;
  DateTime? get serverUpdatedAt => _serverUpdatedAt;
  double? get courseAccuracy => _courseAccuracy;
  double? get speedAccuracy => _speedAccuracy;
  String? get presentationState => _presentationState;
  String? get safetyRunMode => _safetyRunMode;
  bool get audioSuppressedAshore => _audioSuppressedAshore;

  /// RTDB Rulesの位置payload契約に反する最初の項目。
  ///
  /// サーバーの `permission-denied` は認証失敗とは限らない。
  /// 例えば精度1026.5mは端末内のGPS判定には使えるが、
  /// Rulesの `z <= 1000` に反する。不確かさを1000mへ切り下げるのは
  /// 危険なので、送信側がこのfixを送らず次の正常fixを待つ。
  String? get compactRtdbContractViolation {
    final now = DateTime.now().toUtc();
    final observedAt = _timestamp.toUtc();
    if (_sessionId.isEmpty || _sessionId.length > 128) return 'sessionId';
    if (_sequence < 0 || _sequence > RemoteBoatMessage.maxSafeInteger) {
      return 'sequence';
    }
    if (!_lat.isFinite || _lat < -90 || _lat > 90) return 'latitude';
    if (!_lng.isFinite || _lng < -180 || _lng > 180) return 'longitude';
    if (!_heading.isFinite) return 'course';
    if (!_speed.isFinite ||
        _speed < 0 ||
        _speed > RemoteBoatMessage.maxSpeedMetersPerSecond) {
      return 'speed';
    }
    if (observedAt.isAfter(now.add(const Duration(seconds: 5))) ||
        observedAt.isBefore(now.subtract(const Duration(seconds: 60)))) {
      return 'observedAt';
    }
    if (_accuracy == null ||
        !_accuracy!.isFinite ||
        _accuracy! <= 0 ||
        _accuracy! > RemoteBoatMessage.maxAccuracyMeters) {
      return 'accuracy';
    }
    if (_battery != null && (_battery! < 0 || _battery! > 100)) {
      return 'battery';
    }
    if (_courseAccuracy != null &&
        (!_courseAccuracy!.isFinite ||
            _courseAccuracy! < 0 ||
            _courseAccuracy! > 180)) {
      return 'courseAccuracy';
    }
    if (_speedAccuracy != null &&
        (!_speedAccuracy!.isFinite ||
            _speedAccuracy! < 0 ||
            _speedAccuracy! > 30)) {
      return 'speedAccuracy';
    }
    if (_presentationState != null &&
        !PresentationStateProtocol.isValid(_presentationState!)) {
      return 'presentationState';
    }
    if (_safetyRunMode != null &&
        !RegExp(r'^[fdu]$').hasMatch(_safetyRunMode!)) {
      return 'safetyRunMode';
    }
    if (_displayName.isEmpty || _displayName.length > maxDisplayNameLength) {
      return 'displayName';
    }
    if (_protocolVersion < 1 ||
        _protocolVersion > RemoteBoatMessage.maxSafeInteger) {
      return 'protocolVersion';
    }
    if (_appVersion.isEmpty || _appVersion.length > 64) return 'appVersion';
    if (_profileVersion.isEmpty || _profileVersion.length > 128) {
      return 'profileVersion';
    }
    return null;
  }

  static BoatType _parseBoatType(dynamic value) {
    return BoatType.values.any((elm) => elm.toString().split('.').last == value)
        ? BoatType.values.byName(value)
        : BoatType.r_1x; // 艇種の識別子が不正な場合は1xとする
  }

  /// accuracyとして意味のある値(有限・正)のみ通し、それ以外はnullにする
  static double? _parseAccuracy(dynamic value) {
    final acc = (value as num?)?.toDouble();
    if (acc == null || !acc.isFinite || acc <= 0) return null;
    return acc;
  }

  // ---------------- Firestore 用 ----------------

  Map<String, dynamic> toJson() {
    return {
      'boatId': _boatId,
      'displayName': _displayName,
      'protocolVersion': _protocolVersion,
      'appVersion': _appVersion,
      'profileVersion': _profileVersion,
      'sessionId': _sessionId,
      'sequence': _sequence,
      'boatType': _boatType.toString().split('.').last,
      'lat': _lat,
      'lng': _lng,
      'heading': _heading,
      'speed': _speed,
      'timestamp': _timestamp,
      'observedAt': _timestamp,
      if (_serverUpdatedAt != null) 'serverUpdatedAt': _serverUpdatedAt,
      if (_battery != null) 'battery': _battery,
      if (_accuracy != null) 'accuracy': _accuracy,
      if (_courseAccuracy != null) 'courseAccuracy': _courseAccuracy,
      if (_speedAccuracy != null) 'speedAccuracy': _speedAccuracy,
      if (_presentationState != null) 'presentationState': _presentationState,
      if (_safetyRunMode != null) 'safetyRunMode': _safetyRunMode,
      if (_audioSuppressedAshore) 'audioSuppressedAshore': 1,
    };
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      boatId: json['boatId'],
      displayName: json['displayName'] as String? ?? fallbackDisplayName,
      protocolVersion:
          (json['protocolVersion'] as num?)?.toInt() ?? currentProtocolVersion,
      appVersion: json['appVersion'] as String? ?? currentAppVersion,
      profileVersion:
          json['profileVersion'] as String? ?? currentProfileVersion,
      sessionId: json['sessionId'] as String? ?? 'legacy-session',
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      boatType: _parseBoatType(json['boatType']),
      lat: json['lat'].toDouble(),
      lng: json['lng'].toDouble(),
      heading: json['heading'].toDouble(),
      speed: json['speed'].toDouble(),
      timestamp: (json['observedAt'] ?? json['timestamp']).toDate(),
      battery: (json['battery'] as num?)?.toInt(),
      accuracy: _parseAccuracy(json['accuracy']),
      serverUpdatedAt: json['serverUpdatedAt']?.toDate(),
      courseAccuracy: (json['courseAccuracy'] as num?)?.toDouble(),
      speedAccuracy: (json['speedAccuracy'] as num?)?.toDouble(),
      presentationState: json['presentationState'] as String?,
      safetyRunMode: json['safetyRunMode'] as String?,
      audioSuppressedAshore: json['audioSuppressedAshore'] == 1,
    );
  }

  // ---------------- Realtime Database 用 ----------------
  // RTDBにはTimestamp型がないため、エポックミリ秒で保存する。

  Map<String, dynamic> toRtdbJson({Object? serverUpdatedAt}) {
    return {
      'protocolVersion': _protocolVersion,
      'appVersion': _appVersion,
      'profileVersion': _profileVersion,
      'boatId': _boatId,
      'displayName': _displayName,
      'sessionId': _sessionId,
      'sequence': _sequence,
      'boatType': _boatType.toString().split('.').last,
      'lat': _lat,
      'lng': _lng,
      // protocolではcourseに統一。headingも旧版互換用に残す。
      'course': ((_heading % 360) + 360) % 360,
      'heading': _heading,
      'speed': _speed,
      'timestamp': _timestamp.millisecondsSinceEpoch,
      'observedAt': _timestamp.toUtc().millisecondsSinceEpoch,
      if (serverUpdatedAt != null)
        'serverUpdatedAt': serverUpdatedAt
      else if (_serverUpdatedAt != null)
        'serverUpdatedAt': _serverUpdatedAt!.toUtc().millisecondsSinceEpoch,
      if (_battery != null) 'battery': _battery,
      if (_accuracy != null) 'accuracy': _accuracy,
      if (_courseAccuracy != null) 'courseAccuracy': _courseAccuracy,
      if (_speedAccuracy != null) 'speedAccuracy': _speedAccuracy,
      if (_presentationState != null) 'presentationState': _presentationState,
      if (_safetyRunMode != null) 'safetyRunMode': _safetyRunMode,
      if (_audioSuppressedAshore) 'audioSuppressedAshore': 1,
      'navigationState': _speed >= 0.5 ? 'moving' : 'stopped',
      'capabilities': [
        'course',
        'accuracy',
        'session_sequence',
        'display_name',
        if (_presentationState != null) 'presentation_state',
      ],
    };
  }

  /// 通常の1Hz送信用。名前・艇種などの不変値は
  /// `boat_profiles/{uid}`に分離し、RTDB転送量と無線処理を減らす。
  Map<String, dynamic> toCompactRtdbJson({Object? serverUpdatedAt}) {
    return {
      's': _sessionId,
      'q': _sequence,
      'u': serverUpdatedAt ?? _serverUpdatedAt?.toUtc().millisecondsSinceEpoch,
      'o': _timestamp.toUtc().millisecondsSinceEpoch,
      'x': _lat,
      'y': _lng,
      'c': ((_heading % 360) + 360) % 360,
      'v': _speed,
      if (_accuracy != null) 'z': _accuracy,
      if (_battery != null) 'b': _battery,
      if (_courseAccuracy != null) 'j': _courseAccuracy,
      if (_speedAccuracy != null) 'k': _speedAccuracy,
      if (_presentationState != null) 'w': _presentationState,
      if (_safetyRunMode != null) 'm': _safetyRunMode,
      if (_audioSuppressedAshore) 'a': 1,
    }..removeWhere((_, value) => value == null);
  }

  /// 不変プロファイル。送信内容が変わった時だけ上書きする。
  Map<String, dynamic> toRtdbProfileJson({Object? updatedAt}) => {
        'displayName': _displayName,
        'boatType': _boatType.name,
        'protocolVersion': _protocolVersion,
        'appVersion': _appVersion,
        'profileVersion': _profileVersion,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };

  /// コンパクト位置にpathとprofileの値を結合し、既存の
  /// 強制検証パイプラインに渡す標準形式へ展開する。
  static Map<Object?, Object?> expandCompactRtdbJson({
    required String boatId,
    required Map<Object?, Object?> compact,
    required Map<Object?, Object?> profile,
  }) {
    return {
      'protocolVersion': profile['protocolVersion'],
      'appVersion': profile['appVersion'],
      'profileVersion': profile['profileVersion'],
      'boatId': boatId,
      'displayName': profile['displayName'],
      'boatType': profile['boatType'],
      'sessionId': compact['s'],
      'sequence': compact['q'],
      'serverUpdatedAt': compact['u'],
      'observedAt': compact['o'],
      'lat': compact['x'],
      'lng': compact['y'],
      'course': compact['c'],
      'speed': compact['v'],
      'accuracy': compact['z'],
      if (compact['b'] != null) 'battery': compact['b'],
      if (compact['j'] != null) 'courseAccuracy': compact['j'],
      if (compact['k'] != null) 'speedAccuracy': compact['k'],
      if (compact['w'] != null) 'presentationState': compact['w'],
      if (compact['m'] != null) 'safetyRunMode': compact['m'],
      if (compact['a'] != null) 'audioSuppressedAshore': compact['a'],
      'navigationState': compact['v'] is num && (compact['v'] as num) >= 0.5
          ? 'moving'
          : 'stopped',
      'capabilities': [
        'course',
        'accuracy',
        'session_sequence',
        'display_name',
        if (compact['w'] != null) 'presentation_state',
      ],
    };
  }

  factory Message.fromRtdbJson(Map<String, dynamic> json) {
    return Message(
      boatId: json['boatId'] as String,
      displayName: json['displayName'] as String? ?? fallbackDisplayName,
      protocolVersion:
          (json['protocolVersion'] as num?)?.toInt() ?? currentProtocolVersion,
      appVersion: json['appVersion'] as String? ?? currentAppVersion,
      profileVersion:
          json['profileVersion'] as String? ?? currentProfileVersion,
      sessionId: json['sessionId'] as String? ?? 'legacy-session',
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      boatType: _parseBoatType(json['boatType']),
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      heading: ((json['course'] ?? json['heading']) as num).toDouble(),
      speed: (json['speed'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        ((json['observedAt'] ?? json['timestamp']) as num).toInt(),
      ),
      battery: (json['battery'] as num?)?.toInt(),
      accuracy: _parseAccuracy(json['accuracy']),
      serverUpdatedAt: json['serverUpdatedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['serverUpdatedAt'] as num).toInt(),
            ),
      courseAccuracy: (json['courseAccuracy'] as num?)?.toDouble(),
      speedAccuracy: (json['speedAccuracy'] as num?)?.toDouble(),
      presentationState: json['presentationState'] as String?,
      safetyRunMode: json['safetyRunMode'] as String?,
      audioSuppressedAshore: json['audioSuppressedAshore'] == 1,
    );
  }
}
