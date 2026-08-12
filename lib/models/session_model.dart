// =====================================================
// 練習セッション(構造化された航行記録)のデータモデル
// 端末内にJSONファイルとして保存される(サーバー不要・費用ゼロ)。
// =====================================================

/// 1秒ごとの記録点
class TrackPoint {
  final DateTime t;

  /// 単調時計ベースのセッション開始からの経過時間。
  final int? elapsedMs;
  final double lat;
  final double lng;
  final double speed; // [m/s]
  final double heading; // [度]
  final double? spm; // ストロークレート(計測不能時はnull)
  final String safetyLevel; // safe / caution / warning / emergency
  final double? rawLat;
  final double? rawLng;
  final double? gnssAccuracyMeters;
  final double? speedAccuracyMetersPerSecond;
  final double? headingAccuracyDegrees;
  final String? gnssQuality;
  final String? positionFilterResult;
  final double? estimateUncertaintyMeters;
  final double? estimateInnovationMeters;
  final String? estimateDisposition;
  final double? estimateNormalizedInnovationSquared;
  final double? rawGnssSpeedMetersPerSecond;
  final double? imuConfidence;
  final String? imuQuality;
  final double? distancePerStrokeMeters;
  final double? catchSpeedLossMetersPerSecond;
  final double? lateDriveSpeedGainMetersPerSecond;
  final double? recoverySpeedRetention;

  TrackPoint({
    required this.t,
    this.elapsedMs,
    required this.lat,
    required this.lng,
    required this.speed,
    required this.heading,
    this.spm,
    required this.safetyLevel,
    this.rawLat,
    this.rawLng,
    this.gnssAccuracyMeters,
    this.speedAccuracyMetersPerSecond,
    this.headingAccuracyDegrees,
    this.gnssQuality,
    this.positionFilterResult,
    this.estimateUncertaintyMeters,
    this.estimateInnovationMeters,
    this.estimateDisposition,
    this.estimateNormalizedInnovationSquared,
    this.rawGnssSpeedMetersPerSecond,
    this.imuConfidence,
    this.imuQuality,
    this.distancePerStrokeMeters,
    this.catchSpeedLossMetersPerSecond,
    this.lateDriveSpeedGainMetersPerSecond,
    this.recoverySpeedRetention,
  });

  Map<String, dynamic> toJson() => {
        't': t.millisecondsSinceEpoch,
        if (elapsedMs != null) 'elapsedMs': elapsedMs,
        'lat': lat,
        'lng': lng,
        'speed': speed,
        'heading': heading,
        if (spm != null) 'spm': spm,
        'safetyLevel': safetyLevel,
        if (rawLat != null) 'rawLat': rawLat,
        if (rawLng != null) 'rawLng': rawLng,
        if (gnssAccuracyMeters != null)
          'gnssAccuracyMeters': gnssAccuracyMeters,
        if (speedAccuracyMetersPerSecond != null)
          'speedAccuracyMetersPerSecond': speedAccuracyMetersPerSecond,
        if (headingAccuracyDegrees != null)
          'headingAccuracyDegrees': headingAccuracyDegrees,
        if (gnssQuality != null) 'gnssQuality': gnssQuality,
        if (positionFilterResult != null)
          'positionFilterResult': positionFilterResult,
        if (estimateUncertaintyMeters != null)
          'estimateUncertaintyMeters': estimateUncertaintyMeters,
        if (estimateInnovationMeters != null)
          'estimateInnovationMeters': estimateInnovationMeters,
        if (estimateDisposition != null)
          'estimateDisposition': estimateDisposition,
        if (estimateNormalizedInnovationSquared != null)
          'estimateNormalizedInnovationSquared':
              estimateNormalizedInnovationSquared,
        if (rawGnssSpeedMetersPerSecond != null)
          'rawGnssSpeedMetersPerSecond': rawGnssSpeedMetersPerSecond,
        if (imuConfidence != null) 'imuConfidence': imuConfidence,
        if (imuQuality != null) 'imuQuality': imuQuality,
        if (distancePerStrokeMeters != null)
          'distancePerStrokeMeters': distancePerStrokeMeters,
        if (catchSpeedLossMetersPerSecond != null)
          'catchSpeedLossMetersPerSecond': catchSpeedLossMetersPerSecond,
        if (lateDriveSpeedGainMetersPerSecond != null)
          'lateDriveSpeedGainMetersPerSecond':
              lateDriveSpeedGainMetersPerSecond,
        if (recoverySpeedRetention != null)
          'recoverySpeedRetention': recoverySpeedRetention,
      };

