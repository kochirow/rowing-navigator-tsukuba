import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart' hide Transaction;
import 'package:firebase_database/firebase_database.dart' as rtdb
    show Transaction;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/navigator_config.dart';
import '../config/store_config.dart';
import '../models/team_model.dart';

class AlreadyInTeamException implements Exception {
  const AlreadyInTeamException();

  @override
  String toString() => 'すでに別のチームに参加しています。';
}

class InvalidInviteCodeException implements Exception {
  const InvalidInviteCodeException();

  @override
  String toString() => '招待コードが正しくありません。';
}

class TeamMembershipInconsistentException implements Exception {
  const TeamMembershipInconsistentException();

  @override
  String toString() => 'チーム所属データが一致しません。再試行してください。';
}

class TermsNotAcceptedException implements Exception {
  const TermsNotAcceptedException();

  @override
  String toString() => '利用規約への同意が必要です。';
}

class NotTeamAdministratorException implements Exception {
  const NotTeamAdministratorException();

  @override
  String toString() => 'この操作はチーム管理者だけが実行できます。';
}

class CannotRemoveTeamAdministratorException implements Exception {
  const CannotRemoveTeamAdministratorException();

  @override
  String toString() => 'チーム管理者はこの画面から削除できません。';
}

class TeamManagementSyncException implements Exception {
  const TeamManagementSyncException();

  @override
  String toString() => 'チーム管理の反映を完了できませんでした。通信を確認して再試行してください。';
}

/// 認証情報が失われたときにだけ表示する、再参加用の端末内ヒント。
///
/// 有効なFirebase認証やチーム所属の代わりには使わず、必ず招待コードで
/// Firestore/RTDBの所属を作り直す。部分的に壊れたキャッシュは採用しない。
class TeamRecoveryHint {
  final String teamName;
  final String inviteCode;

  const TeamRecoveryHint({
    required this.teamName,
    required this.inviteCode,
  });

  static TeamRecoveryHint? fromCachedValues({
    required String? teamName,
    required String? inviteCode,
  }) {
    final normalizedName = teamName?.trim();
    if (normalizedName == null ||
        normalizedName.isEmpty ||
        normalizedName.length > 40 ||
        inviteCode == null ||
        !TeamInviteCode.isValid(inviteCode)) {
      return null;
    }
    return TeamRecoveryHint(
      teamName: normalizedName,
      inviteCode: TeamInviteCode.normalize(inviteCode),
    );
  }
}

/// 所属復元に失敗した際、過去キャッシュを使ってよいかを限定する方針。
class TeamRestoreErrorPolicy {
  static bool allowsOfflineCache(String code) =>
      code == 'unavailable' ||
      code == 'deadline-exceeded' ||
      // Sparkのquota到達でも、検証済みの同一UID所属で端末内の
      // マップ・固定危険区域・記録までは継続できるようにする。
      code == 'resource-exhausted' ||
      // App Check/Rules/Auth token側が一時的に拒否しても、現在のAuth UIDと
      // 検証済みcache UIDが一致する場合はローカル機能だけ継続する。
      // サーバーデータへの権限はRulesが拒否したままなので拡大しない。
      code == 'permission-denied' ||
      code == 'unauthenticated';
}

/// 約59bitの固定招待コード。
///
/// 読み間違いを防ぐため 0/1/I/L/O/U を使わない。チーム作成時に
/// RTDB transactionで衝突を検査し、作成後は変更しない。既存チームの
/// 20文字コードも引き続き受理し、更新後に再参加不能にならないようにする。
class TeamInviteCode {
  static const int length = 12;
  static const int legacyLength = 20;
  static const String _alphabet = '23456789ABCDEFGHJKMNPQRSTVWXYZ';

  static String generate([Random? random]) {
    final source = random ?? Random.secure();
    return List.generate(
      length,
      (_) => _alphabet[source.nextInt(_alphabet.length)],
      growable: false,
    ).join();
  }

