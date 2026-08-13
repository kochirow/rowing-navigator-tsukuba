import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/observer_priority_banner.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/services/observer_traffic_awareness_evaluator.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  Boat boat(String name) => Boat(
        boatId: name,
        displayName: name,
        boatType: BoatType.r_1x,
        lat: 36,
        lng: 140,
        heading: 0,
        speed: 3,
        timestamp: DateTime.utc(2026, 8, 3),
      );

  ObserverAwarenessGroup group(List<String> names) {
    final pair = ObserverPairAwareness(
      pairId: '${names.first}|${names.last}',
      boatIds: names,
      displayNames: names,
      phase: ObserverAwarenessPhase.aware,
      encounter: ObserverEncounterKind.opposing,
      distanceMeters: 120,
      closingSpeedMetersPerSecond: 5,
      awareSince: DateTime.utc(2026, 8, 3),
    );
    return ObserverAwarenessGroup(
      boatIds: names,
      displayNames: names,
      pairs: [pair],
    );
  }

  Future<void> pumpBanner(
    WidgetTester tester,
    ObserverTrafficSnapshot snapshot,
  ) =>
      tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: ObserverPriorityBanner(snapshot: snapshot)),
      ));

  testWidgets('逆走と接近を最大2本の短いバナーへ分ける', (tester) async {
    await pumpBanner(
      tester,
      ObserverTrafficSnapshot(
        reverseBoats: [boat('A艇'), boat('B艇')],
        groups: [
          group(['C艇', 'D艇', 'E艇'])
        ],
      ),
    );

    expect(find.text('逆走：A艇・B艇'), findsOneWidget);
    expect(find.text('接近中：C艇・D艇・E艇'), findsOneWidget);
    expect(find.byIcon(Icons.u_turn_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.swap_horiz_rounded), findsOneWidget);
  });

  testWidgets('4艇以上と複数組を1本の接近バナーへ圧縮する', (tester) async {
    await pumpBanner(
      tester,
      ObserverTrafficSnapshot(
        groups: [
          group(['A', 'B', 'C', 'D']),
          group(['E', 'F']),
        ],
      ),
    );

    expect(find.text('接近中：A・B・C・ほか1艇・ほか1組'), findsOneWidget);
    expect(find.byType(InkWell), findsOneWidget);
  });
}
