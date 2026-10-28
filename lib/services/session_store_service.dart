import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/session_model.dart';
import 'diagnostic_bundle_service.dart';

/// 練習セッションの永続化(端末内JSONファイル)。
/// サーバー不要のため費用はかからない。
/// 保存先: `アプリのドキュメントディレクトリ/sessions/id.json`
class SessionStoreService {
  final Future<Directory> Function() _documentsDirectoryProvider;

  SessionStoreService({
    Future<Directory> Function()? documentsDirectoryProvider,
  }) : _documentsDirectoryProvider =
            documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  Future<Directory> _sessionsDir() async {
    final docs = await _documentsDirectoryProvider();
    final dir = Directory('${docs.path}/sessions');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> saveSession(Session session) async {
    final dir = await _sessionsDir();
    final file = File('${dir.path}/${session.id}.json');
    final temporaryFile = File('${file.path}.tmp');
    try {
      // アプリ強制終了が書込中に起き、既存の記録まで途中の
      // JSONにならないよう、別ファイルをflushしてから置き換える。
      await temporaryFile.writeAsString(
        json.encode(session.toJson()),
        flush: true,
      );
      await temporaryFile.rename(file.path);
    } finally {
      // rename前に失敗した一時ファイルは一覧の対象にしない。
      if (await temporaryFile.exists()) {
        try {
          await temporaryFile.delete();
        } catch (_) {
          // クリーンアップ失敗で保存本体の成否を上書きしない。
        }
      }
    }
  }

  /// 全セッションを新しい順に返す
  Future<List<Session>> listSessions() async {
    final dir = await _sessionsDir();
    final sessions = <Session>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final data = json.decode(await entity.readAsString());
        sessions.add(Session.fromJson(Map<String, dynamic>.from(data)));
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Broken session file: ${entity.path} $e');
        }
      }
    }
    sessions.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return sessions;
  }

  Future<void> deleteSession(String id) async {
    final dir = await _sessionsDir();
    final file = File('${dir.path}/$id.json');
    if (await file.exists()) {
      await file.delete();
    }
    final temporaryFile = File('${file.path}.tmp');
    if (await temporaryFile.exists()) {
      await temporaryFile.delete();
    }
  }

  /// 「まとめて送る」の対象(15分・2km以上で未送信)の件数。
  ///
  /// メニューの「練習記録」に出すためだけに使う。記録を全部読むので、
  /// 別 isolate で数えて画面を止めない。読めない記録は数えない。
  Future<int> countPendingBulkLogExports() async {
    final dir = await _sessionsDir();
    return compute(_countPendingInDirectory, dir.path);
  }

  /// アカウント・データ削除用に、端末内の全練習記録を削除する。
  Future<void> deleteAllSessions() async {
    final docs = await _documentsDirectoryProvider();
    final dir = Directory('${docs.path}/sessions');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}

Future<int> _countPendingInDirectory(String path) async {
  var count = 0;
  await for (final entity in Directory(path).list()) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    try {
      final data = json.decode(await entity.readAsString());
      final session = Session.fromJson(Map<String, dynamic>.from(data));
      if (isBulkLogExportTarget(session)) count++;
    } catch (_) {
      // 壊れた記録は一覧でも出さないので、ここでも数えない。
    }
  }
  return count;
}