  static String normalize(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

  static bool isValid(String value) {
    final normalized = normalize(value);
    return (normalized.length == length || normalized.length == legacyLength) &&
        normalized.split('').every(_alphabet.contains);
  }

  static String format(String value) {
    final normalized = normalize(value);
    if (normalized.length == length) {
      return List.generate(
        3,
        (index) => normalized.substring(index * 4, index * 4 + 4),
        growable: false,
      ).join('-');
    }
    if (normalized.length == legacyLength) {
      return List.generate(
        4,
        (index) => normalized.substring(index * 5, index * 5 + 5),
        growable: false,
      ).join('-');
    }
    return normalized;
  }
}

/// Firestoreのチーム所属を権威とし、RTDBに位置共有用の
/// 最小membership bridgeを持つ。Cloud Functionsは使わずSpark無料枠内で動作する。
class TeamService {
  static const _deletedAccountMarker = 'deleted-account';
  static const _cachedTeamIdKey = 'active_team_id_v1';
  static const _cachedTeamNameKey = 'active_team_name_v1';
  static const _cachedInviteCodeKey = 'active_team_invite_code_v1';
  static const _cachedCreatedByKey = 'active_team_created_by_v1';
  static const _cachedTeamUserIdKey = 'active_team_user_id_v1';
  static const _recoveryTeamNameKey = 'recovery_team_name_v1';
  static const _recoveryInviteCodeKey = 'recovery_team_invite_code_v1';
  static TeamMembership? _activeMembership;
  static TeamRecoveryHint? _recoveryHint;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FirebaseDatabase _database;
  final Random _random;

  TeamService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseDatabase? database,
    Random? random,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _database = database ??
            (realtimeDatabaseUrl.isEmpty
                ? FirebaseDatabase.instance
                : FirebaseDatabase.instanceFor(
                    app: Firebase.app(),
                    databaseURL: realtimeDatabaseUrl,
                  )),
        _random = random ?? Random.secure();

  static TeamMembership? get activeMembership => _activeMembership;

  /// 認証喪失時の再参加画面にだけ使う。所属済みとはみなさない。
  static TeamRecoveryHint? get recoveryHint => _recoveryHint;

  String? get currentUserId => _auth.currentUser?.uid;

  /// 起動時の端末保存認証の復元完了と、その後の意図しない認証喪失を通知する。
  Stream<String?> get authenticationUserIds =>
      _auth.authStateChanges().map((user) => user?.uid).distinct();

  /// 所属が管理者により削除されたことを、起動中の端末でも検知する。
  /// Rulesの拒否だけに頼らず、オンラインなら直ちに参加画面へ戻せるようにする。
  Stream<bool> watchMembershipExists(String uid) =>
      _firestore.collection('users').doc(uid).snapshots().map(
            (snapshot) => snapshot.exists,
          );

  static String get requireActiveTeamId {
    final value = _activeMembership?.teamId;
    if (value == null || value.isEmpty) {
      throw StateError('チームへの参加が必要です。');
    }
    return value;
  }

