import '../config/protocol_config.dart';
import '../config/display_name_config.dart';

/// Firebaseの型に依存しない、検証済みの他艇位置メッセージ。
///
/// 生のMapからは[tryParse]だけを通し、不正値が衝突予測へ入らないようにする。
class RemoteBoatMessage {
  static const int currentProtocolVersion = currentPositionProtocolVersion;
  static const int maxSafeInteger = 9007199254740991; // JavaScriptでも正確な上限
  static const double maxAccuracyMeters = 1000;
  static const double maxSpeedMetersPerSecond = 30;
  static const Duration maxObservedAtFutureSkew = Duration(seconds: 5);

  final int protocolVersion;
  final String appVersion;
  final String profileVersion;
  final String boatId;
  final String displayName;
  final String sessionId;
  final int sequence;
  final DateTime serverUpdatedAt;
  final DateTime observedAt;
  final double lat;
  final double lng;
  final double accuracy;
  final double course;
  final double? courseAccuracy;
  final double speed;
  final double? speedAccuracy;
  final int? battery;
  final String? boatType;
  final double? turnRate;
  final String? navigationState;
  final List<String> capabilities;

  /// 記録専用の提示状態。Boatや衝突評価へは渡さない。
  final String? presentationState;
  final String? safetyRunMode;
  final bool audioSuppressedAshore;

  const RemoteBoatMessage._({
    required this.protocolVersion,
    required this.appVersion,
    required this.profileVersion,
    required this.boatId,
    required this.displayName,
    required this.sessionId,
    required this.sequence,
    required this.serverUpdatedAt,
    required this.observedAt,
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.course,
    required this.courseAccuracy,
    required this.speed,
    required this.speedAccuracy,
    required this.battery,
    required this.boatType,
    required this.turnRate,
    required this.navigationState,
    required this.capabilities,
    required this.presentationState,
    required this.safetyRunMode,
    required this.audioSuppressedAshore,
  });