  factory TrackPoint.fromJson(Map<String, dynamic> json) => TrackPoint(
        t: DateTime.fromMillisecondsSinceEpoch((json['t'] as num).toInt()),
        elapsedMs: (json['elapsedMs'] as num?)?.toInt(),
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        speed: (json['speed'] as num).toDouble(),
        heading: (json['heading'] as num).toDouble(),
        spm: (json['spm'] as num?)?.toDouble(),
        safetyLevel: json['safetyLevel'] as String? ?? 'safe',
        rawLat: (json['rawLat'] as num?)?.toDouble(),
        rawLng: (json['rawLng'] as num?)?.toDouble(),
        gnssAccuracyMeters: (json['gnssAccuracyMeters'] as num?)?.toDouble(),
        speedAccuracyMetersPerSecond:
            (json['speedAccuracyMetersPerSecond'] as num?)?.toDouble(),
        headingAccuracyDegrees:
            (json['headingAccuracyDegrees'] as num?)?.toDouble(),
        gnssQuality: json['gnssQuality'] as String?,
        positionFilterResult: json['positionFilterResult'] as String?,
        estimateUncertaintyMeters:
            (json['estimateUncertaintyMeters'] as num?)?.toDouble(),
        estimateInnovationMeters:
            (json['estimateInnovationMeters'] as num?)?.toDouble(),
        estimateDisposition: json['estimateDisposition'] as String?,
        estimateNormalizedInnovationSquared:
            (json['estimateNormalizedInnovationSquared'] as num?)?.toDouble(),
        rawGnssSpeedMetersPerSecond:
            (json['rawGnssSpeedMetersPerSecond'] as num?)?.toDouble(),
        imuConfidence: (json['imuConfidence'] as num?)?.toDouble(),
        imuQuality: json['imuQuality'] as String?,
        distancePerStrokeMeters:
            (json['distancePerStrokeMeters'] as num?)?.toDouble(),
        catchSpeedLossMetersPerSecond:
            (json['catchSpeedLossMetersPerSecond'] as num?)?.toDouble(),
        lateDriveSpeedGainMetersPerSecond:
            (json['lateDriveSpeedGainMetersPerSecond'] as num?)?.toDouble(),
        recoverySpeedRetention:
            (json['recoverySpeedRetention'] as num?)?.toDouble(),
      );
}

/// 警告の候補・状態遷移・音声指示を後から再現するための診断イベント。
///
/// 他艇は永続IDではなく、航行セッション内だけで有効な [targetRef] を保存する。
class AlertDiagnosticEvent {
  /// alerts.jsonl と events.jsonl を横断して並べるための通し番号。
  final int? sequence;

  /// 端末時計の変更に影響されにくい、セッション開始からの経過時間。
  final int? elapsedMs;
  final DateTime t;
  final String event;
  final String alertId;
  final String detectorId;
  final String category;
  final String? targetRef;
  final String phase;
  final String? fromPhase;
  final String? toPhase;
  final bool isPrimary;
  final int riskLevel;
  final bool currentOverlap;
  final double confidence;
  final String dataQuality;
  final double? distanceMeters;

  /// 領域同士の最接近距離 [m](DCPA相当)。重なるときは0。
  final double? separationMeters;
  final double? actionDeadlineSec;
  final List<String> reasonCodes;
  final String? audioMode;
  final String? audioAction;