  /// 初回画面の判定の前に呼ぶ。Firestoreローカルキャッシュからも
  /// 復元できるため、短い圏外からの再起動でもチーム画面に戻りにくい。
  Future<TeamMembership?> restoreMembership() async {
    // currentUserの即時参照だけでは、Firebase Authが端末保存認証を
    // 復元している途中のnullと、本当の未認証を区別できない。
    // native SDKが最初の認証状態を確定してから所属を判定する。
    final user = await _auth.authStateChanges().first;
    if (user == null) {
      await _clearActive(preserveRecoveryHint: true);
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final cachedTeamId = prefs.getString(_cachedTeamIdKey);
    try {
      final userDocument =
          await _firestore.collection('users').doc(user.uid).get();
      final data = userDocument.data();
      final teamId = data?['teamId'];
      if (!userDocument.exists || teamId is! String || teamId.isEmpty) {
        await _clearActive(preserveRecoveryHint: true);
        return null;
      }
      if (cachedTeamId != null && cachedTeamId != teamId) {
        await _clearActive();
      }
      return await _loadAndActivate(
        teamId,
        user.uid,
        allowOfflineBridge: true,
      );
    } on FirebaseException catch (error) {
      // permission-denied/unauthenticatedでも自動signOutはしない。
      // App CheckやRulesの誤設定で、復元可能な匿名UIDを破棄しないため。
      // authStateChangesが実際にnullになった場合だけ上の再参加導線へ進む。
      if (!TeamRestoreErrorPolicy.allowsOfflineCache(error.code)) rethrow;
      // Authとチームは過去にサーバー確認済みの組み合わせだけ
      // 復元する。圏外中もマップと自端末GPSは使え、共有は各
      // Firebase listenerが明示的に受信不可を通知する。
      final cached = _restoreCachedMembership(user.uid, prefs);
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<TeamMembership> createTeam(
    String rawName, {
    required bool acceptedTerms,
  }) async {
    final name = rawName.trim();
    if (name.isEmpty || name.length > 40) {
      throw ArgumentError.value(rawName, 'name', 'must be 1-40 characters');
    }
    if (!acceptedTerms) throw const TermsNotAcceptedException();
    final user = await _ensureUser();
    await _throwIfAlreadyInTeam(user.uid);

    // RTDB側の招待コードをtransactionで先に予約する。
    // 万一Firestore書込み前に終了しても、予約はデータを読む
    // 権限を与えず、同一ユーザーの再試行で修復できる。
    for (var attempt = 0; attempt < 8; attempt++) {
      final teamId = _firestore.collection('teams').doc().id;
      final inviteCode = TeamInviteCode.generate(_random);
      final reserved = await _reserveRtdbInvite(
        inviteCode: inviteCode,
        teamId: teamId,
        uid: user.uid,
      );
      if (!reserved) continue;

      try {
        await _firestore.runTransaction((transaction) async {
          final userReference = _firestore.collection('users').doc(user.uid);
          final teamReference = _firestore.collection('teams').doc(teamId);
          final inviteReference =
              _firestore.collection('invite_codes').doc(inviteCode);
          final memberReference =
              teamReference.collection('members').doc(user.uid);
          final snapshots = await Future.wait([
            transaction.get(userReference),
            transaction.get(inviteReference),
          ]);
          if (snapshots[0].exists) throw const AlreadyInTeamException();
          if (snapshots[1].exists) {
            throw const InvalidInviteCodeException();
          }
          transaction.set(teamReference, {
            'name': name,
            'inviteCode': inviteCode,
            'createdBy': user.uid,
            'adminUid': user.uid,
            'createdAt': FieldValue.serverTimestamp(),
          });
          transaction.set(inviteReference, {
            'teamId': teamId,
            'createdBy': user.uid,
            'createdAt': FieldValue.serverTimestamp(),
          });
          transaction.set(memberReference, {
            'inviteCode': inviteCode,
            'joinedAt': FieldValue.serverTimestamp(),
            'termsVersion': teamTermsVersion,
            'termsAcceptedAt': FieldValue.serverTimestamp(),
          });
          transaction.set(userReference, {
            'teamId': teamId,
            'joinedAt': FieldValue.serverTimestamp(),
            'termsVersion': teamTermsVersion,
            'termsAcceptedAt': FieldValue.serverTimestamp(),
          });
        });
        await _activateRtdbMembership(
          uid: user.uid,
          teamId: teamId,
          inviteCode: inviteCode,
        );
        return _activate(
          TeamMembership(
            team: RowingTeam(
              id: teamId,
              name: name,
              inviteCode: inviteCode,
              createdBy: user.uid,
              adminUid: user.uid,
            ),
            userId: user.uid,
          ),
        );
      } on AlreadyInTeamException {
        await _releaseRtdbInviteReservation(
          inviteCode: inviteCode,
          teamId: teamId,
        );
        rethrow;
      } on InvalidInviteCodeException {
        // クロスサービスの過去の不整合による衝突も新しい
        // 約59bitのコードで再試行する。
        await _releaseRtdbInviteReservation(
          inviteCode: inviteCode,
          teamId: teamId,
        );
        continue;
      }
    }
    throw StateError('招待コードを安全に作成できませんでした。');
  }

  Future<TeamMembership> joinTeam(
    String rawInviteCode, {
    required bool acceptedTerms,
  }) async {
    final inviteCode = TeamInviteCode.normalize(rawInviteCode);
    if (!TeamInviteCode.isValid(inviteCode)) {
      throw const InvalidInviteCodeException();
    }
    if (!acceptedTerms) throw const TermsNotAcceptedException();
    final user = await _ensureUser();
    await _throwIfAlreadyInTeam(user.uid);
    late String teamId;

    await _firestore.runTransaction((transaction) async {
      final userReference = _firestore.collection('users').doc(user.uid);
      final inviteReference =
          _firestore.collection('invite_codes').doc(inviteCode);
      final userSnapshot = await transaction.get(userReference);
      final inviteSnapshot = await transaction.get(inviteReference);
      if (userSnapshot.exists) throw const AlreadyInTeamException();
      final inviteData = inviteSnapshot.data();
      final rawTeamId = inviteData?['teamId'];
      if (!inviteSnapshot.exists || rawTeamId is! String || rawTeamId.isEmpty) {
        throw const InvalidInviteCodeException();
      }
      teamId = rawTeamId;
      final teamReference = _firestore.collection('teams').doc(teamId);
      transaction.set(teamReference.collection('members').doc(user.uid), {
        'inviteCode': inviteCode,
        'joinedAt': FieldValue.serverTimestamp(),
        'termsVersion': teamTermsVersion,
        'termsAcceptedAt': FieldValue.serverTimestamp(),
      });
      transaction.set(userReference, {
        'teamId': teamId,
        'joinedAt': FieldValue.serverTimestamp(),
        'termsVersion': teamTermsVersion,
        'termsAcceptedAt': FieldValue.serverTimestamp(),
      });
    });

    await _activateRtdbMembership(
      uid: user.uid,
      teamId: teamId,
      inviteCode: inviteCode,
    );
    return _loadAndActivate(teamId, user.uid);
  }

  /// 現在のチームだけを退出する。
  ///
  /// 匿名Firebaseアカウントや端末内の練習記録、チームそのものは消さない。
  /// Firestoreではusersとmembersを同一transactionで削除し、RTDBでは
  /// 位置共有用bridgeと自分の現在地をまとめて削除する。
  Future<void> leaveTeam() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('チームを退出するための認証情報を確認できません。');
    }

    final userReference = _firestore.collection('users').doc(user.uid);
    var teamId = _activeMembership?.teamId;

    await _firestore.runTransaction((transaction) async {
      final userSnapshot = await transaction.get(userReference);
      if (!userSnapshot.exists) return;

      final storedTeamId = userSnapshot.data()?['teamId'];
      if (storedTeamId is! String || storedTeamId.isEmpty) {
        throw const TeamMembershipInconsistentException();
      }
      teamId = storedTeamId;
      transaction.delete(
        _firestore
            .collection('teams')
            .doc(storedTeamId)
            .collection('members')
            .doc(user.uid),
      );
      transaction.delete(userReference);
    });

    // Firestore側で既に所属が消えていた場合でも、端末に残ったRTDBの
    // 位置情報だけは、最後に有効だったteamIdを使って安全に掃除する。
    if (teamId != null && teamId!.isNotEmpty) {
      await _database.ref().update({
        'teams/$teamId/live_positions/${user.uid}': null,
        'teams/$teamId/boat_profiles/${user.uid}': null,
        'team_users/${user.uid}': null,
        'team_members/$teamId/${user.uid}': null,
      });
    }
    await _clearActive();
  }

  /// 管理者だけが、現在の招待コードを無効化して新しいコードへ替える。
  ///
  /// Firestoreでは古い招待文書の削除と新しい招待文書の作成をtransactionで
  /// 原子的に行う。RTDBも同一multi-location updateで置き換えるため、
  /// 新旧コードが共に有効な状態を残さない。
  Future<TeamMembership> rotateInviteCode() => _changeInviteCode();

  /// 管理者がメンバーをチームから外す。
  ///
  /// 削除と同時に招待コードを更新する。外された端末が古いコードを知っていても
  /// 再参加できず、Firestoreの所属・RTDBの位置共有bridge/艇情報も消える。
  Future<TeamMembership> removeMember(String memberUid) {
    if (memberUid.isEmpty) {
      throw ArgumentError.value(memberUid, 'memberUid', 'must not be empty');
    }
    return _changeInviteCode(memberUidToRemove: memberUid);
  }

  Stream<List<TeamMemberSummary>> watchManagedTeamMembers() {
    final membership = _activeMembership;
    if (membership == null || !membership.isAdministrator) {
      return Stream<List<TeamMemberSummary>>.error(
        const NotTeamAdministratorException(),
      );
    }
    return _firestore
        .collection('teams')
        .doc(membership.teamId)
        .collection('members')
        .orderBy('joinedAt')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(
                (document) => TeamMemberSummary.fromFirestore(
                  document.id,
                  document.data(),
                ),
              )
              .toList(growable: false),
        );
  }

