import "package:cloud_firestore/cloud_firestore.dart";

class StaticObstacleAPI {
  final _db = FirebaseFirestore.instance;
  final collectionName = "static_obstacles";

  CollectionReference<Map<String, dynamic>> get collection =>
      _db.collection(collectionName);
}
