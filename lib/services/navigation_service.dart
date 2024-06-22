import 'package:cloud_firestore/cloud_firestore.dart';

class NavigationService {
  final _db = FirebaseFirestore.instance;

  /* spellchecker: disable */
  static const collectionName = 'navigations';

  Future<void> updateNavigation(String userId, double lat, double lng) async {
    // navigationsコレクションのドキュメントを更新
    await _db.collection(collectionName).doc(userId).set({
      "location": {
        "lat": lat,
        "lng": lng,
      },
    });
    print("Completed updateNavigation");
  }

  Future<void> finishNavigation(String userId) async {
    // navigationsコレクションからドキュメントを削除
    await _db.collection(collectionName).doc(userId).delete();
  }
}
