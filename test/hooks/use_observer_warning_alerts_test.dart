import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/hooks/use_observer_warning_alerts.dart';
import 'package:rowing_navigator/models/message_model.dart';
import 'package:rowing_navigator/types/boat_type.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message message(String? w) => Message(
        boatId: 'boat-a',
        boatType: BoatType.r_1x,
        lat: 36,
        lng: 140,
        heading: 90,
        speed: 3,
        timestamp: DateTime.now(),
        presentationState: w,
      );

  late List<MethodCall> hapticCalls;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    hapticCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') hapticCalls.add(call);
      return null;
    });
  });

  Future<UseObserverWarningAlerts> pump(
    WidgetTester tester, {
    required bool enabled,
    required List<Message> messages,
  }) async {
    late UseObserverWarningAlerts result;
    await tester.pumpWidget(HookBuilder(builder: (context) {
      result = useObserverWarningAlerts(enabled: enabled, messages: messages);
      return const SizedBox();
    }));
    return result;
  }

  testWidgets('監視中に漕手の音が鳴り始めたら1回知らせ、地図用の名前を返す', (tester) async {
    await pump(tester, enabled: true, messages: [message(null)]);
    final alerts = await pump(tester, enabled: true, messages: [message('1k')]);
    await tester.pump();
    expect(alerts.mapLabelFor('boat-a'), '杭');
    expect(alerts.notifications.value, hasLength(1));
    expect(hapticCalls, hasLength(1));
    // 同じ警告が続いても繰り返さない
    await pump(tester, enabled: true, messages: [message('1k')]);
    await tester.pump(const Duration(seconds: 3));
    expect(hapticCalls, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('監視中でなければ(航行中の端末)何も表示も通知もしない', (tester) async {
    final alerts =
        await pump(tester, enabled: false, messages: [message('2o')]);
    await tester.pump(const Duration(seconds: 2));
    expect(alerts.active.value, isEmpty);
    expect(alerts.mapLabelFor('boat-a'), isNull);
    expect(hapticCalls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('バイブをオフにしても表示と記録は続く', (tester) async {
    final alerts = await pump(tester, enabled: true, messages: [message(null)]);
    alerts.setVibrationEnabled(false);
    await pump(tester, enabled: true, messages: [message('2o')]);
    await tester.pump();
    expect(alerts.active.value.keys, ['boat-a']);
    expect(alerts.notifications.value, hasLength(1));
    expect(hapticCalls, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('observer_warning_vibration_v1'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
