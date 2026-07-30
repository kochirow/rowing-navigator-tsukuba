import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/models/static_obstacle_model.dart';

import '../config/hazard_profile_config.dart';
import '../models/ashore_area.dart';
import '../models/channel_lane.dart';
import '../models/danger_zone_settings.dart';
import '../models/fixed_obstacle_calibration.dart';
import '../models/fixed_obstacle_warning_settings.dart';
import '../models/managed_hazard_model.dart';
import '../models/navigable_water.dart';
import '../models/shared_safety_calibration.dart';
import '../utils/metric_polygon_buffer.dart';
import 'channel_centerline.dart';
import 'danger_zone_settings_service.dart';
import 'fixed_obstacle_calibration_service.dart';
import 'fixed_obstacle_warning_settings_service.dart';
import 'legacy_danger_zone_generator.dart';
import 'managed_hazard_service.dart';
import 'shared_safety_calibration_service.dart';

/// 同梱ハザードプロファイルの検証結果。
///
/// [versionMatched] は「座標差分(校正値)を適用してよいか」の意味論的な
/// 契約であり、falseなら校正値を一切適用しない。
/// [checksumMatched] は編集ミス・改変の検出であり、falseでも同梱形状の
/// 読み込み・警告判定は継続する。checksum不一致で航行機能を止めると、
/// JSONの空白1つでその日の練習全体が警告なしになるため許容しない。
class HazardProfileIntegrity {
  final bool versionMatched;
  final bool checksumMatched;
  final int? actualVersion;
  final String actualSha256;

  const HazardProfileIntegrity({
    required this.versionMatched,
    required this.checksumMatched,
    required this.actualVersion,
    required this.actualSha256,
  });

  /// 共有・端末内の座標校正値を適用してよいか。
  bool get mayApplyCalibrations => versionMatched;

  /// 完全に検証済みで、追加の注意表示が不要か。
  bool get isFullyVerified => versionMatched && checksumMatched;

  Map<String, dynamic> toJson() => {
        'versionMatched': versionMatched,
        'checksumMatched': checksumMatched,
        'expectedVersion': PresetObstacleService.expectedProfileVersion,
        if (actualVersion != null) 'actualVersion': actualVersion,
        'expectedSha256': PresetObstacleService.expectedProfileSha256,
        'actualSha256': actualSha256,
      };
}

/// 航行判定に使った危険区域幅の出所。
///
/// 同じ水面で端末ごとに危険形状が違う状態を、診断パッケージと航行計器だけで
/// 後から照合できるよう、共有設定・端末設定・コード既定値を明示的に分ける。
enum DangerZoneSettingsSource { shared, local, codeDefault }

/// [PresetObstacleService.loadPresets] が最後に解決した危険区域幅の詳細。
class DangerZoneSettingsResolution {
  const DangerZoneSettingsResolution({
    required this.source,
    required this.settings,
    this.sharedSafety,
  });

  final DangerZoneSettingsSource source;
  final DangerZoneSettings settings;
  final SharedSafetyCalibrationState? sharedSafety;

  int? get sharedSafetyRevision => sharedSafety?.revision;

  DateTime? get sharedSafetyUpdatedAt => sharedSafety?.updatedAt;
}

/// 桜川(土浦市)などのプリセット危険区域データを
/// アセット(assets/data/sakuragawa_obstacles.json)から読み込むサービス。
///
/// データの追加・修正は JSON ファイルを編集するだけでよい。
/// 基準形状は端末内に保持し、Firestoreのチーム共有文書からは
/// 検証済みの位置校正・危険範囲だけを適用する。
class PresetObstacleService {
  static const presetAssetPath = 'assets/data/sakuragawa_obstacles.json';
  static const expectedProfileVersion = currentHazardProfileDataVersion;
  static const expectedProfileSha256 = currentHazardProfileSha256;
  static const maxPolygonPoints = 1000;

  final DangerZoneSettingsService _settingsService;
  final FixedObstacleCalibrationService _calibrationService;
  final FixedObstacleWarningSettingsService _warningSettingsService;
  final LegacyDangerZoneGenerator _generator;
  final ManagedHazardService _managedHazardService;
  final SharedSafetyCalibrationService _sharedSafetyCalibrationService;
  final ManagedHazardTransformer _managedHazardTransformer;
  final MetricPolygonBuffer _polygonBuffer;
  final bool includeTestZones;
  final bool useLocalDangerZoneSettings;
  final bool useLocalFixedObstacleCalibrations;
  final bool previewLocalFixedObstacleCalibrations;
  final bool previewLocalDangerZoneSettings;

