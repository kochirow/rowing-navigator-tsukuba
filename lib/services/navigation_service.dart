/* spellchecker: disable */
import 'package:cloud_firestore/cloud_firestore.dart';

class NavigationService {
  final _db = FirebaseFirestore.instance;
  /* spellchecker: disable */
  static const collectionName = 'navigations';

  // =============================================
  // ナビゲーション情報更新
  // =============================================
  Future<void> updateNavigation(String userId, double lat, double lng) async {
    // print("updateNavigation: $userId, $lat, $lng");
    // navigationsコレクションのドキュメントを更新
    // await _db.collection(collectionName).doc(userId).set({
    //   "location": {
    //     "lat": lat,
    //     "lng": lng,
    //     "timestamp": FieldValue.serverTimestamp(),
    //   },
    // });
    // print("Completed updateNavigation");
  }

  // =============================================
  // ナビゲーション情報更新終了時の処理
  // =============================================
  Future<void> finishNavigation(String userId) async {
    // navigationsコレクションからドキュメントを削除
    await _db.collection(collectionName).doc(userId).delete();
  }
}
