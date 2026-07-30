import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  final _auth = FirebaseAuth.instance;

  bool get isSignedIn => _auth.currentUser != null;

  User? get currentUser => _auth.currentUser;

  // =============================================
  // ユーザー削除
  // =============================================
  Future<void> deleteUser() async {
    await _auth.currentUser?.delete();
    debugPrint("Deleted user.");
  }
}