  AlertDiagnosticEvent({
    this.sequence,
    this.elapsedMs,
    required this.t,
    required this.event,
    required this.alertId,
    required this.detectorId,
    required this.category,
    required this.phase,
    required this.isPrimary,
    required this.riskLevel,
    required this.currentOverlap,
    required this.confidence,
    required this.dataQuality,
    this.targetRef,
    this.fromPhase,
    this.toPhase,
    this.distanceMeters,
    this.separationMeters,
    this.actionDeadlineSec,
    this.reasonCodes = const [],
    this.audioMode,
    this.audioAction,
  });

  Map<String, dynamic> toJson() => {
        if (sequence != null) 'seq': sequence,
        if (elapsedMs != null) 'elapsedMs': elapsedMs,
        't': t.millisecondsSinceEpoch,
        'event': event,
        'alertId': alertId,
        'detectorId': detectorId,
        'category': category,
        if (targetRef != null) 'targetRef': targetRef,
        'phase': phase,
        if (fromPhase != null) 'fromPhase': fromPhase,
        if (toPhase != null) 'toPhase': toPhase,
        'isPrimary': isPrimary,
        'riskLevel': riskLevel,
        'currentOverlap': currentOverlap,
        'confidence': confidence,
        'dataQuality': dataQuality,
        if (distanceMeters != null) 'distanceMeters': distanceMeters,
        if (separationMeters != null) 'separationMeters': separationMeters,
        if (actionDeadlineSec != null) 'actionDeadlineSec': actionDeadlineSec,
        'reasonCodes': reasonCodes,
        if (audioMode != null) 'audioMode': audioMode,
        if (audioAction != null) 'audioAction': audioAction,
      };

  factory AlertDiagnosticEvent.fromJson(Map<String, dynamic> json) =>
      AlertDiagnosticEvent(
        sequence: (json['seq'] as num?)?.toInt(),
        elapsedMs: (json['elapsedMs'] as num?)?.toInt(),
        t: DateTime.fromMillisecondsSinceEpoch((json['t'] as num).toInt()),
        event: json['event'] as String? ?? 'observation',
        alertId: json['alertId'] as String? ?? 'unknown',
        detectorId: json['detectorId'] as String? ?? 'unknown',
        category: json['category'] as String? ?? 'generic',
        targetRef: json['targetRef'] as String?,
        phase: json['phase'] as String? ?? 'safe',
        fromPhase: json['fromPhase'] as String?,
        toPhase: json['toPhase'] as String?,
        isPrimary: json['isPrimary'] as bool? ?? false,
        riskLevel: (json['riskLevel'] as num?)?.toInt() ?? 0,
        currentOverlap: json['currentOverlap'] as bool? ?? false,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 1,
        dataQuality: json['dataQuality'] as String? ?? 'good',
        distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
        separationMeters: (json['separationMeters'] as num?)?.toDouble(),
        actionDeadlineSec: (json['actionDeadlineSec'] as num?)?.toDouble(),
        reasonCodes: (json['reasonCodes'] as List<dynamic>? ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        audioMode: json['audioMode'] as String?,
        audioAction: json['audioAction'] as String?,
      );
}

/// GPS品質・画面状態・ライフサイクルなどの軽量診断イベント。
class SessionDiagnosticEvent {
  /// alerts.jsonl と events.jsonl を横断して並べるための通し番号。
  final int? sequence;

  /// 端末時計の変更に影響されにくい、セッション開始からの経過時間。
  final int? elapsedMs;
  final DateTime t;
  final String type;
  final Map<String, dynamic> details;

  SessionDiagnosticEvent({
    this.sequence,
    this.elapsedMs,
    required this.t,
    required this.type,
    this.details = const {},
  });

  Map<String, dynamic> toJson() => {
        if (sequence != null) 'seq': sequence,
        if (elapsedMs != null) 'elapsedMs': elapsedMs,
        't': t.millisecondsSinceEpoch,
        'type': type,
        'details': details,
      };