  /// アカウント削除用。位置を消してからRTDB bridgeと
  /// Firestore所属を外す。通常の「チーム退会」としては公開しない。
  Future<void> detachForAccountDeletion() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final userReference = _firestore.collection('users').doc(user.uid);
    final userSnapshot = await userReference.get();
    final teamId = userSnapshot.data()?['teamId'];
    if (teamId is! String || teamId.isEmpty) {
      await _clearActive();
      return;
    }

    final active = _activeMembership;
    final rtdbUpdates = <String, Object?>{
      'teams/$teamId/live_positions/${user.uid}': null,
      'teams/$teamId/boat_profiles/${user.uid}': null,
      'team_users/${user.uid}': null,
      'team_members/$teamId/${user.uid}': null,
    };
    if (active?.teamId == teamId && active?.team.createdBy == user.uid) {
      final inviteCode = active?.inviteCode;
      rtdbUpdates['team_meta/$teamId/ownerUid'] = _deletedAccountMarker;
      if (inviteCode != null && inviteCode.isNotEmpty) {
        rtdbUpdates['team_invites/$inviteCode/ownerUid'] =
            _deletedAccountMarker;
      }
    }
    // 4種類の所属/共有データと所有者匿名化を一度にcommit。
    // 通信断で片側だけ消える状態を作らない。
    await _database.ref().update(rtdbUpdates);
    await _firestore.runTransaction((transaction) async {
      final latestUser = await transaction.get(userReference);
      final latestTeamId = latestUser.data()?['teamId'];
      if (!latestUser.exists || latestTeamId != teamId) return;
      final teamReference = _firestore.collection('teams').doc(teamId);
      final memberReference = _firestore
          .collection('teams')
          .doc(teamId)
          .collection('members')
          .doc(user.uid);
      final teamSnapshot = await transaction.get(teamReference);
      final teamInviteCode = teamSnapshot.data()?['inviteCode'];
      DocumentReference<Map<String, dynamic>>? inviteReference;
      DocumentSnapshot<Map<String, dynamic>>? inviteSnapshot;
      if (teamInviteCode is String && teamInviteCode.isNotEmpty) {
        inviteReference =
            _firestore.collection('invite_codes').doc(teamInviteCode);
        inviteSnapshot = await transaction.get(inviteReference);
      }
      if (teamSnapshot.data()?['createdBy'] == user.uid) {
        transaction.update(teamReference, {
          'createdBy': _deletedAccountMarker,
        });
      }
      if (inviteReference != null &&
          inviteSnapshot?.data()?['createdBy'] == user.uid) {
        transaction.update(inviteReference, {
          'createdBy': _deletedAccountMarker,
        });
      }
      transaction.delete(memberReference);
      transaction.delete(userReference);
    });
    await _clearActive();
  }

