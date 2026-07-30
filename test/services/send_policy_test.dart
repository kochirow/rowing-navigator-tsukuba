import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/services/send_policy.dart';

void main() {
  group('sendIntervalSecondsFor (適応送信)', () {
    test('停止中かつ周囲に他艇がいなければ10秒間隔', () {
      expect(
        sendIntervalSecondsFor(
            speed: 0.0, otherBoatNearby: false, elevatedRisk: false),
        10,
      );
    });

    test('周囲300m以内に他艇がいなければ5秒間隔', () {
      expect(
        sendIntervalSecondsFor(
            speed: 3.0, otherBoatNearby: false, elevatedRisk: false),
        5,
      );
    });

    test('他艇が近いがリスクなしなら2秒間隔', () {
      expect(
        sendIntervalSecondsFor(
            speed: 3.0, otherBoatNearby: true, elevatedRisk: false),
        2,
      );
      expect(
        sendIntervalSecondsFor(
            speed: 0.4, otherBoatNearby: true, elevatedRisk: false),
        2,
      );
    });

    test('リスクレベルが上がってもクラウド送信は2秒間隔', () {
      expect(
        sendIntervalSecondsFor(
            speed: 0.0, otherBoatNearby: false, elevatedRisk: true),
        2,
      );
    });

    // otherBoatNearby は自艇が受信できた他艇からしか作れない。受信だけが
    // 落ちた艇が10秒送信を続けると、受信側の予測TTL(6秒)を超えて
    // 10秒周期のうち4秒間、他艇の衝突評価から消える。
    test('他艇を受信できない間は、停止中でも2秒間隔を維持する', () {
      expect(
        sendIntervalSecondsFor(
          speed: 0.0,
          otherBoatNearby: false,
          elevatedRisk: false,
          receiveUnavailable: true,
        ),
        2,
      );
      expect(
        sendIntervalSecondsFor(
          speed: 3.0,
          otherBoatNearby: false,
          elevatedRisk: false,
          receiveUnavailable: true,
        ),
        2,
      );
    });

    test('受信が正常なら従来どおりの間隔に戻る', () {
      expect(
        sendIntervalSecondsFor(
          speed: 0.0,
          otherBoatNearby: false,
          elevatedRisk: false,
          receiveUnavailable: false,
        ),
        10,
      );
    });
  });
}
