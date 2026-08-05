import 'package:cloud_firestore/cloud_firestore.dart';

import '../config/hazard_profile_config.dart';
import '../config/risk_evaluator_config.dart' as risk;
import 'danger_zone_settings.dart';
import 'fixed_obstacle_calibration.dart';
import 'shared_safety_calibration.g.dart';

/// Firestoreで1チーム1文書として共有する、固定障害物の確定設定。
///
/// 位置校正と危険範囲を同じ文書にまとめることで、航行中の更新確認を
/// 1 document read（または1 listener）で完了できる。
class SharedSafetyCalibrationState {
  /// v9は桟橋エリア追加を含むprofile v9専用。旧profile向けの頂点
  /// 差分を新しい座標へ誤適用しないよう、v8以前とは文書を分離する。
  static const documentId = 'fixed_obstacle_calibrations_v9';
  static const kind = 'fixed_obstacle_calibrations';

  /// 現地確認により、現在使っていない旧ポリゴン2件を初期状態で
  /// 警告対象から外す。航路中心線ベースの逆走判定はこの設定とは別経路。
  ///
  /// 共有文書がまだないチームと、旧形式の共有文書を読む端末でも、安全側の
  /// 初期設定を一貫して使えるようここで定義する。
  static const defaultDisabledWarningSourceIds = <String>{
    'reverse_main_channel',
    'island_upstream',
  };

  /// 現行プリセットに含まれる、校正可能なsourceId。
  ///
  /// Firestore Rulesでも同じ一覧をallowlistにし、任意の巨大mapや
  /// 未知の障害物IDを書き込めないようにする。
  static const allowedSourceIds = generatedAllowedSourceIds;

  /// 同梱プロフィールv9の各基準線・Polygonの頂点数。
  ///
  /// 頂点補正はこの固定レイアウトに対する差分だけを共有する。基準
  /// プロフィールのversion/hashが変われば、別レイアウトを誤適用しない。
  static const vertexPointCounts = generatedVertexPointCounts;

  final int baseProfileVersion;
  final String baseProfileSha256;
  final Map<String, FixedObstacleCalibration> calibrations;
  final DangerZoneSettings dangerZoneSettings;
  final Set<String> disabledWarningSourceIds;
  final double primaryWarningLeadSeconds;
  final double advanceWarningLeadSeconds;
  final int revision;
  final DateTime? updatedAt;
  final String? updatedBy;

  SharedSafetyCalibrationState({
    this.baseProfileVersion = currentHazardProfileDataVersion,
    this.baseProfileSha256 = currentHazardProfileSha256,
    Map<String, FixedObstacleCalibration> calibrations = const {},
    DangerZoneSettings? dangerZoneSettings,
    Set<String> disabledWarningSourceIds = defaultDisabledWarningSourceIds,
    this.primaryWarningLeadSeconds = risk.primaryWarningLeadSeconds,
    this.advanceWarningLeadSeconds = risk.advanceWarningLeadSeconds,
    this.revision = 0,
    this.updatedAt,
    this.updatedBy,
  })  : calibrations = Map.unmodifiable(
          Map<String, FixedObstacleCalibration>.from(calibrations)
            ..removeWhere((_, value) => value.isZero),
        ),
        dangerZoneSettings =
            dangerZoneSettings ?? DangerZoneSettings.defaults(),
        disabledWarningSourceIds =
            Set.unmodifiable(Set<String>.from(disabledWarningSourceIds)) {
    validate();
  }

  bool get isCompatibleWithCurrentProfile =>
      baseProfileVersion == currentHazardProfileDataVersion &&
      baseProfileSha256 == currentHazardProfileSha256;

