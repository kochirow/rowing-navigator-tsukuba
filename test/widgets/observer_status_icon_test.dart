import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/observer_status_icon.dart';
import 'package:rowing_navigator/hooks/use_coach_watch.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  final anomaly = BoatAnomaly(
    boatId: 'a',
    displayName: 'A艇',
    kind: BoatAnomalyKind.lost,
    detectedAt: DateTime.utc(2026, 8, 3),
  );

  testWidgets('状態は青い小アイコンだけで示し、タップで詳細へ進める', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: ObserverStatusIcon(anomalies: [anomaly], onTap: () => taps++),
      ),
    ));

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.textContaining('異常'), findsNothing);
    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(taps, 1);
  });
}
