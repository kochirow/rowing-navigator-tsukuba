import 'dart:convert';

enum PracticeLogSource { live, observer }

class PracticeLogPoint {
  final DateTime t;
  final PracticeLogSource source;
  final String boatId;
  final String? displayName;
  final String? sessionId;
  final int? sequence;
  final double lat;
  final double lng;
  final double? speed;
  final double? course;
  final double? accuracy;
  final int? battery;
  final String? presentationState;
  final String? safetyRunMode;
  final bool audioSuppressedAshore;
  final double ageSec;

  const PracticeLogPoint({
    required this.t,
    required this.source,
    required this.boatId,
    required this.lat,
    required this.lng,
    required this.ageSec,
    this.displayName,
    this.sessionId,
    this.sequence,
    this.speed,
    this.course,
    this.accuracy,
    this.battery,
    this.presentationState,
    this.safetyRunMode,
    this.audioSuppressedAshore = false,
  });

  Map<String, dynamic> toJson() => {
        't': t.toUtc().toIso8601String(),
        'source': source.name,
        'boatId': boatId,
        if (displayName != null) 'displayName': displayName,
        if (sessionId != null) 'sessionId': sessionId,
        if (sequence != null) 'seq': sequence,
        'lat': lat,
        'lng': lng,
        if (speed != null) 'speed': speed,
        if (course != null) 'course': course,
        if (accuracy != null) 'accuracy': accuracy,
        if (battery != null) 'battery': battery,
        if (presentationState != null) 'w': presentationState,
        if (safetyRunMode != null) 'm': safetyRunMode,
        if (audioSuppressedAshore) 'a': 1,
        'ageSec': ageSec,
      };

  factory PracticeLogPoint.fromJson(Map<String, dynamic> json) =>
      PracticeLogPoint(
        t: DateTime.parse(json['t'] as String).toUtc(),
        source: PracticeLogSource.values.byName(json['source'] as String),
        boatId: json['boatId'] as String,
        displayName: json['displayName'] as String?,
        sessionId: json['sessionId'] as String?,
        sequence: (json['seq'] as num?)?.toInt(),
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        speed: (json['speed'] as num?)?.toDouble(),
        course: (json['course'] as num?)?.toDouble(),
        accuracy: (json['accuracy'] as num?)?.toDouble(),
        battery: (json['battery'] as num?)?.toInt(),
        presentationState: json['w'] as String?,
        safetyRunMode: json['m'] as String?,
        audioSuppressedAshore: json['a'] == 1,
        ageSec: (json['ageSec'] as num).toDouble(),
      );
}

class PracticeLogEvent {
  final DateTime t;
  final int elapsedMs;
  final String type;
  final Map<String, dynamic> details;
  const PracticeLogEvent(
      {required this.t,
      required this.elapsedMs,
      required this.type,
      this.details = const {}});
  Map<String, dynamic> toJson() => {
        't': t.toUtc().toIso8601String(),
        'elapsedMs': elapsedMs,
        'type': type,
        'details': details
      };
  factory PracticeLogEvent.fromJson(
          Map<String, dynamic> json) =>
      PracticeLogEvent(
          t: DateTime.parse(json['t'] as String).toUtc(),
          elapsedMs: (json['elapsedMs'] as num).toInt(),
          type: json['type'] as String,
          details:
              Map<String, dynamic>.from(json['details'] as Map? ?? const {}));
}

class PracticeLog {
  final String id;
  final String teamId;
  final String recordedBy;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool isComplete;
  final int pointCount;
  final int eventCount;

  const PracticeLog(
      {required this.id,
      required this.teamId,
      required this.recordedBy,
      required this.startedAt,
      this.endedAt,
      required this.isComplete,
      this.pointCount = 0,
      this.eventCount = 0});
  PracticeLog copyWith(
          {DateTime? endedAt,
          bool? isComplete,
          int? pointCount,
          int? eventCount}) =>
      PracticeLog(
          id: id,
          teamId: teamId,
          recordedBy: recordedBy,
          startedAt: startedAt,
          endedAt: endedAt ?? this.endedAt,
          isComplete: isComplete ?? this.isComplete,
          pointCount: pointCount ?? this.pointCount,
          eventCount: eventCount ?? this.eventCount);
  Map<String, dynamic> toJson() => {
        'practiceLogSchemaVersion': 1,
        'practiceId': id,
        'teamId': teamId,
        'recordedBy': recordedBy,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
        'isComplete': isComplete,
        'pointCount': pointCount,
        'eventCount': eventCount,
        'automaticUpload': false
      };
  factory PracticeLog.fromJson(Map<String, dynamic> json) => PracticeLog(
      id: json['practiceId'] as String,
      teamId: json['teamId'] as String,
      recordedBy: json['recordedBy'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String).toUtc(),
      endedAt: json['endedAt'] == null
          ? null
          : DateTime.parse(json['endedAt'] as String).toUtc(),
      isComplete: json['isComplete'] as bool? ?? false,
      pointCount: (json['pointCount'] as num?)?.toInt() ?? 0,
      eventCount: (json['eventCount'] as num?)?.toInt() ?? 0);
}

String practiceLogJsonLine(Object value) => jsonEncode(value is PracticeLogPoint
    ? value.toJson()
    : (value as PracticeLogEvent).toJson());