  Future<User> _ensureUser() async {
    final current = _auth.currentUser;
    if (current != null) return current;
    final credential = await _auth.signInAnonymously();
    final user = credential.user;
    if (user == null) throw StateError('匿名認証に失敗しました。');
    return user;
  }

  Future<void> _throwIfAlreadyInTeam(String uid) async {
    final snapshot = await _firestore.collection('users').doc(uid).get();
    if (snapshot.exists) throw const AlreadyInTeamException();
  }

  Future<bool> _reserveRtdbInvite({
    required String inviteCode,
    required String teamId,
    required String uid,
  }) async {
    final metaReference = _database.ref('team_meta/$teamId');
    try {
      // teamIdはFirestoreのランダムID。create-only Rules付きsetなので
      // 既存metaを上書きしない。transactionは初回creatorにもread権限を
      // 要求するため使わない。
      await metaReference.set({
        'inviteCode': inviteCode,
        'ownerUid': uid,
        'createdAt': ServerValue.timestamp,
      });
    } on FirebaseException {
      return false;
    }
    try {
      final result = await _database
          .ref('team_invites/$inviteCode')
          .runTransaction((current) {
        if (current != null) return rtdb.Transaction.abort();
        return rtdb.Transaction.success({
          'teamId': teamId,
          'ownerUid': uid,
          'createdAt': ServerValue.timestamp,
        });
      }, applyLocally: false);
      if (result.committed) return true;
    } on FirebaseException {
      // code衝突または一時的な予約失敗。下で未使用metaを掃除する。
    }
    try {
      await metaReference.remove();
    } on FirebaseException {
      // 孤立metaは所属/位置のread権限を付与しない。
    }
    return false;
  }

