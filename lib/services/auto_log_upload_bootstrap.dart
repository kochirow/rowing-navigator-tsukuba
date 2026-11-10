import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'account_display_name_service.dart';
import 'auto_log_upload_service.dart';
import 'team_service.dart';

/// アプリ全体で1つだけ使う自動回収。Firebase の初期化の後に [AutoLogUploadService.start] する。
///
/// - ログインの証明: Firebase 匿名アカウントの ID トークン(受け口がチームのメンバーかを確かめる)
/// - App Check のトークン: 受け口が Firestore へ問い合わせるときに添える
/// - 名前: ドライブのファイル名に入れ、誰の記録か分かるようにする
/// - いまのチーム: 前に入っていたチームの監視ログを送らないために使う
final AutoLogUploadService appAutoLogUpload = AutoLogUploadService(
  idToken: () async => FirebaseAuth.instance.currentUser?.getIdToken(),
  appCheckToken: () => FirebaseAppCheck.instance.getToken(),
  displayName: () => AccountDisplayNameService().load(),
  currentTeamId: () async {
    try {
      return TeamService.requireActiveTeamId;
    } on StateError {
      return null; // まだチームを復元していない・入っていない
    }
  },
);
