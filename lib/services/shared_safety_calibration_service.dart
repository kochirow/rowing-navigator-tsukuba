import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/danger_zone_settings.dart';
import '../models/fixed_obstacle_calibration.dart';
import '../models/fixed_obstacle_warning_settings.dart';
import '../models/shared_safety_calibration.dart';
import 'danger_zone_settings_service.dart';
import 'fixed_obstacle_calibration_service.dart';
import 'fixed_obstacle_warning_settings_service.dart';
import 'team_service.dart';

class SharedSafetyCalibrationConflictException implements Exception {
  const SharedSafetyCalibrationConflictException();

  @override
  String toString() => '他の端末が先に安全設定を公開しました。最新版を取得して確認し直してください。';
}

/// 航行開始前の共有安全設定の取得結果。
///
/// ネットワーク取得の失敗を航行停止の理由にはしない。その代わり、画面と診断
/// パッケージに「今回使った共有設定が新規取得・キャッシュ・未取得のどれか」を
/// 残して、複数艇の危険形状が違った理由を後から照合できるようにする。
enum SharedSafetyFetchResult { fresh, cache, unavailable }

class SharedSafetyCalibrationFetch {
  const SharedSafetyCalibrationFetch({
    required this.result,
    required this.state,
    required this.teamIdHash,
    this.cacheAge,
  });

  final SharedSafetyFetchResult result;
  final SharedSafetyCalibrationState? state;
  final String? teamIdHash;
  final Duration? cacheAge;
}

class _CachedSharedSafetyCalibration {
  const _CachedSharedSafetyCalibration({
    required this.state,
    required this.cachedAt,
  });

  final SharedSafetyCalibrationState state;
  final DateTime? cachedAt;
}

class SharedSafetyCalibrationPermissionException implements Exception {
  const SharedSafetyCalibrationPermissionException();

  @override
  String toString() => 'チーム所属を確認できないため、安全設定を公開できません。';
}

class SharedSafetyCalibrationProfileMismatchException implements Exception {
  const SharedSafetyCalibrationProfileMismatchException();

  @override
  String toString() => '共有設定の基準データがこのアプリと異なります。アプリを更新してください。';
}

/// チーム共有の位置校正と危険範囲を1文書だけで読み書きする。
///
/// 常時listenerやpollingは内部で開始しない。[watchLatest]も、監視・航行中など
/// 呼び出し側が必要な期間だけ購読するためのcold streamである。
class SharedSafetyCalibrationService {
  static const collectionName = 'managed_hazards';
  static const _cachePrefix = 'shared_safety_calibration_v1';

  final FirebaseFirestore? _firestore;
  final FirebaseAuth? _auth;
  final String? _teamId;
  final FixedObstacleCalibrationService _localCalibrationService;
  final DangerZoneSettingsService _localDangerZoneSettingsService;
  final FixedObstacleWarningSettingsService _localWarningSettingsService;