  Future<void> _releaseRtdbInviteReservation({
    required String inviteCode,
    required String teamId,
  }) async {
    // Firestore所属が一度も作られなかった既知の衝突経路だけを掃除する。
    // Rulesはteam_membersが存在する確定済みチームの削除を拒否する。
    try {
      await _database.ref().update({
        'team_meta/$teamId': null,
        'team_invites/$inviteCode': null,
      });
    } on FirebaseException {
      // cleanup失敗は認可を広げない。孤立予約は読取権限を付与せず、
      // 次のランダムteamId/codeで安全に再試行できる。
    }
  }

  Future<void> _activateRtdbMembership({
    required String uid,
    required String teamId,
    required String inviteCode,
  }) async {
    final userReference = _database.ref('team_users/$uid');
    final userSnapshot = await userReference.get();
    final existing = userSnapshot.value;
    if (existing is Map && existing['teamId'] != teamId) {
      throw const AlreadyInTeamException();
    }
    if (!userSnapshot.exists) {
      final result = await userReference.runTransaction((current) {
        if (current != null) return rtdb.Transaction.abort();
        return rtdb.Transaction.success({
          'teamId': teamId,
          'inviteCode': inviteCode,
        });
      }, applyLocally: false);
      if (!result.committed) throw const AlreadyInTeamException();
    }
    final memberReference = _database.ref('team_members/$teamId/$uid');
    final memberSnapshot = await memberReference.get();
    if (!memberSnapshot.exists) {
      await memberReference.set({'joinedAt': ServerValue.timestamp});
    }
  }

  Future<TeamMembership> _loadAndActivate(
    String teamId,
    String uid, {
    bool allowOfflineBridge = false,
  }) async {
    final teamReference = _firestore.collection('teams').doc(teamId);
    final results = await Future.wait([
      teamReference.get(),
      teamReference.collection('members').doc(uid).get(),
    ]);
    final teamSnapshot = results[0];
    final memberSnapshot = results[1];
    final data = teamSnapshot.data();
    if (!teamSnapshot.exists || !memberSnapshot.exists || data == null) {
      throw const TeamMembershipInconsistentException();
    }
    final team = RowingTeam.fromFirestore(teamId, data);
    final membership = TeamMembership(team: team, userId: uid);
    try {
      await _activateRtdbMembership(
        uid: uid,
        teamId: teamId,
        inviteCode: team.inviteCode,
      );
    } on FirebaseException {
      if (!allowOfflineBridge) rethrow;
    }
    return _activate(membership);
  }

