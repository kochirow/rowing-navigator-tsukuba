import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/managed_hazard_model.dart';
import 'team_service.dart';

class ManagedHazardConflictException implements Exception {
  const ManagedHazardConflictException();

  @override
  String toString() => '他の端末が先に固定流木を更新しました。最新状態を取得して編集し直してください。';
}

/// 固定流木の1文書だけを必要時に読み書きする。
/// 通常航行中のlistenerやpollingは持たない。
class ManagedHazardService {
  static const collectionName = 'managed_hazards';
  static const _cacheKey = 'managed_hazard_fixed_driftwood_01_v1';

  final FirebaseFirestore? _firestore;
  final FirebaseAuth? _auth;
  final String? _teamId;

  ManagedHazardService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    String? teamId,
  })  : _firestore = firestore,
        _auth = auth,
        _teamId = teamId;

  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;
  FirebaseAuth get _firebaseAuth => _auth ?? FirebaseAuth.instance;

  String get _activeTeamId => _teamId ?? TeamService.requireActiveTeamId;

  String? get _optionalActiveTeamId =>
      _teamId ?? TeamService.activeMembership?.teamId;

  DocumentReference<Map<String, dynamic>> get _document => _db
      .collection('teams')
      .doc(_activeTeamId)
      .collection(collectionName)
      .doc(ManagedHazardState.documentId);

  String get _teamCacheKey => '${_cacheKey}_$_activeTeamId';

  Future<ManagedHazardState?> loadCached() async {
    // チーム選択前の初回画面や純粋なプリセット読込では、共有状態を
    // 参照せず同梱形状へフォールバックする。ネットワーク読書きは
    // 引き続き_activeTeamIdを要求し、チーム外へは出さない。
    final teamId = _optionalActiveTeamId;
    if (teamId == null || teamId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = '${_cacheKey}_$teamId';
    final raw = prefs.getString(cacheKey);
    if (raw == null) return null;
    try {
      return ManagedHazardState.fromCacheMap(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      await prefs.remove(cacheKey);
      return null;
    }
  }

  Future<void> cache(ManagedHazardState state) async {
    state.validate();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_teamCacheKey, jsonEncode(state.toCacheMap()));
  }

  /// 認証後の画面開始や航行開始で明示的に1回だけ呼ぶ。
  /// 文書が未作成の場合はキャッシュ（またはnull）を返す。
  Future<ManagedHazardState?> fetchLatest() async {
    final cached = await loadCached();
    final user = _firebaseAuth.currentUser;
    if (user == null) return cached;
    final snapshot = await _document.get();
    if (!snapshot.exists || snapshot.data() == null) return cached;
    final remote = ManagedHazardState.fromMap(snapshot.data()!);
    if (cached == null || remote.revision >= cached.revision) {
      await cache(remote);
      return remote;
    }
    return cached;
  }

  /// 開始時revisionが現在と同じ場合だけ、1transactionで保存する。
  Future<ManagedHazardState> save({
    required ManagedHazardState draft,
    required int expectedRevision,
  }) async {
    final user = _firebaseAuth.currentUser;
    if (user == null) {
      throw StateError('固定流木の更新にはログインが必要です。');
    }
    draft.validate();
    final saved = await _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(_document);
      ManagedHazardState? current;
      if (snapshot.exists && snapshot.data() != null) {
        current = ManagedHazardState.fromMap(snapshot.data()!);
      }
      final currentRevision = current?.revision ?? 0;
      if (currentRevision != expectedRevision) {
        throw const ManagedHazardConflictException();
      }
      final next = draft.copyWith(revision: currentRevision + 1);
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
  }
}
