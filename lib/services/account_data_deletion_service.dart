import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/managed_hazard_model.dart';
import 'managed_hazard_service.dart';
import 'firebase_usage_budget.dart';
import 'session_store_service.dart';
import 'practice_log_store_service.dart';
import 'static_obstacle_service.dart';
import 'team_service.dart';

/// Firebase匿名アカウントと、端末内の関連データを削除する。
///
/// 個人の位置と危険区域更新を残したままAuthだけを削除しないよう、
/// リモート整理→Auth削除→端末内削除の順で実行する。
class AccountDataDeletionService {
  static const deletedAccountMarker = 'deleted-account';

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  AccountDataDeletionService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  Future<void> deleteCurrentAccountAndData() async {
    final user = _auth.currentUser;
    if (user != null) {
      final uid = user.uid;
      final teamService = TeamService(auth: _auth, firestore: _firestore);
      final membership =
          TeamService.activeMembership ?? await teamService.restoreMembership();
      if (membership != null) {
        await _deleteAuthoredTemporaryObstacles(uid, membership.teamId);
        await _anonymizeTemporaryObstacleEdits(uid, membership.teamId);
        await _anonymizeManagedHazardEdit(uid, membership.teamId);
        await teamService.detachForAccountDeletion();
      }
      await user.delete();
    }

    await SessionStoreService().deleteAllSessions();
    await PracticeLogStoreService().deleteAllPracticeLogs();
    await _deleteTemporaryExports();
    final preferences = await SharedPreferences.getInstance();
    await preferences.clear();
  }

  CollectionReference<Map<String, dynamic>> _temporaryObstacles(
    String teamId,
  ) =>
      _firestore
          .collection('teams')
          .doc(teamId)
          .collection(StaticObstacleService.collectionName);

  Future<void> _deleteAuthoredTemporaryObstacles(
    String uid,
    String teamId,
  ) async {
    while (true) {
      final snapshot = await _temporaryObstacles(teamId)
          .where('createdBy', isEqualTo: uid)
          .limit(FirebaseUsageBudget.maxTemporaryObstaclesPerSync)
          .get();
      if (snapshot.docs.isEmpty) return;
      final batch = _firestore.batch();
      for (final document in snapshot.docs) {
        batch.delete(document.reference);
      }
      await batch.commit();
    }
  }

  Future<void> _anonymizeTemporaryObstacleEdits(
    String uid,
    String teamId,
  ) async {
    while (true) {
      final snapshot = await _temporaryObstacles(teamId)
          .where('updatedBy', isEqualTo: uid)
          .limit(FirebaseUsageBudget.maxTemporaryObstaclesPerSync)
          .get();
      if (snapshot.docs.isEmpty) return;
      final batch = _firestore.batch();
      for (final document in snapshot.docs) {
        batch.update(document.reference, {
          'confirmedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': deletedAccountMarker,
        });
      }
      await batch.commit();
    }
  }

  Future<void> _anonymizeManagedHazardEdit(
    String uid,
    String teamId,
  ) async {
    final reference = _firestore
        .collection('teams')
        .doc(teamId)
        .collection(ManagedHazardService.collectionName)
        .doc(ManagedHazardState.documentId);
    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(reference);
      final data = snapshot.data();
      if (!snapshot.exists || data == null || data['updatedBy'] != uid) return;

      final current = ManagedHazardState.fromMap(data);
      final anonymized = current.copyWith(revision: current.revision + 1);
      transaction.set(
        reference,
        anonymized.toFirestoreMap(
          updatedBy: deletedAccountMarker,
          updatedAt: FieldValue.serverTimestamp(),
          previousState: current.toPreviousStateMap(),
        ),
      );
    });
  }

  Future<void> _deleteTemporaryExports() async {
    final directory = await getTemporaryDirectory();
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is File &&
          (entity.path.endsWith('.gpx') ||
              entity.path.endsWith('.csv') ||
              entity.path.endsWith('.zip')) &&
          (entity.uri.pathSegments.last.startsWith('rowing_') ||
              entity.uri.pathSegments.last.startsWith('practice_'))) {
        await entity.delete();
      }
    }
  }
}