  PresetObstacleService({
    DangerZoneSettingsService? settingsService,
    FixedObstacleCalibrationService? calibrationService,
    FixedObstacleWarningSettingsService? warningSettingsService,
    LegacyDangerZoneGenerator? generator,
    ManagedHazardService? managedHazardService,
    SharedSafetyCalibrationService? sharedSafetyCalibrationService,
    ManagedHazardTransformer? managedHazardTransformer,
    MetricPolygonBuffer? polygonBuffer,
    bool? includeTestZones,
    bool? useLocalDangerZoneSettings,
    bool? useLocalFixedObstacleCalibrations,
    this.previewLocalFixedObstacleCalibrations = false,
    this.previewLocalDangerZoneSettings = false,
  })  : _settingsService = settingsService ?? DangerZoneSettingsService(),
        _calibrationService =
            calibrationService ?? FixedObstacleCalibrationService(),
        _warningSettingsService =
            warningSettingsService ?? FixedObstacleWarningSettingsService(),
        _generator = generator ?? LegacyDangerZoneGenerator(),
        _managedHazardService = managedHazardService ?? ManagedHazardService(),
        _sharedSafetyCalibrationService =
            sharedSafetyCalibrationService ?? SharedSafetyCalibrationService(),
        _managedHazardTransformer =
            managedHazardTransformer ?? const ManagedHazardTransformer(),
        _polygonBuffer = polygonBuffer ?? const MetricPolygonBuffer(),
        includeTestZones = includeTestZones ?? !kReleaseMode,
        // 現地で安全範囲を調整できることが要件のため、Releaseでも
        // 端末内設定を使う。明示的にfalseを渡すテストだけ既定値へ固定する。
        useLocalDangerZoneSettings = useLocalDangerZoneSettings ?? true,
        useLocalFixedObstacleCalibrations =
            useLocalFixedObstacleCalibrations ?? true;

  Map<String, dynamic>? _cachedProfile;
  HazardProfileIntegrity? _cachedIntegrity;
  ChannelCenterline? _cachedCenterline;
  bool _centerlineResolved = false;
  bool _centerlineDerivedFromShores = false;
  DangerZoneSettingsResolution? _lastDangerZoneSettingsResolution;
  List<String> _lastUnplottedBridgeIds = const [];
  List<_BridgePierOrphan> _lastOrphanedBridgePiers = const [];

  /// 直近に読み込んだ同梱プロファイルの検証結果。
  HazardProfileIntegrity? get lastProfileIntegrity => _cachedIntegrity;

  /// 直近の [loadPresets] で実際に使った危険区域幅と出所。
  ///
  /// 読み込みに失敗した場合は以前の有効値を残す。失敗を「既定値で安全」と
  /// 読み替えず、呼出側が直前の形状を維持するためである。
  DangerZoneSettingsResolution? get lastDangerZoneSettingsResolution =>
      _lastDangerZoneSettingsResolution;

  /// まだ橋脚が1本も紐付いていない橋。移行進捗の診断用でありfaultではない。
  List<String> get lastUnplottedBridgeIds => _lastUnplottedBridgeIds;

  /// 存在しない橋を指す橋脚。橋脚を残しつつ桁の縮退警告も残す。
  List<Map<String, String>> get lastOrphanedBridgePiers =>
      _lastOrphanedBridgePiers
          .map((pier) => {'pierId': pier.pierId, 'bridgeId': pier.bridgeId})
          .toList(growable: false);

