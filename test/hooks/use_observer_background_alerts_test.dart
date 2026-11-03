import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/hooks/use_observer_background_alerts.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/services/observer_notification_service.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotifications extends ObserverNotificationService {
  final shown = <String>[];
  int permissionRequests = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<bool> show({required String boatId, required String body}) async {
    shown.add(body);
    return true;
  }
}

Message _message(String? w) => Message(
      boatId: 'a',
      displayName: '後藤',
      boatType: BoatType.r_4p,
      lat: 36.0,
      lng: 140.0,
      heading: 90,
      speed: 3,
      timestamp: DateTime.now(),
      serverUpdatedAt: DateTime.now(),
      presentationState: w,
    );

void main() {
  late ValueNotifier<List<Message>> messages;
  late _FakeNotifications notifications;
  late List<Map<String, dynamic>> recorded;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messages = ValueNotifier(const []);
    notifications = _FakeNotifications();
    recorded = [];
  });

  Future<void> pumpHost(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          home: HookBuilder(builder: (context) {
            useObserverBackgroundAlerts(
              enabled: true,
              messages: messages,
              onRecord: (type, details) =>
                  recorded.add({'type': type, ...details}),
              service: notifications,
            );
            return const SizedBox();
          }),
        ),
      );

  testWidgets('背面で漕手に警告が鳴ったら、描画なしでも通知し、監視ログへ残す', (tester) async {
    await pumpHost(tester);
    await tester.pump();
    expect(notifications.permissionRequests, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // 受信の変化だけで判定する(背面では画面の再描画が起きない)。
    messages.value = [_message(null)];
    messages.value = [_message('2o')];
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(notifications.shown, ['4+ 後藤：警告：他艇に注意（連続音）']);
    expect(recorded.single['type'], 'observer_background_notified');
    expect(recorded.single['kind'], 'warning');
    expect(recorded.single['delivered'], isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('前面にある間は通知しない(バイブと艇一覧が受け持つ)', (tester) async {
    await pumpHost(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    messages.value = [_message(null)];
    messages.value = [_message('2o')];
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(notifications.shown, isEmpty);
  });
}