  factory SessionDiagnosticEvent.fromJson(Map<String, dynamic> json) =>
      SessionDiagnosticEvent(
        sequence: (json['seq'] as num?)?.toInt(),
        elapsedMs: (json['elapsedMs'] as num?)?.toInt(),
        t: DateTime.fromMillisecondsSinceEpoch((json['t'] as num).toInt()),
        type: json['type'] as String? ?? 'unknown',
        details: Map<String, dynamic>.from(json['details'] as Map? ?? const {}),
      );
}

/// 診断ZIPのmanifestへ引き継ぐ、航行開始時点の構成スナップショット。
class SessionDiagnosticMetadata {
  final String appVersion;
  final String buildNumber;
  final String platform;
  final int hazardProfileVersion;
  final String hazardProfileSha256;
  final Map<String, dynamic> settingsSnapshot;

  SessionDiagnosticMetadata({
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    required this.hazardProfileVersion,
    required this.hazardProfileSha256,
    this.settingsSnapshot = const {},
  });

  Map<String, dynamic> toJson() => {
        'appVersion': appVersion,
        'buildNumber': buildNumber,
        'platform': platform,
        'hazardProfileVersion': hazardProfileVersion,
        'hazardProfileSha256': hazardProfileSha256,
        'settingsSnapshot': settingsSnapshot,
      };

  factory SessionDiagnosticMetadata.fromJson(Map<String, dynamic> json) =>
      SessionDiagnosticMetadata(
        appVersion: json['appVersion'] as String? ?? 'unknown',
        buildNumber: json['buildNumber'] as String? ?? 'unknown',
        platform: json['platform'] as String? ?? 'unknown',
        hazardProfileVersion:
            (json['hazardProfileVersion'] as num?)?.toInt() ?? 0,
        hazardProfileSha256:
            json['hazardProfileSha256'] as String? ?? 'unknown',
        settingsSnapshot: Map<String, dynamic>.from(
            json['settingsSnapshot'] as Map? ?? const {}),
      );
}

enum AlertEpisodeRating {
  tooEarly,
  appropriate,
  falseAlarm,
  positionMismatch,
  tooFrequent;

  String get displayLabel => switch (this) {
        AlertEpisodeRating.tooEarly => '早すぎる',
        AlertEpisodeRating.appropriate => '適切',
        AlertEpisodeRating.falseAlarm => '誤警告',
        AlertEpisodeRating.positionMismatch => '位置ずれ',
        AlertEpisodeRating.tooFrequent => '鳴りすぎ',
      };

  static AlertEpisodeRating? fromName(String? value) {
    for (final rating in values) {
      if (rating.name == value) return rating;
    }
    return null;
  }
}

/// 500mごとのスプリット
class Split {
  final int index; // 1始まり
  final double distanceMeters; // 実際の距離(端数区間は500未満)
  final double timeSec;

  Split(
      {required this.index,
      required this.distanceMeters,
      required this.timeSec});

  /// 500m換算ペース [秒/500m]
  double get paceSecPer500 =>
      distanceMeters > 0 ? timeSec * (500.0 / distanceMeters) : 0;

  Map<String, dynamic> toJson() =>
      {'index': index, 'distanceMeters': distanceMeters, 'timeSec': timeSec};

  factory Split.fromJson(Map<String, dynamic> json) => Split(
        index: (json['index'] as num).toInt(),
        distanceMeters: (json['distanceMeters'] as num).toDouble(),
        timeSec: (json['timeSec'] as num).toDouble(),
      );
}

/// 自動検出されたピース(漕いでいた区間)
class Piece {
  final DateTime startTime;
  final DateTime endTime;
  final double distanceMeters;
  final double durationSec;
  final double maxSpeed;
  final double? avgSpm;

  Piece({
    required this.startTime,
    required this.endTime,
    required this.distanceMeters,
    required this.durationSec,
    required this.maxSpeed,
    this.avgSpm,
  });

  double get avgPaceSecPer500 =>
      distanceMeters > 0 ? durationSec * (500.0 / distanceMeters) : 0;