  SharedSafetyCalibrationService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    String? teamId,
    FixedObstacleCalibrationService? localCalibrationService,
    DangerZoneSettingsService? localDangerZoneSettingsService,
    FixedObstacleWarningSettingsService? localWarningSettingsService,
  })  : _firestore = firestore,
        _auth = auth,
        _teamId = teamId,
        _localCalibrationService =
            localCalibrationService ?? FixedObstacleCalibrationService(),
        _localDangerZoneSettingsService =
            localDangerZoneSettingsService ?? DangerZoneSettingsService(),
        _localWarningSettingsService = localWarningSettingsService ??
            FixedObstacleWarningSettingsService();

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;
  FirebaseAuth get _firebaseAuth => _auth ?? FirebaseAuth.instance;
  String get _activeTeamId => _teamId ?? TeamService.requireActiveTeamId;
  String? get optionalActiveTeamId =>
      _teamId ?? TeamService.activeMembership?.teamId;

  DocumentReference<Map<String, dynamic>> get _document => _db
      .collection('teams')
      .doc(_activeTeamId)
      .collection(collectionName)
      .doc(SharedSafetyCalibrationState.documentId);

  /// profile v4向けv3文書は参照だけに残し、新規書き込みはv4へ行う。
  DocumentReference<Map<String, dynamic>> get _previousDocument => _db
      .collection('teams')
      .doc(_activeTeamId)
      .collection(collectionName)
      .doc('fixed_obstacle_calibrations_v3');

  String get _teamCacheKey => '${_cachePrefix}_$_activeTeamId';

  /// 診断・manifest用の匿名チーム識別子。生のチームIDは端末ログへ残さない。
  String? get activeTeamIdHash {
    final teamId = optionalActiveTeamId;
    if (teamId == null || teamId.isEmpty) return null;
    return sha256.convert(utf8.encode(teamId)).toString().substring(0, 8);
  }

  Future<SharedSafetyCalibrationState?> loadCached() async {
    return (await _loadCachedWithMetadata())?.state;
  }

  Future<_CachedSharedSafetyCalibration?> _loadCachedWithMetadata() async {
    final teamId = optionalActiveTeamId;
    if (teamId == null || teamId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = '${_cachePrefix}_$teamId';
    final raw = prefs.getString(cacheKey);
    if (raw == null) return null;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final state = SharedSafetyCalibrationState.fromCacheMap(map);
      if (!state.isCompatibleWithCurrentProfile) {
        await prefs.remove(cacheKey);
        return null;
      }
      final cachedAtMillis = map['cachedAtMillis'];
      return _CachedSharedSafetyCalibration(
        state: state,
        cachedAt: cachedAtMillis is int
            ? DateTime.fromMillisecondsSinceEpoch(cachedAtMillis, isUtc: true)
            : null,
      );
    } catch (_) {
      await prefs.remove(cacheKey);
      return null;
    }
  }

  Future<void> cache(SharedSafetyCalibrationState state) async {
    state.validate();
    if (!state.isCompatibleWithCurrentProfile) {
      throw const SharedSafetyCalibrationProfileMismatchException();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _teamCacheKey,
      jsonEncode({
        ...state.toCacheMap(),
        'cachedAtMillis': DateTime.now().toUtc().millisecondsSinceEpoch,
      }),
    );
  }

  /// サーバーを試したうえで、失敗時だけ既存キャッシュへ縮退する。
  ///
  /// 呼出側はこのFutureへ短いtimeoutを付けてもよい。timeout後も取得Futureは
  /// 裏で完了し得るが、成功時はcache更新だけに留まり、航行中の危険形状を
  /// 黙って置換しないのは呼出側の責務である。
  Future<SharedSafetyCalibrationFetch> fetchLatestWithStatus({
    bool forceServer = false,
  }) async {
    final cached = await _loadCachedWithMetadata();
    final teamIdHash = activeTeamIdHash;
    if (optionalActiveTeamId == null || optionalActiveTeamId!.isEmpty) {
      return SharedSafetyCalibrationFetch(
        result: SharedSafetyFetchResult.unavailable,
        state: null,
        teamIdHash: null,
      );
    }
    if (_firebaseAuth.currentUser == null) {
      return SharedSafetyCalibrationFetch(
        result: cached == null
            ? SharedSafetyFetchResult.unavailable
            : SharedSafetyFetchResult.cache,
        state: cached?.state,
        teamIdHash: teamIdHash,
        cacheAge: _cacheAge(cached?.cachedAt),
      );
    }
    try {
      final options = GetOptions(
        source: forceServer ? Source.server : Source.serverAndCache,
      );
      final snapshot = await _document.get(options);
      final state = await _acceptCurrentOrLegacy(
        snapshot,
        cached: cached?.state,
        options: options,
      );
      return SharedSafetyCalibrationFetch(
        result: SharedSafetyFetchResult.fresh,
        state: state,
        teamIdHash: teamIdHash,
      );
    } catch (_) {
      return SharedSafetyCalibrationFetch(
        result: cached == null
            ? SharedSafetyFetchResult.unavailable
            : SharedSafetyFetchResult.cache,
        state: cached?.state,
        teamIdHash: teamIdHash,
        cacheAge: _cacheAge(cached?.cachedAt),
      );
    }
  }

  Duration? _cacheAge(DateTime? cachedAt) {
    if (cachedAt == null) return null;
    final age = DateTime.now().toUtc().difference(cachedAt);
    return age.isNegative ? Duration.zero : age;
  }

  /// 必要なタイミングで1文書だけ取得する。listenerは作らない。
  ///
  /// [forceServer]をtrueにするとキャッシュへフォールバックせず、サーバーへ
  /// 更新確認を行う。revisionが変わらなければSharedPreferencesへ再書込しない。
  Future<SharedSafetyCalibrationState?> fetchLatest({
    bool forceServer = false,
  }) async {
    final cached = await loadCached();
    if (_firebaseAuth.currentUser == null) return cached;
    final options = GetOptions(
      source: forceServer ? Source.server : Source.serverAndCache,
    );
    final snapshot = await _document.get(options);
    return _acceptCurrentOrLegacy(snapshot, cached: cached, options: options);
  }

  /// 呼び出し側が購読している間だけ、チームの1文書を監視する。
  ///
  /// Firestoreは初回取得とサーバー上の文書変更時だけreadを消費し、
  /// GPSの1Hz処理とは連動しない。metadata-onlyイベントは要求しない。
  Stream<SharedSafetyCalibrationState?> watchLatest() async* {
    final cached = await loadCached();
    if (_firebaseAuth.currentUser == null) {
      yield cached;
      return;
    }
    var lastAccepted = cached;
    var isFirstEvent = true;
    await for (final snapshot in _document.snapshots()) {
      final next = snapshot.exists
          ? await _acceptSnapshot(snapshot, cached: lastAccepted)
          : isFirstEvent
              ? await _acceptPreviousSnapshot(
                  await _previousDocument.get(),
                  cached: lastAccepted,
                )
              : lastAccepted;
      if (!isFirstEvent && next?.revision == lastAccepted?.revision) continue;
      isFirstEvent = false;
      lastAccepted = next;
      yield next;
    }
  }

  Future<SharedSafetyCalibrationState> publishCalibrations({
    required Map<String, FixedObstacleCalibration> calibrations,
    required int expectedRevision,
  }) async {
    // 初回文書作成時も既存の端末内危険範囲を失わない。
    final initialDangerZones = await _localDangerZoneSettingsService.load();
    final initialWarningSettings = await _localWarningSettingsService.load();
    return publish(
      calibrations: calibrations,
      initialDangerZoneSettings: initialDangerZones,
      initialDisabledWarningSourceIds: initialWarningSettings.disabledSourceIds,
      expectedRevision: expectedRevision,
    );
  }

  Future<SharedSafetyCalibrationState> publishDangerZones({
    required DangerZoneSettings dangerZoneSettings,
    required int expectedRevision,
  }) async {
    // 初回文書作成時も既存の端末内位置校正を失わない。
    final initialCalibrations = await _localCalibrationService.loadAll();
    final initialWarningSettings = await _localWarningSettingsService.load();
    return publish(
      dangerZoneSettings: dangerZoneSettings,
      initialCalibrations: initialCalibrations,
      initialDisabledWarningSourceIds: initialWarningSettings.disabledSourceIds,
      expectedRevision: expectedRevision,
    );
  }

  Future<SharedSafetyCalibrationState> publishWarningSettings({
    required FixedObstacleWarningSettings warningSettings,
    required int expectedRevision,
  }) async {
    // 初回文書作成時も既存の端末内位置・危険範囲設定を失わない。
    final initialCalibrations = await _localCalibrationService.loadAll();
    final initialDangerZones = await _localDangerZoneSettingsService.load();
    return publish(
      disabledWarningSourceIds: warningSettings.disabledSourceIds,
      initialCalibrations: initialCalibrations,
      initialDangerZoneSettings: initialDangerZones,
      initialDisabledWarningSourceIds: warningSettings.disabledSourceIds,
      expectedRevision: expectedRevision,
    );
  }

  /// transaction内の現行値へpatchし、位置公開で危険範囲を、危険範囲公開で
  /// 位置校正を誤って上書きしない。
  Future<SharedSafetyCalibrationState> publish({
    Map<String, FixedObstacleCalibration>? calibrations,
    DangerZoneSettings? dangerZoneSettings,
    Set<String>? disabledWarningSourceIds,
    Map<String, FixedObstacleCalibration> initialCalibrations = const {},
    DangerZoneSettings? initialDangerZoneSettings,
    Set<String> initialDisabledWarningSourceIds =
        SharedSafetyCalibrationState.defaultDisabledWarningSourceIds,
    required int expectedRevision,
  }) async {
    if (calibrations == null &&
        dangerZoneSettings == null &&
        disabledWarningSourceIds == null) {
      throw ArgumentError('At least one shared safety field is required');
    }
    final user = _firebaseAuth.currentUser;
    if (user == null) {
      throw StateError('チーム安全設定の公開にはログインが必要です。');
    }
    try {
      final saved = await _db.runTransaction((transaction) async {
        final snapshot = await transaction.get(_document);
        SharedSafetyCalibrationState? current;
        if (snapshot.exists && snapshot.data() != null) {
          current = SharedSafetyCalibrationState.fromFirestoreMap(
            snapshot.data()!,
          );
          if (!current.isCompatibleWithCurrentProfile) {
            throw const SharedSafetyCalibrationProfileMismatchException();
          }
        } else {
          // 旧profile向けv3は変更せず残す。同じprofileの場合だけ引き継ぎ、
          // 座標が異なる場合は補正を誤適用せず新しいv4をrevision 1で作る。
          final previous = await transaction.get(_previousDocument);
          if (previous.exists && previous.data() != null) {
            final candidate = SharedSafetyCalibrationState.fromFirestoreMap(
              previous.data()!,
            );
            if (candidate.isCompatibleWithCurrentProfile) current = candidate;
          }
        }
        final currentRevision = current?.revision ?? 0;
        if (currentRevision != expectedRevision) {
          throw const SharedSafetyCalibrationConflictException();
        }
        final base = current ??
            SharedSafetyCalibrationState(
              calibrations: initialCalibrations,
              dangerZoneSettings: initialDangerZoneSettings,
              disabledWarningSourceIds: initialDisabledWarningSourceIds,
            );
        final next = base.copyWith(
          calibrations: calibrations,
          dangerZoneSettings: dangerZoneSettings,
          disabledWarningSourceIds: disabledWarningSourceIds,
          revision: currentRevision + 1,
          updatedAt: DateTime.now().toUtc(),
          updatedBy: user.uid,
        );
        transaction.set(
          _document,
          next.toFirestoreMap(
            updatedBy: user.uid,
            updatedAt: FieldValue.serverTimestamp(),
            previousState: current?.toPreviousStateMap(),
          ),
        );
        return next;
      });
      await cache(saved);
      return saved;
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        throw const SharedSafetyCalibrationPermissionException();
      }
      rethrow;
    }
  }

  Future<SharedSafetyCalibrationState?> _acceptSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snapshot, {
    required SharedSafetyCalibrationState? cached,
  }) async {
    if (!snapshot.exists || snapshot.data() == null) return cached;
    final remote =
        SharedSafetyCalibrationState.fromFirestoreMap(snapshot.data()!);
    if (!remote.isCompatibleWithCurrentProfile) {
      throw const SharedSafetyCalibrationProfileMismatchException();
    }
    if (cached != null && remote.revision <= cached.revision) return cached;
    await cache(remote);
    return remote;
  }

  Future<SharedSafetyCalibrationState?> _acceptCurrentOrLegacy(
    DocumentSnapshot<Map<String, dynamic>> snapshot, {
    required SharedSafetyCalibrationState? cached,
    required GetOptions options,
  }) async {
    if (snapshot.exists) return _acceptSnapshot(snapshot, cached: cached);
    return _acceptPreviousSnapshot(
      await _previousDocument.get(options),
      cached: cached,
    );
  }

  Future<SharedSafetyCalibrationState?> _acceptPreviousSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snapshot, {
    required SharedSafetyCalibrationState? cached,
  }) async {
    if (!snapshot.exists || snapshot.data() == null) return cached;
    final previous = SharedSafetyCalibrationState.fromFirestoreMap(
      snapshot.data()!,
    );
    if (!previous.isCompatibleWithCurrentProfile) return cached;
    if (cached != null && previous.revision <= cached.revision) return cached;
    await cache(previous);
    return previous;
  }
}
