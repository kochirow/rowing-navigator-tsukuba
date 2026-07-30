import "package:cloud_firestore/cloud_firestore.dart";

import '../services/team_service.dart';

class StaticObstacleAPI {
  final String? _teamId;

  StaticObstacleAPI({String? teamId}) : _teamId = teamId;

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// 流木・工事など、当日だけ共有したい危険区域の保存先。
  /// 固定危険区域は assets/data のJSONとしてアプリに同梱する。
  static const collectionName = "temporary_obstacles";

  CollectionReference<Map<String, dynamic>> get collection => _db
      .collection('teams')
      .doc(_teamId ?? TeamService.requireActiveTeamId)
      .collection(collectionName);
}