  Map<String, dynamic> toJson() => {
        'startTime': startTime.millisecondsSinceEpoch,
        'endTime': endTime.millisecondsSinceEpoch,
        'distanceMeters': distanceMeters,
        'durationSec': durationSec,
        'maxSpeed': maxSpeed,
        if (avgSpm != null) 'avgSpm': avgSpm,
      };

  factory Piece.fromJson(Map<String, dynamic> json) => Piece(
        startTime: DateTime.fromMillisecondsSinceEpoch(
            (json['startTime'] as num).toInt()),
        endTime: DateTime.fromMillisecondsSinceEpoch(
            (json['endTime'] as num).toInt()),
        distanceMeters: (json['distanceMeters'] as num).toDouble(),
        durationSec: (json['durationSec'] as num).toDouble(),
        maxSpeed: (json['maxSpeed'] as num).toDouble(),
        avgSpm: (json['avgSpm'] as num?)?.toDouble(),
      );
}

/// セッションのサマリー(保存時に自動計算される)
class SessionSummary {
  final double totalDistanceMeters;
  final double durationSec;
  final double maxSpeed; // [m/s]
  final double avgSpeed; // 移動中の平均 [m/s]
  final double movingTimeSec;
  final double restTimeSec;
  final List<Split> splits250;
  final List<Split> splits;
  final List<Piece> pieces;
  final Map<String, int> alertCounts; // safetyLevel名 → 秒数(≒回数)

  SessionSummary({
    required this.totalDistanceMeters,
    required this.durationSec,
    required this.maxSpeed,
    required this.avgSpeed,
    this.movingTimeSec = 0,
    this.restTimeSec = 0,
    this.splits250 = const [],
    required this.splits,
    required this.pieces,
    required this.alertCounts,
  });

  double get avgPaceSecPer500 => avgSpeed > 0 ? 500.0 / avgSpeed : 0;

  Map<String, dynamic> toJson() => {
        'totalDistanceMeters': totalDistanceMeters,
        'durationSec': durationSec,
        'maxSpeed': maxSpeed,
        'avgSpeed': avgSpeed,
        'movingTimeSec': movingTimeSec,
        'restTimeSec': restTimeSec,
        'splits250': splits250.map((s) => s.toJson()).toList(),
        'splits': splits.map((s) => s.toJson()).toList(),
        'pieces': pieces.map((p) => p.toJson()).toList(),
        'alertCounts': alertCounts,
      };

