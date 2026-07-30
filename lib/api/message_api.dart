import "package:cloud_firestore/cloud_firestore.dart";

import '../services/team_service.dart';

class MessageAPI {
  final _db = FirebaseFirestore.instance;
  static const collectionName = "messages";
  final String? _teamId;

  MessageAPI({String? teamId}) : _teamId = teamId;

  CollectionReference<Map<String, dynamic>> get collection => _db
      .collection('teams')
      .doc(_teamId ?? TeamService.requireActiveTeamId)
      .collection(collectionName);
}
