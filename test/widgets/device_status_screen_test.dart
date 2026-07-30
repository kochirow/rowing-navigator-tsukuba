import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/models/safety_snapshot.dart';
import 'package:rowing_navigator/screens/device_status_screen.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(theme: buildAppTheme(), home: child);

  testWidgets('測位と安全機能の現状を読み取り専用で示す', (tester) async {
    final now = DateTime(2026, 7, 26, 6, 30);
    await tester.pumpWidget(
      wrap(
        DeviceStatusScreen(
          latitude: 36.069123,
          longitude: 140.208456,
          accuracyMeters: 4.2,
          speedMetersPerSecond: 3.5,
          headingDegrees: 182.0,
          lastFixAt: now.subtract(const Duration(seconds: 12)),
          batteryPercent: 64,
          otherBoatReceiveUnavailable: true,
          safetyRunMode: SafetyRunMode.runningDegraded,
          otherBoatCount: 3,
          obstacleCount: 312,
          navigating: true,
          clock: () => now,
        ),
      ),
    );

    expect(find.text('航行中'), findsOneWidget);
    expect(find.text('36.069123'), findsOneWidget);
    expect(find.text('4.2 m'), findsOneWidget);
    expect(find.text('12 秒前'), findsOneWidget);
    expect(find.text('64 %'), findsOneWidget);

    // 落ちている能力は「利用不可」、生きている能力は「正常」。
    expect(find.text('利用不可'), findsOneWidget);
    expect(find.text('縮退運転'), findsOneWidget);
    expect(find.text('3 隻'), findsOneWidget);
    expect(find.text('312 件'), findsOneWidget);

    // 設定を変える手段は置かない。
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('値が無くても破綻せず、欠測を明示する', (tester) async {
    await tester.pumpWidget(wrap(const DeviceStatusScreen()));

    expect(find.text('待機中'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
    expect(find.text('停止中（待機）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