  factory SharedSafetyCalibrationState.fromFirestoreMap(
    Map<String, dynamic> map,
  ) {
    if (map['kind'] != kind) {
      throw const FormatException('Invalid shared safety calibration kind');
    }
    final updatedAt = map['updatedAt'];
    final updatedBy = map['updatedBy'];
    return SharedSafetyCalibrationState(
      baseProfileVersion:
          _requiredInt(map['baseProfileVersion'], 'baseProfileVersion'),
      baseProfileSha256:
          _requiredString(map['baseProfileSha256'], 'baseProfileSha256'),
      calibrations: _calibrationsFromFirestoreMap(
        map['scaledOffsets'],
        map['scaledVertexOffsets'],
      ),
      dangerZoneSettings: _dangerZoneSettingsFromMap(map['dangerZoneOffsets']),
      disabledWarningSourceIds: _disabledWarningSourceIdsFromMap(
        map['disabledWarningSourceIds'],
      ),
      primaryWarningLeadSeconds: _requiredDouble(
        map['primaryWarningLeadSeconds'],
        'primaryWarningLeadSeconds',
      ),
      advanceWarningLeadSeconds: _requiredDouble(
        map['advanceWarningLeadSeconds'],
        'advanceWarningLeadSeconds',
      ),
      revision: _requiredInt(map['revision'], 'revision'),
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
      updatedBy: updatedBy is String ? updatedBy : null,
    );
  }

  /// v2の固定長配列を読むためだけの互換入口。新しいv3文書では使わない。
  factory SharedSafetyCalibrationState.fromLegacyFirestoreMap(
    Map<String, dynamic> map,
  ) {
    if (map['kind'] != kind) {
      throw const FormatException(
          'Invalid legacy shared safety calibration kind');
    }
    final updatedAt = map['updatedAt'];
    final updatedBy = map['updatedBy'];
    return SharedSafetyCalibrationState(
      baseProfileVersion:
          _requiredInt(map['baseProfileVersion'], 'baseProfileVersion'),
      baseProfileSha256:
          _requiredString(map['baseProfileSha256'], 'baseProfileSha256'),
      calibrations: _calibrationsFromLegacyFirestoreList(
        map['scaledOffsets'],
        map['scaledVertexOffsets'],
      ),
      dangerZoneSettings: _dangerZoneSettingsFromMap(map['dangerZoneOffsets']),
      disabledWarningSourceIds: _disabledWarningSourceIdsFromMap(
        map['disabledWarningSourceIds'],
      ),
      primaryWarningLeadSeconds: map['primaryWarningLeadSeconds'] == null
          ? risk.primaryWarningLeadSeconds
          : _requiredDouble(
              map['primaryWarningLeadSeconds'],
              'primaryWarningLeadSeconds',
            ),
      advanceWarningLeadSeconds: map['advanceWarningLeadSeconds'] == null
          ? risk.advanceWarningLeadSeconds
          : _requiredDouble(
              map['advanceWarningLeadSeconds'],
              'advanceWarningLeadSeconds',
            ),
      revision: _requiredInt(map['revision'], 'revision'),
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
      updatedBy: updatedBy is String ? updatedBy : null,
    );
  }

  factory SharedSafetyCalibrationState.fromCacheMap(
    Map<String, dynamic> map,
  ) {
    final updatedAtMillis = map['updatedAtMillis'];
    return SharedSafetyCalibrationState(
      baseProfileVersion:
          _requiredInt(map['baseProfileVersion'], 'baseProfileVersion'),
      baseProfileSha256:
          _requiredString(map['baseProfileSha256'], 'baseProfileSha256'),
      calibrations: _calibrationsFromMap(map['calibrations']),
      dangerZoneSettings: _dangerZoneSettingsFromMap(map['dangerZoneOffsets']),
      disabledWarningSourceIds: _disabledWarningSourceIdsFromMap(
        map['disabledWarningSourceIds'],
      ),
      primaryWarningLeadSeconds: _requiredDouble(
        map['primaryWarningLeadSeconds'],
        'primaryWarningLeadSeconds',
      ),
      advanceWarningLeadSeconds: _requiredDouble(
        map['advanceWarningLeadSeconds'],
        'advanceWarningLeadSeconds',
      ),
      revision: _requiredInt(map['revision'], 'revision'),
      updatedAt: updatedAtMillis is int
          ? DateTime.fromMillisecondsSinceEpoch(updatedAtMillis, isUtc: true)
          : null,
      updatedBy: map['updatedBy'] is String ? map['updatedBy'] as String : null,
    );
  }

