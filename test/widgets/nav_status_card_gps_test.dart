import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_status_card.dart';
import 'package:rowing_navigator/services/gps_health_monitor.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    required GpsHealthQuality quality,
    int? ageSeconds,
    bool streamRecovering = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: NavStatusCard(
            paceSeconds: 120,
            distanceMeters: 1000,
            elapsedTimeSeconds: 60,
            gpsAgeSeconds: ageSeconds,
            gpsQuality: quality,
            gpsStreamRecovering: streamRecovering,
          ),
        ),
      ),
    );
  }

  testWidgets('初回測位前はGPS捕捉中と表示する', (tester) async {
    await pumpCard(tester, quality: GpsHealthQuality.unusable);
    expect(find.text('GPS捕捉中'), findsOneWidget);
  });

  testWidgets('測位途絶時は測位なしと最終測位時刻を表示する', (tester) async {
    await pumpCard(
      tester,
      quality: GpsHealthQuality.unusable,
      ageSeconds: 8,
    );
    expect(find.text('GPS測位なし 8秒前'), findsOneWidget);
  });

  testWidgets('低精度fixを使っている間はGPS精度低下と表示する', (tester) async {
    await pumpCard(
      tester,
      quality: GpsHealthQuality.degraded,
      ageSeconds: 1,
    );
    expect(find.text('GPS精度低下'), findsOneWidget);
  });

  testWidgets('stream無通信は低精度とは別に再接続中と表示する', (tester) async {
    await pumpCard(
      tester,
      quality: GpsHealthQuality.degraded,
      ageSeconds: 8,
      streamRecovering: true,
    );
    expect(find.text('GPSストリーム再接続中 8秒前'), findsOneWidget);
    expect(find.text('GPS精度低下'), findsNothing);
  });
}