  /// RTDB/Firestoreのスナップショットを検証する。
  ///
  /// [estimatedServerNow]はFirebaseサーバー時刻の推定値を渡す。端末時計を
  /// そのまま渡すと、端末の時計ずれでfutureTimestampになりうる。
  static RemoteBoatMessageParseResult tryParse(
    Map<Object?, Object?> json, {
    required DateTime estimatedServerNow,
    Set<int>? supportedProtocolVersions,
    Set<String>? supportedProfileVersions,
  }) {
    final now = estimatedServerNow.toUtc();

    RemoteBoatMessageParseResult fail(
      String field,
      RemoteBoatMessageValidationCode code,
    ) =>
        RemoteBoatMessageParseResult.failure(
          RemoteBoatMessageValidationFailure(field: field, code: code),
        );

    final protocolVersion = _integer(json['protocolVersion']);
    if (protocolVersion == null) {
      return fail('protocolVersion', _numericFailure(json['protocolVersion']));
    }
    if (protocolVersion < 1 || protocolVersion > maxSafeInteger) {
      return fail(
          'protocolVersion', RemoteBoatMessageValidationCode.outOfRange);
    }
    // 版番号は通常は参考情報とし、未知版でも共通フィールドから
    // 他艇位置を復元する。限定的な調査・テストで明示的にallowlistを
    // 渡した場合だけ、従来どおり厳格モードで判定する。
    if (supportedProtocolVersions != null &&
        !supportedProtocolVersions.contains(protocolVersion)) {
      return fail(
        'protocolVersion',
        RemoteBoatMessageValidationCode.unsupportedProtocolVersion,
      );
    }

    // app/profile版も文字列としての安全性だけを見る。
    final appVersionResult =
        _validatedString(json['appVersion'], maxLength: 64);
    if (appVersionResult == null) {
      return fail('appVersion', _stringFailure(json['appVersion'], 64));
    }
    final profileVersionResult =
        _validatedString(json['profileVersion'], maxLength: 128);
    if (profileVersionResult == null) {
      return fail(
        'profileVersion',
        _stringFailure(json['profileVersion'], 128),
      );
    }
    if (supportedProfileVersions != null &&
        !supportedProfileVersions.contains(profileVersionResult)) {
      return fail(
        'profileVersion',
        RemoteBoatMessageValidationCode.unsupportedProfileVersion,
      );
    }
    final boatIdResult = _validatedString(json['boatId'], maxLength: 128);
    if (boatIdResult == null) {
      return fail('boatId', _stringFailure(json['boatId'], 128));
    }
    var displayNameResult = fallbackDisplayName;
    if (json.containsKey('displayName')) {
      final displayName = _validatedString(json['displayName'],
          maxLength: maxDisplayNameLength);
      if (displayName == null) {
        return fail(
          'displayName',
          _stringFailure(json['displayName'], maxDisplayNameLength),
        );
      }
      displayNameResult = displayName;
    }
    final sessionIdResult = _validatedString(json['sessionId'], maxLength: 128);
    if (sessionIdResult == null) {
      return fail('sessionId', _stringFailure(json['sessionId'], 128));
    }

    final sequence = _integer(json['sequence']);
    if (sequence == null) {
      return fail('sequence', _numericFailure(json['sequence']));
    }
    if (sequence < 0 || sequence > maxSafeInteger) {
      return fail('sequence', RemoteBoatMessageValidationCode.outOfRange);
    }

    final serverUpdatedAtMillis = _integer(json['serverUpdatedAt']);
    if (serverUpdatedAtMillis == null) {
      return fail(
        'serverUpdatedAt',
        _numericFailure(json['serverUpdatedAt']),
      );
    }
    final observedAtMillis = _integer(json['observedAt']);
    if (observedAtMillis == null) {
      return fail('observedAt', _numericFailure(json['observedAt']));
    }
    final serverUpdatedAt = _utcDate(serverUpdatedAtMillis);
    if (serverUpdatedAt == null) {
      return fail(
          'serverUpdatedAt', RemoteBoatMessageValidationCode.outOfRange);
    }
    final observedAt = _utcDate(observedAtMillis);
    if (observedAt == null) {
      return fail('observedAt', RemoteBoatMessageValidationCode.outOfRange);
    }
    if (serverUpdatedAt.isAfter(now)) {
      return fail(
        'serverUpdatedAt',
        RemoteBoatMessageValidationCode.futureTimestamp,
      );
    }
    // observedAtは送信端末のwall clockであり、RTDB Rulesも端末差を5秒まで
    // 許容する。鮮度・外挿にはserverUpdatedAtを使い、ここでは同じ上限だけ
    // 受理してRulesとクライアント検証の不一致を避ける。
    if (observedAt.isAfter(now.add(maxObservedAtFutureSkew))) {
      return fail(
        'observedAt',
        RemoteBoatMessageValidationCode.futureTimestamp,
      );
    }

    final lat = _finiteDouble(json['lat']);
    if (lat == null) return fail('lat', _numericFailure(json['lat']));
    if (lat < -90 || lat > 90) {
      return fail('lat', RemoteBoatMessageValidationCode.outOfRange);
    }
    final lng = _finiteDouble(json['lng']);
    if (lng == null) return fail('lng', _numericFailure(json['lng']));
    if (lng < -180 || lng > 180) {
      return fail('lng', RemoteBoatMessageValidationCode.outOfRange);
    }
    final accuracy = _finiteDouble(json['accuracy']);
    if (accuracy == null) {
      return fail('accuracy', _numericFailure(json['accuracy']));
    }
    if (accuracy <= 0 || accuracy > maxAccuracyMeters) {
      return fail('accuracy', RemoteBoatMessageValidationCode.outOfRange);
    }
    final course = _finiteDouble(json['course']);
    if (course == null) {
      return fail('course', _numericFailure(json['course']));
    }
    if (course < 0 || course >= 360) {
      return fail('course', RemoteBoatMessageValidationCode.outOfRange);
    }
    final speed = _finiteDouble(json['speed']);
    if (speed == null) return fail('speed', _numericFailure(json['speed']));
    if (speed < 0 || speed > maxSpeedMetersPerSecond) {
      return fail('speed', RemoteBoatMessageValidationCode.outOfRange);
    }

    final courseAccuracy = _optionalFiniteDouble(json['courseAccuracy']);
    if (json['courseAccuracy'] != null && courseAccuracy == null) {
      return fail(
        'courseAccuracy',
        _numericFailure(json['courseAccuracy']),
      );
    }
    if (courseAccuracy != null &&
        (courseAccuracy < 0 || courseAccuracy > 180)) {
      return fail('courseAccuracy', RemoteBoatMessageValidationCode.outOfRange);
    }
    final speedAccuracy = _optionalFiniteDouble(json['speedAccuracy']);
    if (json['speedAccuracy'] != null && speedAccuracy == null) {
      return fail(
        'speedAccuracy',
        _numericFailure(json['speedAccuracy']),
      );
    }
    if (speedAccuracy != null &&
        (speedAccuracy < 0 || speedAccuracy > maxSpeedMetersPerSecond)) {
      return fail('speedAccuracy', RemoteBoatMessageValidationCode.outOfRange);
    }

    final battery = json['battery'] == null ? null : _integer(json['battery']);
    if (json['battery'] != null && battery == null) {
      return fail('battery', _numericFailure(json['battery']));
    }
    if (battery != null && (battery < 0 || battery > 100)) {
      return fail('battery', RemoteBoatMessageValidationCode.outOfRange);
    }

    final boatType = _validatedString(json['boatType'], maxLength: 32);
    if (boatType == null) {
      return fail('boatType', _stringFailure(json['boatType'], 32));
    }
    // 未知の艇種名は将来版で追加された可能性がある。位置自体は残し、
    // 現行版がBoatへ変換する際はMessageの安全な1x既定値へ縮退する。
    final navigationState =
        _optionalString(json['navigationState'], maxLength: 32);
    if (json['navigationState'] != null && navigationState == null) {
      return fail(
        'navigationState',
        _stringFailure(json['navigationState'], 32),
      );
    }
    final turnRate = _optionalFiniteDouble(json['turnRate']);
    if (json['turnRate'] != null && turnRate == null) {
      return fail('turnRate', _numericFailure(json['turnRate']));
    }
    if (turnRate != null && (turnRate < -360 || turnRate > 360)) {
      return fail('turnRate', RemoteBoatMessageValidationCode.outOfRange);
    }

    final capabilities = _capabilities(json['capabilities']);
    if (capabilities == null) {
      return fail(
        'capabilities',
        RemoteBoatMessageValidationCode.invalidCapabilities,
      );
    }

    // 新旧アプリの混在中も位置共有を止めない。記録用の任意フィールドが
    // 壊れていても、その艇の位置レコード全体を捨てず値だけ落とす。
    final presentationState = _presentationState(json['presentationState']);
    final safetyRunMode = _safetyRunMode(json['safetyRunMode']);
    final audioSuppressedAshore = json['audioSuppressedAshore'] == 1;

    return RemoteBoatMessageParseResult.success(
      RemoteBoatMessage._(
        protocolVersion: protocolVersion,
        appVersion: appVersionResult,
        profileVersion: profileVersionResult,
        boatId: boatIdResult,
        displayName: displayNameResult,
        sessionId: sessionIdResult,
        sequence: sequence,
        serverUpdatedAt: serverUpdatedAt,
        observedAt: observedAt,
        lat: lat,
        lng: lng,
        accuracy: accuracy,
        course: course,
        courseAccuracy: courseAccuracy,
        speed: speed,
        speedAccuracy: speedAccuracy,
        battery: battery,
        boatType: boatType,
        turnRate: turnRate,
        navigationState: navigationState,
        capabilities: List.unmodifiable(capabilities),
        presentationState: presentationState,
        safetyRunMode: safetyRunMode,
        audioSuppressedAshore: audioSuppressedAshore,
      ),
    );
  }