  /// 同梱プロファイルを1度だけ読み込み・検証し、以後は再利用する。
  ///
  /// checksum不一致では例外を投げない。同じアセットに対して sha256 を
  /// 5回計算していた無駄も同時に取り除く。
  Future<Map<String, dynamic>> _loadProfile() async {
    final cached = _cachedProfile;
    if (cached != null) return cached;
    final jsonStr = await rootBundle.loadString(presetAssetPath);
    final actualChecksum = sha256.convert(utf8.encode(jsonStr)).toString();
    final data = json.decode(jsonStr) as Map<String, dynamic>;
    // 構造の検証だけは失敗させる。解釈できない形状を安全判定へ渡さない。
    _validateProfile(data);
    final actualVersion =
        data['version'] is int ? data['version'] as int : null;
    final integrity = HazardProfileIntegrity(
      versionMatched: actualVersion == expectedProfileVersion,
      checksumMatched: actualChecksum == expectedProfileSha256,
      actualVersion: actualVersion,
      actualSha256: actualChecksum,
    );
    if (!integrity.checksumMatched) {
      debugPrint(
        'Hazard profile checksum mismatch: expected $expectedProfileSha256, '
        'got $actualChecksum. Embedded shapes are still used; '
        'run tool/update_hazard_profile_hash.sh to re-verify.',
      );
    }
    if (!integrity.versionMatched) {
      debugPrint(
        'Hazard profile version mismatch: expected $expectedProfileVersion, '
        'got $actualVersion. Coordinate calibrations are not applied.',
      );
    }
    _cachedIntegrity = integrity;
    _cachedProfile = data;
    return data;
  }

  void _validatePoints(
    Object? rawPoints, {
    required String context,
    required int minimum,
  }) {
    if (rawPoints is! List ||
        rawPoints.length < minimum ||
        rawPoints.length > maxPolygonPoints) {
      throw FormatException(
          '$context points must contain $minimum-$maxPolygonPoints items');
    }
    for (var index = 0; index < rawPoints.length; index++) {
      final point = rawPoints[index];
      if (point is! Map) {
        throw FormatException('$context points[$index] must be an object');
      }
      final lat = point['lat'];
      final lng = point['lng'];
      if (lat is! num ||
          lng is! num ||
          !lat.isFinite ||
          !lng.isFinite ||
          lat < -90 ||
          lat > 90 ||
          lng < -180 ||
          lng > 180) {
        throw FormatException('$context points[$index] is out of range');
      }
    }
  }