  SharedSafetyCalibrationState copyWith({
    Map<String, FixedObstacleCalibration>? calibrations,
    DangerZoneSettings? dangerZoneSettings,
    Set<String>? disabledWarningSourceIds,
    double? primaryWarningLeadSeconds,
    double? advanceWarningLeadSeconds,
    int? revision,
    DateTime? updatedAt,
    String? updatedBy,
  }) {
    return SharedSafetyCalibrationState(
      baseProfileVersion: baseProfileVersion,
      baseProfileSha256: baseProfileSha256,
      calibrations: calibrations ?? this.calibrations,
      dangerZoneSettings: dangerZoneSettings ?? this.dangerZoneSettings,
      disabledWarningSourceIds:
          disabledWarningSourceIds ?? this.disabledWarningSourceIds,
      primaryWarningLeadSeconds:
          primaryWarningLeadSeconds ?? this.primaryWarningLeadSeconds,
      advanceWarningLeadSeconds:
          advanceWarningLeadSeconds ?? this.advanceWarningLeadSeconds,
      revision: revision ?? this.revision,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }

  Map<String, dynamic> toFirestoreMap({
    required String updatedBy,
    required Object updatedAt,
    Map<String, dynamic>? previousState,
  }) {
    validate();
    return {
      'kind': kind,
      'baseProfileVersion': baseProfileVersion,
      'baseProfileSha256': baseProfileSha256,
      'scaledOffsets': _calibrationsToFirestoreMap(calibrations),
      'scaledVertexOffsets': _vertexOffsetsToFirestoreMap(calibrations),
      'dangerZoneOffsets': _dangerZoneSettingsToMap(dangerZoneSettings),
      'disabledWarningSourceIds': _disabledWarningSourceIdsToList(
        disabledWarningSourceIds,
      ),
      'primaryWarningLeadSeconds': primaryWarningLeadSeconds,
      'advanceWarningLeadSeconds': advanceWarningLeadSeconds,
      'revision': revision,
      'updatedAt': updatedAt,
      'updatedBy': updatedBy,
      if (previousState != null) 'previousState': previousState,
    };
  }

  Map<String, dynamic> toPreviousStateMap() => {
        'scaledOffsets': _calibrationsToFirestoreMap(calibrations),
        'scaledVertexOffsets': _vertexOffsetsToFirestoreMap(calibrations),
        'dangerZoneOffsets': _dangerZoneSettingsToMap(dangerZoneSettings),
        'disabledWarningSourceIds': _disabledWarningSourceIdsToList(
          disabledWarningSourceIds,
        ),
        'primaryWarningLeadSeconds': primaryWarningLeadSeconds,
        'advanceWarningLeadSeconds': advanceWarningLeadSeconds,
        'revision': revision,
      };

  Map<String, dynamic> toCacheMap() => {
        'baseProfileVersion': baseProfileVersion,
        'baseProfileSha256': baseProfileSha256,
        'calibrations': _calibrationsToMap(calibrations),
        'dangerZoneOffsets': _dangerZoneSettingsToMap(dangerZoneSettings),
        'disabledWarningSourceIds': _disabledWarningSourceIdsToList(
          disabledWarningSourceIds,
        ),
        'primaryWarningLeadSeconds': primaryWarningLeadSeconds,
        'advanceWarningLeadSeconds': advanceWarningLeadSeconds,
        'revision': revision,
        if (updatedAt != null)
          'updatedAtMillis': updatedAt!.toUtc().millisecondsSinceEpoch,
        if (updatedBy != null) 'updatedBy': updatedBy,
      };

  void validate() {
    if (baseProfileVersion < 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(baseProfileSha256) ||
        revision < 0 ||
        calibrations.length > allowedSourceIds.length) {
      throw const FormatException('Invalid shared safety calibration header');
    }
    for (final entry in calibrations.entries) {
      if (!allowedSourceIds.contains(entry.key) ||
          entry.value.isZero ||
          !entry.value.northMeters.isFinite ||
          !entry.value.eastMeters.isFinite ||
          entry.value.northMeters.abs() >
              FixedObstacleCalibration.maxAbsoluteOffsetMeters ||
          entry.value.eastMeters.abs() >
              FixedObstacleCalibration.maxAbsoluteOffsetMeters) {
        throw const FormatException(
          'Invalid shared fixed obstacle calibration',
        );
      }
      final pointCount = vertexPointCounts[entry.key];
      if (pointCount == null || entry.value.vertexOffsets.length > pointCount) {
        throw const FormatException('Invalid shared vertex offset count');
      }
      for (final pointOffset in entry.value.vertexOffsets.entries) {
        final offset = pointOffset.value;
        if (pointOffset.key < 0 ||
            pointOffset.key >= pointCount ||
            !offset.northMeters.isFinite ||
            !offset.eastMeters.isFinite ||
            offset.northMeters.abs() >
                FixedObstacleCalibration.maxAbsoluteOffsetMeters ||
            offset.eastMeters.abs() >
                FixedObstacleCalibration.maxAbsoluteOffsetMeters) {
          throw const FormatException('Invalid shared vertex offset');
        }
      }
    }
    for (final dangerKind in DangerZoneKind.values) {
      final offsets = dangerZoneSettings[dangerKind];
      if (!offsets.waterSideMeters.isFinite ||
          !offsets.landSideMeters.isFinite ||
          offsets.waterSideMeters < minDangerZoneOffsetMeters ||
          offsets.waterSideMeters > maxDangerZoneOffsetMeters ||
          offsets.landSideMeters < minDangerZoneOffsetMeters ||
          offsets.landSideMeters > maxDangerZoneOffsetMeters) {
        throw const FormatException('Invalid shared danger-zone offsets');
      }
    }
    if (disabledWarningSourceIds.length > allowedSourceIds.length ||
        !allowedSourceIds.containsAll(disabledWarningSourceIds)) {
      throw const FormatException('Invalid shared disabled warning source IDs');
    }
    if (!primaryWarningLeadSeconds.isFinite ||
        !advanceWarningLeadSeconds.isFinite ||
        primaryWarningLeadSeconds < risk.minPrimaryWarningLeadSeconds ||
        advanceWarningLeadSeconds > risk.maxWarningTimeSeconds ||
        advanceWarningLeadSeconds < risk.minWarningTimeSeconds ||
        primaryWarningLeadSeconds >= advanceWarningLeadSeconds) {
      throw const FormatException('Invalid shared warning lead times');
    }
  }

  static Map<String, FixedObstacleCalibration> _calibrationsFromMap(
    Object? raw,
  ) {
    if (raw is! Map) {
      throw const FormatException('calibrations must be a map');
    }
    final result = <String, FixedObstacleCalibration>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('Invalid calibration entry');
      }
      final calibration = FixedObstacleCalibration.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      if (!calibration.isZero) {
        result[entry.key as String] = calibration;
      }
    }
    return result;
  }

  /// v3: 個々のsourceIdを独立して読む。未知キー・壊れた頂点配列は、その
  /// キーだけを無視し、他の現地校正を失わない。
  static Map<String, FixedObstacleCalibration> _calibrationsFromFirestoreMap(
    Object? rawOffsets,
    Object? rawVertexOffsets,
  ) {
    if (rawOffsets is! Map) {
      throw const FormatException('Invalid calibration offset map');
    }
    final result = <String, FixedObstacleCalibration>{};
    for (final entry in rawOffsets.entries) {
      if (entry.key is! String ||
          !allowedSourceIds.contains(entry.key) ||
          entry.value is! GeoPoint) {
        continue;
      }
      final offset = entry.value as GeoPoint;
      final calibration = FixedObstacleCalibration(
        northMeters: offset.latitude / 3,
        eastMeters: offset.longitude / 6,
      );
      if (!calibration.isZero) result[entry.key as String] = calibration;
    }
    if (rawVertexOffsets is! Map) return result;
    for (final entry in rawVertexOffsets.entries) {
      if (entry.key is! String ||
          !allowedSourceIds.contains(entry.key) ||
          entry.value is! List) {
        continue;
      }
      final sourceId = entry.key as String;
      final rawList = entry.value as List;
      final count = vertexPointCounts[sourceId];
      if (count == null || rawList.length != count) continue;
      final offsets = <int, FixedObstacleVertexOffset>{};
      var valid = true;
      for (var index = 0; index < rawList.length; index++) {
        final rawOffset = rawList[index];
        if (rawOffset is! GeoPoint) {
          valid = false;
          break;
        }
        final offset = FixedObstacleVertexOffset(
          northMeters: rawOffset.latitude / 3,
          eastMeters: rawOffset.longitude / 6,
        );
        if (!offset.isZero) offsets[index] = offset;
      }
      if (!valid) continue;
      final current = result[sourceId] ?? const FixedObstacleCalibration();
      final next = current.copyWith(vertexOffsets: offsets);
      if (next.isZero) {
        result.remove(sourceId);
      } else {
        result[sourceId] = next;
      }
    }
    return result;
  }

  static Map<String, FixedObstacleCalibration>
      _calibrationsFromLegacyFirestoreList(
    Object? rawOffsets,
    Object? rawVertexOffsets,
  ) {
    if (rawOffsets is! List || rawOffsets.length != allowedSourceIds.length) {
      throw const FormatException('Invalid calibration offset list');
    }
    final expectedIds = allowedSourceIds.toList(growable: false);
    final result = <String, FixedObstacleCalibration>{};
    for (var index = 0; index < expectedIds.length; index++) {
      final offset = rawOffsets[index];
      if (offset is! GeoPoint) {
        throw const FormatException('Invalid scaled calibration offset');
      }
      final calibration = FixedObstacleCalibration(
        northMeters: offset.latitude / 3,
        eastMeters: offset.longitude / 6,
      );
      if (!calibration.isZero) result[expectedIds[index]] = calibration;
    }
    // v3までに公開された文書には頂点差分がない。読み取り時だけは
    // 既存の全体補正を維持し、v4で再公開した時点で頂点形式へ移行する。
    if (rawVertexOffsets == null) return result;
    if (rawVertexOffsets is! Map) {
      throw const FormatException('Invalid vertex calibration offsets');
    }
    for (final entry in rawVertexOffsets.entries) {
      if (entry.key is! String ||
          !allowedSourceIds.contains(entry.key) ||
          entry.value is! List) {
        throw const FormatException('Invalid vertex calibration entry');
      }
      final sourceId = entry.key as String;
      final count = vertexPointCounts[sourceId]!;
      final rawList = entry.value as List;
      if (rawList.length != count) {
        throw const FormatException('Invalid vertex calibration point count');
      }
      final offsets = <int, FixedObstacleVertexOffset>{};
      for (var index = 0; index < rawList.length; index++) {
        final rawOffset = rawList[index];
        if (rawOffset is! GeoPoint) {
          throw const FormatException('Invalid scaled vertex offset');
        }
        final offset = FixedObstacleVertexOffset(
          northMeters: rawOffset.latitude / 3,
          eastMeters: rawOffset.longitude / 6,
        );
        if (!offset.isZero) offsets[index] = offset;
      }
      final current = result[sourceId] ?? const FixedObstacleCalibration();
      final next = current.copyWith(vertexOffsets: offsets);
      if (next.isZero) {
        result.remove(sourceId);
      } else {
        result[sourceId] = next;
      }
    }
    return result;
  }

  /// Rulesの式数上限を超えず全21件の±30mを検証するため、GeoPointの
  /// 組込み値域（緯度±90・経度±180）へ3倍/6倍して格納する。
  /// sourceId順はbase profile version/hashで固定される。
  static Map<String, GeoPoint> _calibrationsToFirestoreMap(
    Map<String, FixedObstacleCalibration> calibrations,
  ) =>
      {
        for (final entry in calibrations.entries)
          if (!entry.value.isZero)
            entry.key: GeoPoint(
              entry.value.northMeters * 3,
              entry.value.eastMeters * 6,
            ),
      };

  static Map<String, List<GeoPoint>> _vertexOffsetsToFirestoreMap(
    Map<String, FixedObstacleCalibration> calibrations,
  ) =>
      {
        for (final entry in calibrations.entries)
          if (entry.value.vertexOffsets.isNotEmpty)
            entry.key: [
              for (var index = 0;
                  index < vertexPointCounts[entry.key]!;
                  index++)
                GeoPoint(
                  entry.value.vertexOffsetFor(index).northMeters * 3,
                  entry.value.vertexOffsetFor(index).eastMeters * 6,
                ),
            ],
      };

  static Map<String, dynamic> _calibrationsToMap(
    Map<String, FixedObstacleCalibration> calibrations,
  ) =>
      {
        // 端末cacheもFirestoreと同じくsource ID mapで保持する。
        for (final entry in calibrations.entries)
          entry.key: entry.value.toJson(),
      };

  static DangerZoneSettings _dangerZoneSettingsFromMap(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('dangerZoneOffsets must be a map');
    }
    final map = Map<String, dynamic>.from(raw);
    final settings = <DangerZoneKind, DangerZoneOffsets>{};
    for (final kind in DangerZoneKind.values) {
      final value = map[kind.name];
      if (value is! Map) {
        throw FormatException('Missing danger-zone offsets: ${kind.name}');
      }
      final item = Map<String, dynamic>.from(value);
      settings[kind] = DangerZoneOffsets(
        waterSideMeters:
            _requiredDouble(item['waterSideMeters'], 'waterSideMeters'),
        landSideMeters:
            _requiredDouble(item['landSideMeters'], 'landSideMeters'),
      );
    }
    return DangerZoneSettings(settings);
  }

  static Map<String, dynamic> _dangerZoneSettingsToMap(
    DangerZoneSettings settings,
  ) =>
      {
        for (final kind in DangerZoneKind.values)
          kind.name: {
            'waterSideMeters': settings[kind].waterSideMeters,
            'landSideMeters': settings[kind].landSideMeters,
          },
      };

  static Set<String> _disabledWarningSourceIdsFromMap(Object? raw) {
    // v2の既存共有文書にはこの項目がないため、移行中も従来の初期値を
    // 適用する。次回の公開時に新しい形式へ更新される。
    if (raw == null) return defaultDisabledWarningSourceIds;
    if (raw is! List ||
        raw.any(
          (value) => value is! String || !allowedSourceIds.contains(value),
        )) {
      throw const FormatException('Invalid shared disabled warning source IDs');
    }
    return raw.cast<String>().toSet();
  }

  static List<String> _disabledWarningSourceIdsToList(Set<String> sourceIds) {
    final values = sourceIds.toList()..sort();
    return values;
  }

  static int _requiredInt(Object? value, String name) {
    if (value is! int) throw FormatException('$name must be an int');
    return value;
  }

  static String _requiredString(Object? value, String name) {
    if (value is! String) throw FormatException('$name must be a string');
    return value;
  }

  static double _requiredDouble(Object? value, String name) {
    if (value is! num || !value.isFinite) {
      throw FormatException('$name must be finite');
    }
    return value.toDouble();
  }
}