  Map<String, Object?> toJson() => {
        'protocolVersion': protocolVersion,
        'appVersion': appVersion,
        'profileVersion': profileVersion,
        'boatId': boatId,
        'displayName': displayName,
        'sessionId': sessionId,
        'sequence': sequence,
        'serverUpdatedAt': serverUpdatedAt.millisecondsSinceEpoch,
        'observedAt': observedAt.millisecondsSinceEpoch,
        'lat': lat,
        'lng': lng,
        'accuracy': accuracy,
        'course': course,
        'courseAccuracy': courseAccuracy,
        'speed': speed,
        'speedAccuracy': speedAccuracy,
        'battery': battery,
        'boatType': boatType,
        'turnRate': turnRate,
        'navigationState': navigationState,
        'capabilities': capabilities,
        if (presentationState != null) 'presentationState': presentationState,
        if (safetyRunMode != null) 'safetyRunMode': safetyRunMode,
        if (audioSuppressedAshore) 'audioSuppressedAshore': 1,
      };

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.truncateToDouble()) {
      return value.toInt();
    }
    return null;
  }

  static double? _finiteDouble(Object? value) {
    if (value is! num) return null;
    final result = value.toDouble();
    return result.isFinite ? result : null;
  }

  static double? _optionalFiniteDouble(Object? value) =>
      value == null ? null : _finiteDouble(value);

  static String? _validatedString(Object? value, {required int maxLength}) {
    if (value is! String ||
        value.isEmpty ||
        value.length > maxLength ||
        value.trim() != value ||
        value.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return null;
    }
    return value;
  }

  static String? _optionalString(Object? value, {required int maxLength}) =>
      value == null ? null : _validatedString(value, maxLength: maxLength);

  static List<String>? _capabilities(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.length > 32) return null;
    final result = <String>[];
    for (final item in value) {
      final capability = _validatedString(item, maxLength: 64);
      if (capability == null || result.contains(capability)) return null;
      result.add(capability);
    }
    return result;
  }

  static String? _presentationState(Object? value) {
    if (value is! String || !RegExp(r'^[012][obsidcrgf]$').hasMatch(value)) {
      return null;
    }
    return value;
  }

  static String? _safetyRunMode(Object? value) {
    if (value is! String || !RegExp(r'^[fdu]$').hasMatch(value)) return null;
    return value;
  }

  static DateTime? _utcDate(int epochMillis) {
    // DateTimeの実装上限に近い値や、1970年前の値をprotocol入力に許さない。
    if (epochMillis < 0 || epochMillis > 8640000000000000) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(epochMillis, isUtc: true);
    } on ArgumentError {
      return null;
    }
  }

  static RemoteBoatMessageValidationCode _numericFailure(Object? value) {
    if (value == null) return RemoteBoatMessageValidationCode.missingField;
    if (value is num && !value.isFinite) {
      return RemoteBoatMessageValidationCode.nonFinite;
    }
    return RemoteBoatMessageValidationCode.invalidType;
  }

  static RemoteBoatMessageValidationCode _stringFailure(
    Object? value,
    int maxLength,
  ) {
    if (value == null) return RemoteBoatMessageValidationCode.missingField;
    if (value is! String) return RemoteBoatMessageValidationCode.invalidType;
    if (value.isEmpty) return RemoteBoatMessageValidationCode.emptyString;
    if (value.length > maxLength) {
      return RemoteBoatMessageValidationCode.stringTooLong;
    }
    return RemoteBoatMessageValidationCode.invalidCharacters;
  }
}

enum RemoteBoatMessageValidationCode {
  missingField,
  invalidType,
  nonFinite,
  emptyString,
  stringTooLong,
  invalidCharacters,
  outOfRange,
  futureTimestamp,
  unsupportedProtocolVersion,
  // appVersionの不一致は失敗理由にならない(互換の判断はprotocolVersionだけ)。
  unsupportedProfileVersion,
  unsupportedBoatType,
  invalidCapabilities,
}

class RemoteBoatMessageValidationFailure {
  final String field;
  final RemoteBoatMessageValidationCode code;

  const RemoteBoatMessageValidationFailure({
    required this.field,
    required this.code,
  });
}

class RemoteBoatMessageParseResult {
  final RemoteBoatMessage? message;
  final RemoteBoatMessageValidationFailure? failure;

  const RemoteBoatMessageParseResult._({this.message, this.failure});

  const RemoteBoatMessageParseResult.success(RemoteBoatMessage message)
      : this._(message: message);

  const RemoteBoatMessageParseResult.failure(
    RemoteBoatMessageValidationFailure failure,
  ) : this._(failure: failure);

  bool get isValid => message != null;
}