  Future<TeamMembership> _changeInviteCode({String? memberUidToRemove}) async {
    final user = await _ensureUser();
    final active = _activeMembership;
    if (active == null) throw const TeamMembershipInconsistentException();
    if (!active.isAdministrator) throw const NotTeamAdministratorException();
    if (memberUidToRemove == user.uid) {
      throw const CannotRemoveTeamAdministratorException();
    }

    for (var attempt = 0; attempt < 8; attempt++) {
      final nextInviteCode = TeamInviteCode.generate(_random);
      final teamReference = _firestore.collection('teams').doc(active.teamId);
      final previousInviteReference =
          _firestore.collection('invite_codes').doc(active.inviteCode);
      final nextInviteReference =
          _firestore.collection('invite_codes').doc(nextInviteCode);
      final targetUserReference = memberUidToRemove == null
          ? null
          : _firestore.collection('users').doc(memberUidToRemove);
      final targetMemberReference = memberUidToRemove == null
          ? null
          : teamReference.collection('members').doc(memberUidToRemove);

      RowingTeam? updatedTeam;
      try {
        await _firestore.runTransaction((transaction) async {
          final snapshots = await Future.wait([
            transaction.get(teamReference),
            transaction.get(previousInviteReference),
            transaction.get(nextInviteReference),
            if (targetUserReference != null)
              transaction.get(targetUserReference),
            if (targetMemberReference != null)
              transaction.get(targetMemberReference),
          ]);
          final teamSnapshot = snapshots[0];
          final previousInviteSnapshot = snapshots[1];
          final nextInviteSnapshot = snapshots[2];
          if (!teamSnapshot.exists ||
              !previousInviteSnapshot.exists ||
              nextInviteSnapshot.exists) {
            throw const InvalidInviteCodeException();
          }
          final teamData = teamSnapshot.data();
          if (teamData == null) {
            throw const TeamMembershipInconsistentException();
          }
          final team = RowingTeam.fromFirestore(active.teamId, teamData);
          if (team.adminUid != user.uid) {
            throw const NotTeamAdministratorException();
          }
          if (team.inviteCode != active.inviteCode) {
            // 別端末の管理操作を見落とさず、最新コードを再読込してから再試行する。
            throw const TeamMembershipInconsistentException();
          }

          if (memberUidToRemove != null) {
            final targetUserSnapshot = snapshots[3];
            final targetMemberSnapshot = snapshots[4];
            if (!targetUserSnapshot.exists || !targetMemberSnapshot.exists) {
              throw const TeamMembershipInconsistentException();
            }
            if (targetUserSnapshot.data()?['teamId'] != active.teamId) {
              throw const TeamMembershipInconsistentException();
            }
            transaction.delete(targetMemberReference!);
            transaction.delete(targetUserReference!);
          }

          final teamUpdate = <String, Object?>{'inviteCode': nextInviteCode};
          // adminUid追加前のチームを、最初の管理操作時だけ安全に移行する。
          if (teamData['adminUid'] is! String) {
            teamUpdate['adminUid'] = user.uid;
          }
          transaction.update(teamReference, teamUpdate);
          transaction.set(nextInviteReference, {
            'teamId': active.teamId,
            'createdBy': user.uid,
            'createdAt': FieldValue.serverTimestamp(),
          });
          transaction.delete(previousInviteReference);

          updatedTeam = RowingTeam(
            id: team.id,
            name: team.name,
            inviteCode: nextInviteCode,
            createdBy: team.createdBy,
            adminUid: team.adminUid,
            createdAt: team.createdAt,
          );
        });
      } on InvalidInviteCodeException {
        // 生成コードとの稀な衝突だけは、別コードを生成して安全に再試行する。
        continue;
      }

      final nextMembership = TeamMembership(
        team: updatedTeam!,
        userId: user.uid,
      );
      // Firestoreでアクセスを先に失効させる。RTDB側の更新が失敗した場合は
      // 成功として画面遷移せず、管理者に再試行を促す。
      try {
        await _replaceRtdbInviteAndRevokeMember(
          teamId: active.teamId,
          previousInviteCode: active.inviteCode,
          nextInviteCode: nextInviteCode,
          administratorUid: user.uid,
          memberUidToRemove: memberUidToRemove,
        );
      } on FirebaseException {
        throw const TeamManagementSyncException();
      }
      return _activate(nextMembership);
    }
    throw StateError('招待コードを安全に更新できませんでした。');
  }

