import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/display_name_config.dart';

/// アカウント(チーム内の匿名メンバー)の名前。
///
/// 航行中の艇のラベル(「4+ 後藤」)と、管理者のメンバー一覧に出す。
/// 同じ名前の人がいてもよい。艇は匿名UIDで区別しているので、名前は表示にしか使わない。
///
/// 端末内を正とし、チームのメンバー情報(Firestore)へは写しを送る。
/// 起動時の登録画面が通信を待たないようにするためである。送れなかった名前は
/// 次の起動で送り直す(Rulesの本番反映前でも、名前の登録と航行は止まらない)。
///
/// AccountDataDeletionServiceのSharedPreferences全消去対象なので、
/// アカウントとデータの削除後に値が残ることはない。
class AccountDisplayNameService {
  static const displayNameKey = 'account_display_name_v1';

  /// 最後にメンバー情報へ送れた「UID + 名前」。送り直しの判定だけに使う。
  static const publishedKey = 'account_display_name_published_v1';

  /// 2026-10-20 より前の版が、航行開始のたびに保存していた名前。
  static const legacyNavigationNameKey = 'navigation_display_name_v1';

  /// 登録済みの名前。未登録(または壊れた値)なら null。
  Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _validOrNull(prefs.getString(displayNameKey));
  }

  /// 登録画面に最初から入れておく名前。前の版で航行に使った名前があればそれ。
  Future<String?> suggestion() async {
    final prefs = await SharedPreferences.getInstance();
    return _validOrNull(prefs.getString(legacyNavigationNameKey));
  }

  /// 名前を端末内へ登録する。不正な名前は [ArgumentError]。
  Future<String> save(String rawName) async {
    final name = normalizeDisplayName(rawName);
    final error = displayNameValidationError(name);
    if (error != null) throw ArgumentError.value(rawName, 'name', error);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(displayNameKey, name);
    return name;
  }

  /// 起動時に、端末内の名前を決める。通信はしない。
  ///
  /// 端末内に無く、メンバー情報に名前があればそれを取り込む
  /// (同じUIDのまま端末内の設定だけが消えた場合)。どちらにも無ければ null で、
  /// 呼び出し側が登録画面を出す。
  Future<String?> resolve({String? serverName}) async {
    final local = await load();
    if (local != null) return local;
    final server = _validOrNull(serverName);
    if (server == null) return null;
    final saved = await save(server);
    return saved;
  }

  /// 端末内の名前がメンバー情報と違えば送る。失敗しても例外を投げない。
  ///
  /// 送れたかどうかを返す(送る必要が無かったときも true)。
  Future<bool> publishIfNeeded({
    required String userId,
    required String? serverName,
    required Future<void> Function(String name) publish,
  }) async {
    final name = await load();
    if (name == null) return true;
    final prefs = await SharedPreferences.getInstance();
    final marker = '$userId\u0000$name';
    if (serverName == name) {
      await prefs.setString(publishedKey, marker);
      return true;
    }
    if (prefs.getString(publishedKey) == marker) return true;
    try {
      await publish(name);
      await prefs.setString(publishedKey, marker);
      return true;
    } catch (error) {
      // 圏外・Rules未反映。名前は端末内にあり航行には使えるので、次の起動で送り直す。
      debugPrint('Failed to publish account display name: $error');
      return false;
    }
  }

  static String? _validOrNull(String? raw) {
    if (raw == null) return null;
    final name = normalizeDisplayName(raw);
    if (displayNameValidationError(name) != null) return null;
    if (name == fallbackDisplayName) return null;
    return name;
  }
}
