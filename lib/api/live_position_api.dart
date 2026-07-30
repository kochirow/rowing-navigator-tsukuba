import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:rowing_navigator/config/navigator_config.dart';

import '../services/team_service.dart';

/// Realtime Database 上のリアルタイム位置共有パス。
/// Firestore と違い転送量課金のため、1秒間隔の位置共有でも
/// 無料枠(10GB/月)内で運用できる。
class LivePositionAPI {
  static const path = 'live_positions';
  static const profilePath = 'boat_profiles';

  final String? _teamId;

  LivePositionAPI({String? teamId}) : _teamId = teamId;

  String get teamId => _teamId ?? TeamService.requireActiveTeamId;

  FirebaseDatabase get _db => realtimeDatabaseUrl.isEmpty
      ? FirebaseDatabase.instance
      : FirebaseDatabase.instanceFor(
          app: Firebase.app(), databaseURL: realtimeDatabaseUrl);

  DatabaseReference get ref => _db.ref('teams/$teamId/$path');

  DatabaseReference get profilesRef => _db.ref('teams/$teamId/$profilePath');

  DatabaseReference get connectedRef => _db.ref('.info/connected');

  /// profileとpositionを1回のatomic updateで書く。
  ///
  /// 圧縮profileだけ、またはpositionだけが見える中間状態を
  /// 作らず、停止時の後続deleteも同じFirebase接続の書込順序で
  /// 必ず後ろに並ぶ。
  Future<void> publishBoatData({
    required String boatId,
    required Map<String, Object?> position,
    Map<String, Object?>? profile,
  }) {
    return _db.ref().update(buildPublishUpdates(
          teamId: teamId,
          boatId: boatId,
          position: position,
          profile: profile,
        ));
  }

  /// onDisconnectは1回発火すると消費されるため、接続のたびに呼ぶ。
  /// 2pathの削除は一つのatomic onDisconnect updateとして登録する。
  Future<void> armBoatDataRemoval(String boatId) =>
      _db.ref().onDisconnect().update(buildClearUpdates(
            teamId: teamId,
            boatId: boatId,
          ));

  /// 停止時に位置と名前プロファイルを1回のatomic updateで消す。
  Future<void> clearBoatData(String boatId) => _db.ref().update({
        ...buildClearUpdates(teamId: teamId, boatId: boatId),
      });

  /// 端末時計のずれに左右されず受信鮮度を求めるための
  /// Firebaseサーバー時刻オフセット [ms]。
  DatabaseReference get serverTimeOffsetRef =>
      _db.ref('.info/serverTimeOffset');

  static Map<String, Object?> buildPublishUpdates({
    required String teamId,
    required String boatId,
    required Map<String, Object?> position,
    Map<String, Object?>? profile,
  }) =>
      {
        'teams/$teamId/$path/$boatId': position,
        if (profile != null) 'teams/$teamId/$profilePath/$boatId': profile,
      };

  static Map<String, Object?> buildClearUpdates({
    required String teamId,
    required String boatId,
  }) =>
      {
        'teams/$teamId/$path/$boatId': null,
        'teams/$teamId/$profilePath/$boatId': null,
      };
}