  factory SessionSummary.fromJson(Map<String, dynamic> json) => SessionSummary(
        totalDistanceMeters: (json['totalDistanceMeters'] as num).toDouble(),
        durationSec: (json['durationSec'] as num).toDouble(),
        maxSpeed: (json['maxSpeed'] as num).toDouble(),
        avgSpeed: (json['avgSpeed'] as num).toDouble(),
        movingTimeSec: (json['movingTimeSec'] as num?)?.toDouble() ?? 0,
        restTimeSec: (json['restTimeSec'] as num?)?.toDouble() ?? 0,
        splits250: (json['splits250'] as List<dynamic>? ?? [])
            .map((s) => Split.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
        splits: (json['splits'] as List<dynamic>? ?? [])
            .map((s) => Split.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
        pieces: (json['pieces'] as List<dynamic>? ?? [])
            .map((p) => Piece.fromJson(Map<String, dynamic>.from(p)))
            .toList(),
        alertCounts: Map<String, int>.from(json['alertCounts'] ?? {}),
      );
}

/// 練習セッション
class Session {
  static const currentSchemaVersion = 3;

  final int schemaVersion;
  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final String boatTypeName;
  final String seatPosLabel;
  final List<TrackPoint> points;
  final SessionSummary summary;
  final SessionDiagnosticMetadata? diagnosticMetadata;
  final List<AlertDiagnosticEvent> alertEvents;
  final List<SessionDiagnosticEvent> diagnosticEvents;

  /// `AlertEpisode.id` → `AlertEpisodeRating.name`。
  final Map<String, String> alertEpisodeRatings;

  /// falseの場合は、航行中のチェックポイントから回復した記録。
  ///
  /// 過去バージョンのJSONにはフィールドがないため、省略時は
  /// 完了済みとして互換性を保つ。
  final bool isComplete;

  Session({
    this.schemaVersion = currentSchemaVersion,
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.boatTypeName,
    required this.seatPosLabel,
    required this.points,
    required this.summary,
    this.isComplete = true,
    this.diagnosticMetadata,
    this.alertEvents = const [],
    this.diagnosticEvents = const [],
    this.alertEpisodeRatings = const {},
  });

  Session copyWith({
    SessionSummary? summary,
    bool? isComplete,
    SessionDiagnosticMetadata? diagnosticMetadata,
    List<AlertDiagnosticEvent>? alertEvents,
    List<SessionDiagnosticEvent>? diagnosticEvents,
    Map<String, String>? alertEpisodeRatings,
  }) =>
      Session(
        schemaVersion: schemaVersion,
        id: id,
        startedAt: startedAt,
        endedAt: endedAt,
        boatTypeName: boatTypeName,
        seatPosLabel: seatPosLabel,
        points: points,
        summary: summary ?? this.summary,
        isComplete: isComplete ?? this.isComplete,
        diagnosticMetadata: diagnosticMetadata ?? this.diagnosticMetadata,
        alertEvents: alertEvents ?? this.alertEvents,
        diagnosticEvents: diagnosticEvents ?? this.diagnosticEvents,
        alertEpisodeRatings: alertEpisodeRatings ?? this.alertEpisodeRatings,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'startedAt': startedAt.millisecondsSinceEpoch,
        'endedAt': endedAt.millisecondsSinceEpoch,
        'boatTypeName': boatTypeName,
        'seatPosLabel': seatPosLabel,
        'points': points.map((p) => p.toJson()).toList(),
        'summary': summary.toJson(),
        'isComplete': isComplete,
        if (diagnosticMetadata != null)
          'diagnosticMetadata': diagnosticMetadata!.toJson(),
        if (alertEvents.isNotEmpty)
          'alertEvents': alertEvents.map((event) => event.toJson()).toList(),
        if (diagnosticEvents.isNotEmpty)
          'diagnosticEvents':
              diagnosticEvents.map((event) => event.toJson()).toList(),
        if (alertEpisodeRatings.isNotEmpty)
          'alertEpisodeRatings': alertEpisodeRatings,
      };

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
        id: json['id'] as String,
        startedAt: DateTime.fromMillisecondsSinceEpoch(
            (json['startedAt'] as num).toInt()),
        endedAt: DateTime.fromMillisecondsSinceEpoch(
            (json['endedAt'] as num).toInt()),
        boatTypeName: json['boatTypeName'] as String? ?? '',
        seatPosLabel: json['seatPosLabel'] as String? ?? '',
        points: (json['points'] as List<dynamic>? ?? [])
            .map((p) => TrackPoint.fromJson(Map<String, dynamic>.from(p)))
            .toList(),
        summary:
            SessionSummary.fromJson(Map<String, dynamic>.from(json['summary'])),
        isComplete: json['isComplete'] as bool? ?? true,
        diagnosticMetadata: json['diagnosticMetadata'] is Map
            ? SessionDiagnosticMetadata.fromJson(
                Map<String, dynamic>.from(json['diagnosticMetadata'] as Map))
            : null,
        alertEvents: (json['alertEvents'] as List<dynamic>? ?? const [])
            .map((event) => AlertDiagnosticEvent.fromJson(
                Map<String, dynamic>.from(event as Map)))
            .toList(growable: false),
        diagnosticEvents:
            (json['diagnosticEvents'] as List<dynamic>? ?? const [])
                .map((event) => SessionDiagnosticEvent.fromJson(
                    Map<String, dynamic>.from(event as Map)))
                .toList(growable: false),
        alertEpisodeRatings: Map<String, String>.from(
            json['alertEpisodeRatings'] as Map? ?? const {}),
      );
}
