import '../config/risk_evaluator_config.dart';
import '../models/message_model.dart';
import 'package:flutter/foundation.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import '../services/message_service.dart';

class DynamicObstacleService {
  Stream<Map<String, dynamic>> getDynamicObstaclesStream() {
    return getBoatsStream();
  }

  /// 位置として使えない値(NaN/Infinity/範囲外)を含む艇情報を弾く。
  /// 異常データ1件で受信処理やリスク評価が壊れることを防ぐ。
  bool _isUsable(Boat boat) {
    return boat.lat.isFinite &&
        boat.lng.isFinite &&
        boat.lat.abs() <= 90 &&
        boat.lng.abs() <= 180;
  }

  /// 他艇のスナップショットを流す。
  ///
  /// 返す Map のキー:
  ///
  /// - `boats`(`List<Boat>`): 使える他艇。幽霊艇([boatStaleTimeoutSeconds]
  ///   超過)は従来どおり除外する。
  /// - `receiveDegraded`(`bool`): **ストリーム障害**。受信層そのものが
  ///   機能していないことを示し、system fault の根拠になる。
  /// - `unreadableRecordCount`(`int`): 読めなかった個別レコードの件数。
  ///   診断用で、それ自体は fault の根拠にしない。
  /// - `recordFaults`(`List<RecordFault>`): 今回新たに拒否した個別レコード
  ///   の匿名化済み診断情報。これ自体は fault の根拠にしない。
  /// - `receivedRecordCount`(`int`): 受け取ったレコードの総数
  ///   ([TransportFault] を除く)。
  ///
  /// 「一部のレコードが壊れている」と「受信そのものが落ちている」は
  /// 別物として扱う(要件定義 2026-07-26 提案5-2)。前者で fault を立てると、
  /// RTDB に壊れたレコードが1件残っているだけで永久にフラップする。
  Stream<Map<String, dynamic>> getBoatsStream() {
    final messageService = MessageService();
    return messageService
        .getMessagesStream()
        .map((messages) => summarize(messages, now: DateTime.now()));
  }

  /// 受信済みメッセージ列を1スナップショットへ畳み込む。
  /// Firebase に触れないので単体テストできる。
  /// 返す Map のキーと意味は [getBoatsStream] のドキュメントを参照。
  Map<String, dynamic> summarize(
    List<dynamic> messages, {
    required DateTime now,
  }) {
    final List<Boat> boats = [];
    // 記録専用の提示状態は Boat に入れない。地図描画・衝突評価と混ざる
    // 経路を作らず、監視ログのフックだけへ Message のまま渡す。
    final List<Message> logMessages = [];
    // 受信層が報告した障害。これだけをストリーム障害として扱う。
    var transportFaultCount = 0;
    // 1件単位で読めなかったレコード。件数を診断へ出すだけにする。
    var unreadableCount = 0;
    var receivedCount = 0;
    final recordFaults = <RecordFault>[];
    for (final item in messages) {
      if (item is TransportFault) {
        transportFaultCount++;
        continue;
      }
      if (item is RecordFault) {
        receivedCount++;
        unreadableCount++;
        recordFaults.add(item);
        continue;
      }
      receivedCount++;
      if (item is! Message) {
        unreadableCount++;
        if (kDebugMode) {
          debugPrint('Unreadable record ignored: ${item.runtimeType}');
        }
        continue;
      }
      final message = item;
      // 1件の異常メッセージで全艇の受信が止まらないよう例外を分離する
      try {
        final boat = Boat.fromMessage(message);
        if (!_isUsable(boat)) {
          unreadableCount++;
          if (kDebugMode) {
            debugPrint('Unusable boat data ignored: ${boat.boatId}');
          }
          continue;
        }
        // 最終更新が古い艇情報(アプリ異常終了などで残ったもの)は
        // 幽霊艇として無視し、誤警告を防ぐ。
        // これは「読めなかった」ではなく正常に読めた結果なので、
        // unreadableCount には数えない。
        final freshnessTimestamp = boat.serverUpdatedAt ?? boat.timestamp;
        final ageSeconds = now.difference(freshnessTimestamp).inSeconds;
        if (ageSeconds > boatStaleTimeoutSeconds) continue;
        boats.add(boat);
        logMessages.add(message);
      } catch (e) {
        unreadableCount++;
        debugPrint('Invalid boat message ignored: $e');
      }
    }
    return {
      'boats': boats,
      'logMessages': List<Message>.unmodifiable(logMessages),
      // 全艇が不正でも、データを受信できたこと自体は通信経路が生きて
      // いる証拠である。個別レコード不正で送信を2秒へ固定しない。
      'receiveDegraded': transportFaultCount > 0,
      'unreadableRecordCount': unreadableCount,
      'receivedRecordCount': receivedCount,
      'recordFaults': List<RecordFault>.unmodifiable(recordFaults),
    };
  }
}
