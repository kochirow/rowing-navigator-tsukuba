import "package:cloud_firestore/cloud_firestore.dart";

class MessageAPI {
  final _db = FirebaseFirestore.instance;
  final collectionName = "messages";

  CollectionReference<Map<String, dynamic>> get collection =>
      _db.collection(collectionName);
}