  Future<void> _replaceRtdbInviteAndRevokeMember({
    required String teamId,
    required String previousInviteCode,
    required String nextInviteCode,
    required String administratorUid,
    required String? memberUidToRemove,
  }) {
    final changes = <String, Object?>{
      'team_meta/$teamId/inviteCode': nextInviteCode,
      'team_invites/$previousInviteCode': null,
      'team_invites/$nextInviteCode': {
        'teamId': teamId,
        'ownerUid': administratorUid,
        'createdAt': ServerValue.timestamp,
      },
    };
    if (memberUidToRemove != null) {
      changes.addAll({
        'teams/$teamId/live_positions/$memberUidToRemove': null,
        'teams/$teamId/boat_profiles/$memberUidToRemove': null,
        'team_users/$memberUidToRemove': null,
        'team_members/$teamId/$memberUidToRemove': null,
      });
    }
    return _database.ref().update(changes);
  }

  Future<TeamMembership> _activate(TeamMembership membership) async {
    _activeMembership = membership;
    _recoveryHint = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cachedTeamIdKey, membership.teamId);
    await prefs.setString(_cachedTeamNameKey, membership.team.name);
    await prefs.setString(_cachedInviteCodeKey, membership.inviteCode);
    await prefs.setString(_cachedCreatedByKey, membership.team.createdBy);
    await prefs.setString(_cachedTeamUserIdKey, membership.userId);
    await Future.wait([
      prefs.remove(_recoveryTeamNameKey),
      prefs.remove(_recoveryInviteCodeKey),
    ]);
    return membership;
  }

  TeamMembership? _restoreCachedMembership(
    String uid,
    SharedPreferences prefs,
  ) {
    _activeMembership = null;
    final teamId = prefs.getString(_cachedTeamIdKey);
    final name = prefs.getString(_cachedTeamNameKey);
    final inviteCode = prefs.getString(_cachedInviteCodeKey);
    final createdBy = prefs.getString(_cachedCreatedByKey);
    final cachedUid = prefs.getString(_cachedTeamUserIdKey);
    if (teamId == null ||
        teamId.isEmpty ||
        name == null ||
        name.isEmpty ||
        inviteCode == null ||
        !TeamInviteCode.isValid(inviteCode) ||
        createdBy == null ||
        createdBy.isEmpty ||
        cachedUid != uid) {
      return null;
    }
    final membership = TeamMembership(
      team: RowingTeam(
        id: teamId,
        name: name,
        inviteCode: inviteCode,
        createdBy: createdBy,
        adminUid: createdBy,
      ),
      userId: uid,
    );
    _activeMembership = membership;
    _recoveryHint = null;
    return membership;
  }

  Future<void> _clearActive({bool preserveRecoveryHint = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (preserveRecoveryHint) {
      final active = _activeMembership;
      _recoveryHint = TeamRecoveryHint.fromCachedValues(
        teamName: prefs.getString(_cachedTeamNameKey) ??
            active?.team.name ??
            prefs.getString(_recoveryTeamNameKey),
        inviteCode: prefs.getString(_cachedInviteCodeKey) ??
            active?.inviteCode ??
            prefs.getString(_recoveryInviteCodeKey),
      );
      final recovery = _recoveryHint;
      if (recovery != null) {
        await prefs.setString(_recoveryTeamNameKey, recovery.teamName);
        await prefs.setString(_recoveryInviteCodeKey, recovery.inviteCode);
      } else {
        await Future.wait([
          prefs.remove(_recoveryTeamNameKey),
          prefs.remove(_recoveryInviteCodeKey),
        ]);
      }
    } else {
      _recoveryHint = null;
      await Future.wait([
        prefs.remove(_recoveryTeamNameKey),
        prefs.remove(_recoveryInviteCodeKey),
      ]);
    }
    _activeMembership = null;
    await Future.wait([
      prefs.remove(_cachedTeamIdKey),
      prefs.remove(_cachedTeamNameKey),
      prefs.remove(_cachedInviteCodeKey),
      prefs.remove(_cachedCreatedByKey),
      prefs.remove(_cachedTeamUserIdKey),
    ]);
  }
}
