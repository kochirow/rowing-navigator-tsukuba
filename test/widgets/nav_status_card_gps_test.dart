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
          ),
        ),
      ),
    );
  }

  testWidgets('初回測位前はGPS捕捉中と表示する', (tester) async {
    await pumpCard(tester, quality: GpsHealthQuality.unusable);
    expect(find.text('GPS捕捉中'), findsOneWidget);
  });

  testWidgets('測位途絶時はGPS再捕捉中と最終測位時刻を表示する', (tester) async {
    await pumpCard(
      tester,
      quality: GpsHealthQuality.unusable,
      ageSeconds: 8,
    );
    expect(find.text('GPS再捕捉中 8秒前'), findsOneWidget);
  });

  testWidgets('低精度fixを使っている間はGPS精度低下と表示する', (tester) async {
    await pumpCard(
      tester,
      quality: GpsHealthQuality.degraded,
      ageSeconds: 1,
    );
    expect(find.text('GPS精度低下'), findsOneWidget);
  });
}
