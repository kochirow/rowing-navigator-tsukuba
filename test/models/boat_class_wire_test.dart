import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/models/remote_boat_message.dart';
import 'package:rowing_navigator/types/boat_type.dart';

/// 2-/2+/4-/4+ を足したときの送受信の互換。
///
/// 旧版は `boatType` だけを読み、知らない名前を 1x として扱う。
/// 本当の艇種を `boatType` に入れると、旧版の端末で 4+ が 1x の大きさへ
/// 縮んで警告漏れになるため、`boatType` には大きさの区分を送る。
void main() {
  final now = DateTime.utc(2026, 10, 20, 8);

  Message sent(BoatType type) => Message(
        boatId: 'boat-a',
        displayName: '後藤',
        sessionId: 'session-a',
        sequence: 3,
        boatType: type,
        lat: 36.075,
        lng: 140.118,
        heading: 90,
        speed: 4,
        timestamp: now,
        accuracy: 4,
      );

  /// 艇側の送信から受信側の Message までを、実際の経路どおりに通す。
  Message received(Map<Object?, Object?> profile, Message message) {
    final expanded = Message.expandCompactRtdbJson(
      boatId: message.boatId,
      compact: message.toCompactRtdbJson(
        serverUpdatedAt: now.millisecondsSinceEpoch,
      ),
      profile: profile,
    );
    final result =
        RemoteBoatMessage.tryParse(expanded, estimatedServerNow: now);
    expect(result.isValid, isTrue, reason: '${result.failure}');
    return Message.fromRtdbJson(
      Map<String, dynamic>.from(result.message!.toJson()),
    );
  }

  test('全艇種が送受信で元の艇種に戻る', () {
    for (final type in BoatType.values) {
      final message = sent(type);
      final decoded =
          received(message.toRtdbProfileJson(updatedAt: 1), message);
      expect(decoded.boatType, type, reason: type.displayLabel);
    }
  });

  test('boatType には大きさの区分を送り、旧版でも同じ大きさで読める', () {
    for (final type in BoatType.values) {
      final message = sent(type);
      final profile = message.toRtdbProfileJson(updatedAt: 1);
      expect(profile['boatType'], type.sizeClass.name);
      expect(profile['boatClass'], type.name);

      // 旧版は boatClass を知らない。boatType だけで読んだ結果が
      // 同じ大きさの区分になること(1x へ縮まないこと)。
      final legacy = Map<Object?, Object?>.from(profile)..remove('boatClass');
      expect(
        received(legacy, message).boatType,
        type.sizeClass,
        reason: type.displayLabel,
      );
    }
  });

  test('boatClass と boatType の大きさが食い違うときは boatType に従う', () {
    final message = sent(BoatType.r_4p);
    final profile = message.toRtdbProfileJson(updatedAt: 1)
      ..['boatType'] = BoatType.r_8p.name;
    expect(received(profile, message).boatType, BoatType.r_8p);
  });

  test('知らない boatClass は無視して位置を残す', () {
    final message = sent(BoatType.r_4x);
    final profile = message.toRtdbProfileJson(updatedAt: 1)
      ..['boatClass'] = 'r_6z';
    expect(received(profile, message).boatType, BoatType.r_4x);
  });
}
