import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/services/observer_background_alert_policy.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 4, 6);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));
  const all = {...ObserverBackgroundAlertKind.values};

  Message message(
    int second, {
    String boatId = 'a',
    double speed = 3,
    double lat = 36.0,
    double lng = 140.0,
    String? w,
    bool ashore = false,
  }) =>
      Message(
        boatId: boatId,
        displayName: '後藤',
        boatType: BoatType.r_4p,
        lat: lat,
        lng: lng,
        heading: 90,
        speed: speed,
        timestamp: at(second),
        serverUpdatedAt: at(second),
        presentationState: w,
        audioSuppressedAshore: ashore,
      );

  ObserverBackgroundAlertPolicy policy(
          {bool Function(double, double)? quiet}) =>
      ObserverBackgroundAlertPolicy(
        isQuietPlace: quiet ?? (_, __) => false,
        stoppedAfter: const Duration(minutes: 5),
        lostAfter: const Duration(seconds: 90),
      );

  /// 10秒ごとに同じ状態の受信が届き、背面で判定を回す想定。
  List<ObserverBackgroundAlert> run(
    ObserverBackgroundAlertPolicy p, {
    required int fromSecond,
    required int toSecond,
    Message Function(int second)? receive,
    bool foreground = false,
    Set<ObserverBackgroundAlertKind> enabled = all,
  }) {
    final alerts = <ObserverBackgroundAlert>[];
    for (var s = fromSecond; s <= toSecond; s += 5) {
      final messages =
          receive == null || s % 10 != 0 ? <Message>[] : [receive(s)];
      alerts.addAll(p.update(
        messages: messages,
        now: at(s),
        foreground: foreground,
        enabled: enabled,
      ));
    }
    return alerts;
  }

  group('長時間停止', () {
    test('5分止まったら1回だけ、本文は「艇名：種類」', () {
      final p = policy();
      final alerts = run(p,
          fromSecond: 0, toSecond: 900, receive: (s) => message(s, speed: 0.1));
      expect(alerts, hasLength(1));
      expect(alerts.single.kind, ObserverBackgroundAlertKind.stopped);
      expect(alerts.single.body, '4+ 後藤：長時間停止（5分以上）');
      expect(alerts.single.at, at(300));
    });

    test('動き出したら再武装し、また止まれば出す', () {
      final p = policy();
      run(p,
          fromSecond: 0, toSecond: 400, receive: (s) => message(s, speed: 0));
      run(p,
          fromSecond: 410, toSecond: 500, receive: (s) => message(s, speed: 2));
      final again = run(p,
          fromSecond: 510, toSecond: 900, receive: (s) => message(s, speed: 0));
      expect(again.map((a) => a.kind), [ObserverBackgroundAlertKind.stopped]);
    });

    test('係留区域・港の中・陸上判定中の艇は出さない', () {
      final inQuiet = run(policy(quiet: (_, __) => true),
          fromSecond: 0, toSecond: 900, receive: (s) => message(s, speed: 0));
      final ashore = run(policy(),
          fromSecond: 0,
          toSecond: 900,
          receive: (s) => message(s, speed: 0, ashore: true));
      expect(inQuiet, isEmpty);
      expect(ashore, isEmpty);
    });
  });

  group('更新途絶', () {
    test('最後の受信から90秒を超えたら1回', () {
      final p = policy();
      run(p, fromSecond: 0, toSecond: 60, receive: (s) => message(s));
      final alerts = run(p, fromSecond: 65, toSecond: 400);
      expect(alerts.map((a) => a.kind), [ObserverBackgroundAlertKind.lost]);
      expect(alerts.single.body, '4+ 後藤：更新途絶（90秒以上）');
      expect(alerts.single.at.isAfter(at(150)), isTrue);
    });

    test('桟橋で終えた艇(係留区域で途絶えた艇)は出さない', () {
      final p = policy(quiet: (lat, _) => lat > 36.5);
      run(p,
          fromSecond: 0, toSecond: 60, receive: (s) => message(s, lat: 36.6));
      expect(run(p, fromSecond: 65, toSecond: 400), isEmpty);
    });

    test('途絶えている間は長時間停止を出さない', () {
      final p = policy();
      run(p, fromSecond: 0, toSecond: 60, receive: (s) => message(s, speed: 0));
      final alerts = run(p, fromSecond: 65, toSecond: 900);
      expect(alerts.map((a) => a.kind), [ObserverBackgroundAlertKind.lost]);
    });
  });

  group('漕手の警告', () {
    test('音ありに変わったら、どの警告かを本文に入れて1回', () {
      final p = policy();
      final alerts = run(p,
          fromSecond: 0,
          toSecond: 60,
          receive: (s) => message(s, w: s >= 20 ? '2o' : null));
      expect(alerts, hasLength(1));
      expect(alerts.single.kind, ObserverBackgroundAlertKind.warning);
      expect(alerts.single.body, '4+ 後藤：警告：他艇に注意（連続音）');
    });
  });

  group('前面・切った種類', () {
    test('前面にある間は通知せず消化し、背面へ回っても後から出さない', () {
      final p = policy();
      final foreground = run(p,
          fromSecond: 0,
          toSecond: 400,
          receive: (s) => message(s, speed: 0),
          foreground: true);
      final background = run(p,
          fromSecond: 405, toSecond: 600, receive: (s) => message(s, speed: 0));
      expect(foreground, isEmpty);
      expect(background, isEmpty);
    });

    test('切った種類は出さない', () {
      final alerts = run(policy(),
          fromSecond: 0,
          toSecond: 900,
          receive: (s) => message(s, speed: 0),
          enabled: {ObserverBackgroundAlertKind.lost});
      expect(alerts, isEmpty);
    });
  });
}
