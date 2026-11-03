import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/session_model.dart';
import 'diagnostic_bundle_service.dart';
import 'navigation_diagnostics_support.dart';
import 'session_analyzer_service.dart';

/// 途切れた記録を完了に直した結果(R1-R14)。保存に失敗したら [error] が入る。
class SessionRecoveryOutcome {
  final String sessionId;
  final Object? error;
  const SessionRecoveryOutcome(this.sessionId, {this.error});
  bool get succeeded => error == null;
}

/// 練習セッションの永続化(端末内JSONファイル)。
/// サーバー不要のため費用はかからない。
/// 保存先: `アプリのドキュメントディレクトリ/sessions/id.json`
class SessionStoreService {
  final Future<Directory> Function() _documentsDirectoryProvider;

  /// 練習が終わって記録が確定したとき(終了操作・途切れた記録の確定)に、
  /// その記録のIDを流す。「今日の記録」シート(R1)がこれを受けて出る。
  /// 記録画面での評価の保存などでは流さない。
  static final StreamController<String> _finishedSessionIds =
      StreamController<String>.broadcast();
  static Stream<String> get finishedSessionIds => _finishedSessionIds.stream;

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

  /// 終了操作で確定した記録を保存し、[finishedSessionIds] へ知らせる。
  Future<void> saveFinishedSession(Session session) async {
    await saveSession(session);
    if (session.isComplete) _finishedSessionIds.add(session.id);
  }

  /// 1件だけ読む。無い・壊れているときは null。
  Future<Session?> loadSession(String id) async {
    final dir = await _sessionsDir();
    final file = File('${dir.path}/$id.json');
    if (!await file.exists()) return null;
    try {
      return Session.fromJson(
          Map<String, dynamic>.from(json.decode(await file.readAsString())));
    } catch (_) {
      return null;
    }
  }

  /// 終了操作なしで途切れた記録を見つけ、最後の記録の時刻で完了に直す(R1-R14)。
  ///
  /// - 終了時刻は、記録点・警告・診断イベントのうち最後のものの時刻にする。
  ///   次回起動の時刻にはしない(練習時間が数時間に伸びてしまう)。
  /// - 直したことは [Session.endReason] と `session_recovery_detected` に残し、
  ///   通常の終了と区別できるようにする。集計は通常の終了と同じ解析で作り直す。
  /// - [startedBefore] より後に始まった記録(いま記録中の航行)は触らない。
  Future<List<SessionRecoveryOutcome>> recoverIncompleteSessions({
    required DateTime now,
    required DateTime startedBefore,
  }) async {
    final outcomes = <SessionRecoveryOutcome>[];
    for (final incomplete in (await listSessions()).where((session) =>
        !session.isComplete && session.startedAt.isBefore(startedBefore))) {
      final recovered = recoveredSession(incomplete, now: now);
      try {
        await saveSession(recovered);
        _finishedSessionIds.add(recovered.id);
        outcomes.add(SessionRecoveryOutcome(recovered.id));
      } catch (error) {
        outcomes.add(SessionRecoveryOutcome(recovered.id, error: error));
      }
    }
    return outcomes;
  }

  /// [recoverIncompleteSessions] の中身(純粋関数・テスト用に公開)。
  static Session recoveredSession(Session incomplete, {required DateTime now}) {
    final lastRecordedAt = lastRecordedAtOf(incomplete);
    final previousSequence = incomplete.diagnosticEvents.fold<int>(
      0,
      (current, event) => math.max(current, event.sequence ?? 0),
    );
    final recoveryEvent = SessionDiagnosticEvent(
      sequence: previousSequence + 1,
      t: now,
      type: 'session_recovery_detected',
      details: {
        'sessionId': incomplete.id,
        'startedAt': incomplete.startedAt.toUtc().toIso8601String(),
        // 最後に保存したチェックポイントの時刻と、確定に使った最後の記録の時刻。
        'endedAt': incomplete.endedAt.toUtc().toIso8601String(),
        'recoveredEndedAt': lastRecordedAt.toUtc().toIso8601String(),
        'ageMs': now.difference(lastRecordedAt).inMilliseconds,
        'pointCount': incomplete.points.length,
        'alertEventCount': incomplete.alertEvents.length,
        'diagnosticEventCount': incomplete.diagnosticEvents.length,
        'lastDiagnosticEventType': incomplete.diagnosticEvents.isEmpty
            ? null
            : incomplete.diagnosticEvents.last.type,
        'endReason': Session.endReasonRecoveredAfterTermination,
        ...sessionRecoveryContext(incomplete),
      },
    );
    return incomplete.copyWith(
      endedAt: lastRecordedAt,
      isComplete: true,
      endReason: Session.endReasonRecoveredAfterTermination,
      summary: SessionAnalyzerService().analyze(
        incomplete.points,
        boatTypeName: incomplete.boatTypeName,
      ),
      diagnosticEvents: [...incomplete.diagnosticEvents, recoveryEvent],
    );
  }

  /// 記録に残っている最後の時刻。何も無ければチェックポイントの時刻。
  static DateTime lastRecordedAtOf(Session session) {
    DateTime? latest;
    void consider(DateTime? at) {
      if (at == null) return;
      if (latest == null || at.isAfter(latest!)) latest = at;
    }

    // 並び順に頼らず全部を見る(開始前の診断が後から足されることがある)。
    if (session.points.isNotEmpty) consider(session.points.last.t);
    for (final event in session.alertEvents) {
      consider(event.t);
    }
    for (final event in session.diagnosticEvents) {
      consider(event.t);
    }
    final result = latest ?? session.endedAt;
    return result.isBefore(session.startedAt) ? session.startedAt : result;
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
