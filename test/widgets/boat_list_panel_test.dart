import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/boat_list_panel.dart';
import 'package:rowing_navigator/hooks/use_coach_watch.dart';
import 'package:rowing_navigator/models/boat_model.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  Boat makeBoat({String boatId = 'boat-1234', String displayName = '後藤'}) =>
      Boat(
        boatId: boatId,
        displayName: displayName,
        boatType: BoatType.r_1x,
        lat: 36.0,
        lng: 140.0,
        heading: 180,
        speed: 2.5,
        timestamp: DateTime.utc(2026, 7, 20),
        battery: 80,
      );

  BoatAnomaly makeAnomaly(BoatAnomalyKind kind,
          {String boatId = 'boat-1234'}) =>
      BoatAnomaly(
        boatId: boatId,
        displayName: '後藤',
        kind: kind,
        // 継続時間ラベルが出る長さにする(30秒以上)。
        detectedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      );

  Future<void> pumpPanel(
    WidgetTester tester,
    List<BoatStatus> statuses,
  ) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: BoatListPanel(statuses: statuses)),
    ));
  }

  /// 行の枠線色。強調していない行は枠線を持たない。
  Color? rowBorderColor(WidgetTester tester) {
    final decorations = tester
        .widgetList<Container>(find.byType(Container))
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .where((decoration) => decoration.border != null);
    if (decorations.isEmpty) return null;
    return (decorations.first.border! as Border).top.color;
  }

  testWidgets('監視一覧に名前を表示する', (tester) async {
    await pumpPanel(tester, [BoatStatus(boat: makeBoat(), ageSec: 2)]);

    expect(find.text('後藤'), findsOneWidget);
    expect(find.textContaining('boat'), findsOneWidget);
  });

  testWidgets('異常が無ければ強調しない', (tester) async {
    await pumpPanel(tester, [BoatStatus(boat: makeBoat(), ageSec: 2)]);

    expect(rowBorderColor(tester), isNull);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check_circle)).color,
      AppColors.light.ok,
    );
  });

  group('強調度は異常の重さに合わせる', () {
    testWidgets('長時間停止(沈の疑い)は赤枠で強く出す', (tester) async {
      await pumpPanel(tester, [
        BoatStatus(
          boat: makeBoat(),
          ageSec: 4,
          anomaly: makeAnomaly(BoatAnomalyKind.stopped),
        ),
      ]);

      expect(rowBorderColor(tester), AppColors.light.danger);
      expect(find.byIcon(Icons.warning), findsOneWidget);
    });

    testWidgets('更新途絶は日常的なので控えめに出す', (tester) async {
      // 停止中送信10秒 + 画面OFF + ジッタで普通に起こる。赤枠で出すと
      // 一覧が常時赤くなり、本当にまずい艇が埋もれる(原則4)。
      await pumpPanel(tester, [
        BoatStatus(
          boat: makeBoat(),
          ageSec: 120,
          anomaly: makeAnomaly(BoatAnomalyKind.lost),
        ),
      ]);

      expect(rowBorderColor(tester), isNull);
      expect(find.byIcon(Icons.warning), findsNothing);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.cloud_off)).color,
        AppColors.light.textSecondary,
      );

      final anomalyText = tester.widget<Text>(find.textContaining('更新途絶'));
      expect(anomalyText.style?.color, AppColors.light.textSecondary);
      expect(anomalyText.style?.fontWeight, isNot(FontWeight.bold));
    });
  });

  group('強調度を下げても情報は減らさない', () {
    for (final kind in BoatAnomalyKind.values) {
      testWidgets('${kind.name}: ラベル・継続時間・最終更新秒数を残す', (tester) async {
        final anomaly = makeAnomaly(kind);
        await pumpPanel(tester, [
          BoatStatus(boat: makeBoat(), ageSec: 95, anomaly: anomaly),
        ]);

        // ラベルと「◯分前から」は同じ Text に入る。
        expect(find.textContaining(anomaly.label), findsOneWidget);
        expect(find.textContaining('分前から'), findsOneWidget);
        expect(find.text('95秒前'), findsOneWidget);
        expect(find.text('後藤'), findsOneWidget);
        expect(find.text('80%'), findsOneWidget);
      });
    }
  });

  testWidgets('行をタップするとその艇のIDを返す', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: BoatListPanel(
          statuses: [
            BoatStatus(boat: makeBoat(boatId: 'boat-a'), ageSec: 2),
            BoatStatus(boat: makeBoat(boatId: 'boat-b'), ageSec: 3),
          ],
          onTapBoat: tapped.add,
        ),
      ),
    ));

    await tester.tap(find.byType(InkWell).last);
    await tester.pump();

    expect(tapped, ['boat-b']);
  });

  testWidgets('onTapBoat が無いときは従来どおり表示専用', (tester) async {
    await pumpPanel(tester, [BoatStatus(boat: makeBoat(), ageSec: 2)]);

    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('濡れた手でも押せる高さを行が確保する', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: BoatListPanel(
          statuses: [BoatStatus(boat: makeBoat(), ageSec: 2)],
          onTapBoat: tapped.add,
        ),
      ),
    ));

    expect(
      tester.getSize(find.byType(InkWell)).height,
      greaterThanOrEqualTo(44),
    );
  });
}