  void _validateProfile(Map<String, dynamic> data) {
    // versionの不一致は「校正値を適用しない」根拠として扱い、
    // 形状そのものの読み込みは止めない([HazardProfileIntegrity])。
    if (data['version'] is! int) {
      throw const FormatException('Hazard profile version must be an integer');
    }
    if (data['area'] is! String || (data['area'] as String).trim().isEmpty) {
      throw const FormatException('Hazard profile area is missing');
    }
    final ids = <String>{};
    for (final group in [
      (data['dangerZoneBaselines'], 2, 'dangerZoneBaselines'),
      (data['obstacles'], 3, 'obstacles'),
    ]) {
      final items = group.$1;
      if (items is! List) {
        throw FormatException('${group.$3} must be an array');
      }
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        if (item is! Map) {
          throw FormatException('${group.$3}[$index] must be an object');
        }
        final id = item['id'];
        if (id is! String || id.isEmpty || id.length > 128 || !ids.add(id)) {
          throw FormatException(
              '${group.$3}[$index] has an invalid/duplicate id');
        }
        _validatePoints(
          item['points'],
          context: '${group.$3}[$index]',
          minimum: group.$2,
        );
      }
    }
    // 陸上エリア・航路は危険区域ではない。1件の破損で固定危険区域の
    // 読み込みまで止めないよう、詳細検証は各要素を個別スキップする
    // loadAshoreAreas/loadNavigableWaters に閉じ込める。
    final proximity = data['defaultObstacleProximityCautionMeters'];
    if (proximity is! num ||
        !proximity.isFinite ||
        proximity < 0 ||
        proximity > 100) {
      throw const FormatException('Invalid default obstacle proximity');
    }
    final practiceArea = data['practiceArea'];
    if (practiceArea != null) {
      if (practiceArea is! Map) {
        throw const FormatException('practiceArea must be an object');
      }
      _validatePoints(
        practiceArea['points'],
        context: 'practiceArea',
        minimum: 3,
      );
    }
    final operationalCoverage = data['operationalCoveragePolygon'];
    if (operationalCoverage != null) {
      if (operationalCoverage is! Map) {
        throw const FormatException(
            'operationalCoveragePolygon must be an object');
      }
      _validatePoints(
        operationalCoverage['points'],
        context: 'operationalCoveragePolygon',
        minimum: 3,
      );
    }
  }

  Future<String?> _validatedWarningAudio(Object? value) async {
    if (value == null) return null;
    if (value is! String ||
        !RegExp(r'^audio/[A-Za-z0-9._-]+\.mp3$').hasMatch(value)) {
      debugPrint('Invalid warningAudio path ignored: $value');
      return null;
    }
    try {
      await rootBundle.load('assets/$value');
      return value;
    } catch (e) {
      // 個別ファイルの誤記で警告全体を無音にせず、
      // kindごとの標準音へフォールバックさせる。
      debugPrint('Missing warningAudio asset ignored: $value $e');
      return null;
    }
  }

  /// アセットの JSON からプリセット危険区域を読み込む
  /// 同梱プロファイルへ実際に適用する座標校正値を解決する。
  ///
  /// [loadPresets] と [loadShoreBaselines] が同じ校正値を使うために切り出した。
  /// ここがずれると、危険区域と岸の基準線が別の場所を指すことになる。
  Future<Map<String, FixedObstacleCalibration>> _resolveCalibrations(
    HazardProfileIntegrity integrity,
    SharedSafetyCalibrationState? sharedSafety,
  ) async {
    // 通常表示は共有確定版を優先し、位置・範囲をlocal下書きへ加算しない。
    // 共有文書がまだ一度も公開されていないチームだけは、既存版からの
    // 移行互換として検証済みlocal値へフォールバックする。
    final localCalibrations = useLocalFixedObstacleCalibrations
        ? await _calibrationService.loadAll()
        : const <String, FixedObstacleCalibration>{};
    // 座標差分を別バージョンのプロファイルへ適用するのは危険なため、
    // versionが一致しないときだけ校正値を落とす。checksumのみの不一致
    // (誤って空白を入れた等)では、既に現地で合わせた形状を維持する。
    if (!integrity.mayApplyCalibrations) {
      return const <String, FixedObstacleCalibration>{};
    }
    if (previewLocalFixedObstacleCalibrations) return localCalibrations;
    return sharedSafety?.calibrations ?? localCalibrations;
  }

  /// 陸上エリア（警告停止エリア）を読む。危険区域・校正対象ではない。
  /// 1件が壊れていても残りの有効なエリアは使い、全件欠損なら音を止めない。
  Future<List<AshoreArea>> loadAshoreAreas() async {
    final data = await _loadProfile();
    final areas = <AshoreArea>[];
    final rawAreas = data['ashoreAreas'];
    if (rawAreas == null) return const <AshoreArea>[];
    if (rawAreas is! List) {
      debugPrint('Invalid ashoreAreas array ignored.');
      return const <AshoreArea>[];
    }
    for (final raw in rawAreas) {
      try {
        areas.add(AshoreArea.fromJson(Map<String, dynamic>.from(raw as Map)));
      } catch (error) {
        debugPrint('Invalid ashore area skipped: $error');
      }
    }
    return List.unmodifiable(areas);
  }

  /// 表示・作図検証用の航路。衝突判定と陸上判定には渡さない。
  Future<List<NavigableWater>> loadNavigableWaters() async {
    final data = await _loadProfile();
    final waters = <NavigableWater>[];
    final rawWaters = data['navigableWaters'];
    if (rawWaters == null) return const <NavigableWater>[];
    if (rawWaters is! List) {
      debugPrint('Invalid navigableWaters array ignored.');
      return const <NavigableWater>[];
    }
    for (final raw in rawWaters) {
      try {
        waters.add(NavigableWater.fromJson(
          Map<String, dynamic>.from(raw as Map),
        ));
      } catch (error) {
        debugPrint('Invalid navigable water skipped: $error');
      }
    }
    return List.unmodifiable(waters);
  }

  /// 安全判定用の、向きが検証済みの航路レーンを読む。
  ///
  /// 表示用の [loadNavigableWaters] と契約を分ける。不正な1件で航行開始を
  /// 妨げず、全件が不正なら空として従来の `cross` 符号方式へ縮退する。
  Future<List<ChannelLane>> loadChannelLanes() async {
    final data = await _loadProfile();
    final lanes = <ChannelLane>[];
    final rawWaters = data['navigableWaters'];
    if (rawWaters == null) return const <ChannelLane>[];
    if (rawWaters is! List) {
      debugPrint('Invalid navigableWaters array ignored for channel lanes.');
      return const <ChannelLane>[];
    }
    for (final raw in rawWaters) {
      try {
        final map = Map<String, dynamic>.from(raw as Map);
        if (map['kind'] != 'lane') continue;
        lanes.add(ChannelLane.fromJson(map));
      } catch (error) {
        debugPrint('Invalid channel lane skipped: $error');
      }
    }
    return List.unmodifiable(lanes);
  }

  Future<List<StaticObstacle>> loadPresets({
    bool refreshManagedHazards = false,
  }) async {
    final data = await _loadProfile();
    final integrity = _cachedIntegrity!;
    SharedSafetyCalibrationState? sharedSafety;
    try {
      sharedSafety = await _sharedSafetyCalibrationService.loadCached();
    } catch (error) {
      // 共有cache破損時も同梱プリセット（または移行前のlocal設定）を残す。
      debugPrint('Shared safety calibration cache ignored: $error');
    }
    final localDangerZoneLoad = useLocalDangerZoneSettings
        ? await _settingsService.loadWithSource()
        : LocalDangerZoneSettingsLoad(
            settings: DangerZoneSettings.defaults(),
            hasStoredValues: false,
          );
    final localDangerZoneSettings = localDangerZoneLoad.settings;
    final calibrations = await _resolveCalibrations(integrity, sharedSafety);
    final shouldUseShared =
        !previewLocalDangerZoneSettings && sharedSafety != null;
    final dangerZoneSettings = shouldUseShared
        ? sharedSafety.dangerZoneSettings
        : localDangerZoneSettings;
    _lastDangerZoneSettingsResolution = DangerZoneSettingsResolution(
      source: shouldUseShared
          ? DangerZoneSettingsSource.shared
          : localDangerZoneLoad.hasStoredValues
              ? DangerZoneSettingsSource.local
              : DangerZoneSettingsSource.codeDefault,
      settings: dangerZoneSettings,
      sharedSafety: shouldUseShared ? sharedSafety : null,
    );
    FixedObstacleWarningSettings warningSettings;
    try {
      final localWarningSettings = await _warningSettingsService.load();
      warningSettings = FixedObstacleWarningSettings(
        disabledSourceIds: sharedSafety?.disabledWarningSourceIds ??
            localWarningSettings.disabledSourceIds,
      );
    } catch (error) {
      // 警告対象の端末設定が壊れても、既定値（島2のみ対象外）で継続する。
      debugPrint('Fixed obstacle warning settings ignored: $error');
      warningSettings = FixedObstacleWarningSettings();
    }
    final obstacles = <StaticObstacle>[];
    final bridgeBaselineIds = <String>{
      for (final raw
          in data['dangerZoneBaselines'] as List<dynamic>? ?? const [])
        if (raw is Map && raw['kind'] == DangerZoneKind.bridge.name)
          if (raw['id'] is String) raw['id'] as String,
    };
    final bridgeIdsWithPiers = <String>{};
    final orphanedPiers = <_BridgePierOrphan>[];
    for (final raw in data['obstacles'] as List<dynamic>? ?? const []) {
      if (raw is! Map || raw['kind'] != StaticObstacleKind.bridgePier.name) {
        continue;
      }
      final bridgeId = raw['bridgeId'];
      final pierId = raw['id'];
      if (bridgeId is! String || bridgeId.isEmpty || pierId is! String) {
        continue;
      }
      if (bridgeBaselineIds.contains(bridgeId)) {
        bridgeIdsWithPiers.add(bridgeId);
      } else {
        orphanedPiers.add(_BridgePierOrphan(pierId, bridgeId));
      }
    }
    _lastUnplottedBridgeIds = bridgeBaselineIds
        .where((id) => !bridgeIdsWithPiers.contains(id))
        .toList(growable: false);
    _lastOrphanedBridgePiers = List.unmodifiable(orphanedPiers);
    for (final entry in (data['obstacles'] as List<dynamic>? ?? []).indexed) {
      final index = entry.$1;
      final item = entry.$2;
      final map = item as Map<String, dynamic>;
      final kind = StaticObstacleKind.fromJson(map['kind'] as String?);
      if (!includeTestZones && kind == StaticObstacleKind.testZone) continue;
      final warningAudio = await _validatedWarningAudio(map['warningAudio']);
      final sourceId = map['id'] as String? ?? 'default_$index';
      final sourcePoints = (map['points'] as List<dynamic>)
          .map<LatLng>((p) => LatLng(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ))
          .toList();
      final points = _calibrationService.translatePoints(
        sourcePoints,
        calibrations[sourceId] ?? const FixedObstacleCalibration(),
      );
      if (points.length < 3) continue; // 不正なポリゴンはスキップ
      obstacles.add(StaticObstacle(
        id: sourceId,
        sourceId: sourceId,
        bridgeId: kind == StaticObstacleKind.bridgePier
            ? map['bridgeId'] as String?
            : null,
        name: map['name'] as String?,
        points: points,
        isDefault: true,
        isWarningEnabled: warningSettings.isEnabled(sourceId),
        kind: kind,
        warningAudioAsset: warningAudio,
      ));
    }
    // プロファイルの値は「kind別の既定値を上書きする指定」として扱う。
    // 0 は「指定なし=kind別の既定値を使う」を意味する。警告そのものを
    // 止めたい区域は FixedObstacleWarningSettings で外すこと。
    final rawProximityCaution =
        (data['defaultObstacleProximityCautionMeters'] as num? ?? 0).toDouble();
    final proximityCautionDistance =
        rawProximityCaution > 0 ? rawProximityCaution : null;
    final baselines = <DangerZoneBaseline>[];
    for (final item
        in data['dangerZoneBaselines'] as List<dynamic>? ?? const []) {
      final raw = Map<String, dynamic>.from(item as Map);
      if (!includeTestZones && raw['kind'] == 'testZone') continue;
      final warningAudio = await _validatedWarningAudio(raw['warningAudio']);
      if (warningAudio == null) {
        raw.remove('warningAudio');
      } else {
        raw['warningAudio'] = warningAudio;
      }
      final sourceBaseline = DangerZoneBaseline.fromJson(raw);
      final calibration =
          calibrations[sourceBaseline.id] ?? const FixedObstacleCalibration();
      if (sourceBaseline.kind == DangerZoneKind.driftwood) {
        // 閉じた流木外周は辺ごとのリボンにせず、内側全体を1枚で塗る。
        ManagedHazardState? managedState;
        try {
          managedState = refreshManagedHazards
              ? await _managedHazardService.fetchLatest()
              : await _managedHazardService.loadCached();
        } catch (e) {
          // オフラインやRules未適用でも同梱形状を必ず残す。
          debugPrint(
              'Managed driftwood refresh failed; using cache/default: $e');
          try {
            managedState = await _managedHazardService.loadCached();
          } catch (cacheError) {
            debugPrint(
              'Managed driftwood cache is unavailable; using default: '
              '$cacheError',
            );
          }
        }
        managedState ??= ManagedHazardState.forBaseShape(sourceBaseline.points);
        final localMargin =
            dangerZoneSettings[DangerZoneKind.driftwood].waterSideMeters;
        final managedShape = _managedHazardTransformer.transform(
          sourceBaseline.points,
          managedState,
        );
        // 適用順は「共有形状 → 端末位置校正 → 端末余白」。
        // 端末余白は校正値や共有余裕へ合算せず、最終形状の各辺からの
        // 実距離として独立に適用する。
        final calibratedShape = _calibrationService.translatePoints(
          managedShape,
          calibration,
        );
        final localHazardShape = _polygonBuffer.expand(
          calibratedShape,
          localMargin,
        );
        obstacles.add(StaticObstacle(
          id: ManagedHazardState.documentId,
          sourceId: sourceBaseline.id,
          name: sourceBaseline.name,
          points: localHazardShape,
          isDefault: true,
          isWarningEnabled: warningSettings.isEnabled(sourceBaseline.id),
          isManaged: true,
          proximityCautionDistanceMeters: proximityCautionDistance,
          kind: StaticObstacleKind.driftwood,
          warningAudioAsset: sourceBaseline.warningAudioAsset,
        ));
        continue;
      }
      final calibratedBaseline = DangerZoneBaseline(
        id: sourceBaseline.id,
        name: sourceBaseline.name,
        kind: sourceBaseline.kind,
        points: _calibrationService.translatePoints(
          sourceBaseline.points,
          calibration,
        ),
        warningAudioAsset: sourceBaseline.warningAudioAsset,
      );
      // 橋脚がプロット済みでも、橋全体の警告帯は常に残す。
      // 橋と橋脚は別候補として同じ警告パイプラインへ渡し、
      // 重なった場合の音声選択だけをAlertStateMachineで調停する。
      baselines.add(calibratedBaseline);
    }
    if (baselines.isNotEmpty) {
      obstacles.addAll(_generator.generate(
        baselines: baselines,
        settings: dangerZoneSettings,
        proximityCautionDistanceMeters: proximityCautionDistance,
        disabledWarningSourceIds: warningSettings.disabledSourceIds,
      ));
    }
    return obstacles;
  }

  /// 現地校正画面で選択するプリセット単位を返す。
  ///
  /// 画面へ返す点は元データのままにし、保存済み補正量と分離して扱う。
  Future<List<FixedObstacleCalibrationTarget>> loadCalibrationTargets() async {
    final data = await _loadProfile();
    final targets = <FixedObstacleCalibrationTarget>[];
    for (final raw
        in data['dangerZoneBaselines'] as List<dynamic>? ?? const []) {
      final map = Map<String, dynamic>.from(raw as Map);
      final baseline = DangerZoneBaseline.fromJson(map);
      if (!includeTestZones && baseline.kind == DangerZoneKind.testZone) {
        continue;
      }
      var sourcePoints = baseline.points;
      if (baseline.kind == DangerZoneKind.driftwood) {
        ManagedHazardState? managedState;
        try {
          managedState = await _managedHazardService.loadCached();
        } catch (error) {
          debugPrint(
            'Managed driftwood calibration preview is using the default '
            'shape: $error',
          );
        }
        managedState ??= ManagedHazardState.forBaseShape(baseline.points);
        // 校正画面の基準線には共有形状だけを返す。実際の障害物Polygonは
        // loadPresetsで校正後に端末余白を適用している。
        sourcePoints = _managedHazardTransformer.transform(
          baseline.points,
          managedState,
        );
      }
      targets.add(FixedObstacleCalibrationTarget(
        sourceId: baseline.id,
        name: baseline.name,
        kind: _staticKindForDangerZone(baseline.kind),
        sourcePoints: sourcePoints,
      ));
    }
    for (final raw in data['obstacles'] as List<dynamic>? ?? const []) {
      final map = Map<String, dynamic>.from(raw as Map);
      final kind = StaticObstacleKind.fromJson(map['kind'] as String?);
      if (!includeTestZones && kind == StaticObstacleKind.testZone) continue;
      targets.add(FixedObstacleCalibrationTarget(
        sourceId: map['id'] as String,
        name: map['name'] as String? ?? kind.displayLabel,
        kind: kind,
        sourcePoints: (map['points'] as List<dynamic>)
            .map((point) => LatLng(
                  (point['lat'] as num).toDouble(),
                  (point['lng'] as num).toDouble(),
                ))
            .toList(growable: false),
      ));
    }
    targets.sort((a, b) {
      final kind = a.kind.index.compareTo(b.kind.index);
      return kind != 0 ? kind : a.name.compareTo(b.name);
    });
    return targets;
  }

  StaticObstacleKind _staticKindForDangerZone(DangerZoneKind kind) {
    switch (kind) {
      case DangerZoneKind.shore:
        return StaticObstacleKind.shore;
      case DangerZoneKind.bridge:
        return StaticObstacleKind.bridge;
      case DangerZoneKind.island:
        return StaticObstacleKind.island;
      case DangerZoneKind.driftwood:
        return StaticObstacleKind.driftwood;
      case DangerZoneKind.testZone:
        return StaticObstacleKind.testZone;
    }
  }

  /// 直近に読み込んだ中心線が、明示プロットではなく岸からの自動導出か。
  ///
  /// 自動導出は中州を貫通しうるため暫定手段である。明示プロットへ移行したら
  /// [_deriveCenterlineFromShores] ごと削除してよい。
  bool get isChannelCenterlineDerivedFromShores => _centerlineDerivedFromShores;

  /// 航路中心線を読み込む。
  ///
  /// 明示プロットした `channelCenterline` を最優先で使う。
  ///
  /// 明示が無い間は、左右の岸基準線からの自動導出へ縮退する。
  /// 自動導出は中州を貫通しうるので恒久的な手段ではないが、
  /// **中心線がまったく無い状態は直線予測になり、5m/sで7〜10秒先(35〜50m)が
  /// カーブで外岸へ5m以上膨らんで蛇行区間のたびに音が鳴る**(原則4)。
  /// 中州を避けきれない中心線のほうが、中心線が無いよりはるかにましである。
  ///
  /// 明示プロットを同梱したら [isChannelCenterlineDerivedFromShores] が false に
  /// なる。全区間で false を確認できた時点で、この自動導出を削除すること。
  Future<ChannelCenterline?> loadChannelCenterline() async {
    final cached = _cachedCenterline;
    if (cached != null) return cached;
    if (_centerlineResolved) return null;
    _centerlineResolved = true;
    try {
      final data = await _loadProfile();
      final explicit = data['channelCenterline'];
      if (explicit is Map && explicit['points'] is List) {
        final points = (explicit['points'] as List)
            .whereType<Map>()
            .where((point) => point['lat'] is num && point['lng'] is num)
            .map((point) => LatLng(
                  (point['lat'] as num).toDouble(),
                  (point['lng'] as num).toDouble(),
                ))
            .toList(growable: false);
        _cachedCenterline = ChannelCenterline.fromPolyline(points);
        if (_cachedCenterline != null) {
          _centerlineDerivedFromShores = false;
          return _cachedCenterline;
        }
      }

      final derived = _deriveCenterlineFromShores(data);
      if (derived != null) {
        _cachedCenterline = derived;
        _centerlineDerivedFromShores = true;
        debugPrint('Channel centerline is not configured; '
            'falling back to shoreline-derived centerline. '
            'Plot channelCenterline explicitly.');
        return derived;
      }

      debugPrint('Channel centerline is not configured and cannot be derived; '
          'falling back to straight-line prediction.');
      return null;
    } catch (error) {
      // 中心線が作れなくても直線予測で警告は継続する。
      debugPrint('Channel centerline is unavailable; '
          'falling back to straight-line prediction: $error');
      return null;
    }
  }

  /// 左右の岸基準線から中心線を導出する暫定経路。
  /// 明示プロットが同梱されるまでのつなぎであり、恒久的な仕様ではない。
  ChannelCenterline? _deriveCenterlineFromShores(Map<String, dynamic> data) {
    final shores = <List<LatLng>>[];
    for (final raw
        in data['dangerZoneBaselines'] as List<dynamic>? ?? const []) {
      final map = Map<String, dynamic>.from(raw as Map);
      if (map['kind'] != DangerZoneKind.shore.name) continue;
      shores.add(DangerZoneBaseline.fromJson(map).points);
    }
    if (shores.length < 2) return null;
    // 最も長い2本を左右の岸とみなす。
    shores.sort((a, b) => b.length.compareTo(a.length));
    return ChannelCenterline.fromShorelines(
      firstShore: shores[0],
      secondShore: shores[1],
    );
  }

  /// プリセットの練習水域(ジオフェンス)を読み込む。
  /// JSONに practiceArea が定義されていない場合はnullを返す。
  /// コーチモードでの「水域から出た艇」の検知に使用する。
  Future<List<LatLng>?> loadPracticeArea() async {
    final data = await _loadProfile();
    final area = data['practiceArea'];
    if (area == null) return null;
    final points = ((area as Map<String, dynamic>)['points'] as List<dynamic>)
        .map<LatLng>((p) => LatLng(
              (p['lat'] as num).toDouble(),
              (p['lng'] as num).toDouble(),
            ))
        .toList();
    if (points.length < 3) return null;
    return points;
  }

  /// 固定危険区域の網羅性を確認済みの運用対象水域を読み込む。
  /// コーチ用の[loadPracticeArea]とは用途も承認基準も異なる。
  Future<List<LatLng>?> loadOperationalCoverage() async {
    final data = await _loadProfile();
    final coverage = data['operationalCoveragePolygon'];
    if (coverage == null) return null;
    return ((coverage as Map<String, dynamic>)['points'] as List<dynamic>)
        .map<LatLng>((point) => LatLng(
              (point['lat'] as num).toDouble(),
              (point['lng'] as num).toDouble(),
            ))
        .toList(growable: false);
  }

  /// 固定流木の変形プレビュー用に、同梱した未変形の閉じた外周を返す。
  Future<List<LatLng>> loadManagedDriftwoodBaseShape() async {
    final data = await _loadProfile();
    for (final raw in data['dangerZoneBaselines'] as List<dynamic>) {
      final map = Map<String, dynamic>.from(raw as Map);
      if (map['kind'] == DangerZoneKind.driftwood.name) {
        return DangerZoneBaseline.fromJson(map).points;
      }
    }
    throw const FormatException('Managed driftwood baseline is missing');
  }
}

class _BridgePierOrphan {
  const _BridgePierOrphan(this.pierId, this.bridgeId);

  final String pierId;
  final String bridgeId;
}
