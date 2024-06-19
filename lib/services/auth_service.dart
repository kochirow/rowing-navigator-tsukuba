import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  final _auth = FirebaseAuth.instance;

  bool get isSignedIn => _auth.currentUser != null;

  User? get currentUser => _auth.currentUser;

  Future<void> signInAnonymously() async {
    try {
      await FirebaseAuth.instance.signInAnonymously();
      print("Signed in with temporary account.");
    } on FirebaseAuthException catch (e) {
      switch (e.code) {
        case "operation-not-allowed":
          print("Anonymous auth hasn't been enabled for this project.");
          break;
        default:
          print("Unknown error.");
      }
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
    print("Signed out.");
  }

  Future<void> deleteUser() async {
    await _auth.currentUser?.delete();
    print("Deleted user.");
  }
}
