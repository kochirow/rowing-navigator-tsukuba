import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/coach_anomaly_chip.dart';
import 'package:rowing_navigator/hooks/use_coach_watch.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  final now = DateTime.utc(2026, 7, 26, 6);

  BoatAnomaly anomaly({
    required BoatAnomalyKind kind,
    String boatId = 'boat-1',
    String displayName = '第1エイト',
  }) =>
      BoatAnomaly(
        boatId: boatId,
        displayName: displayName,
        kind: kind,
        detectedAt: now,
      );

  Future<void> pumpChip(
    WidgetTester tester, {
    List<BoatAnomaly> anomalies = const [],
    VoidCallback? onTap,
    void Function(String boatId)? onFocusBoat,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: CoachAnomalyChip(
          anomalies: anomalies,
          onTap: onTap,
          onFocusBoat: onFocusBoat,
        ),
      ),
    ));
  }

  testWidgets('伝えることが無ければ何も出さない', (tester) async {
    await pumpChip(tester);

    expect(find.byType(Container), findsNothing);
    expect(find.textContaining('異常'), findsNothing);
  });

  testWidgets('異常のある艇数を出す', (tester) async {
    await pumpChip(tester, anomalies: [
      anomaly(kind: BoatAnomalyKind.stopped, boatId: 'a'),
      anomaly(kind: BoatAnomalyKind.lost, boatId: 'b'),
    ]);

    expect(find.text('異常 2隻'), findsOneWidget);
  });

  testWidgets('タップで艇一覧を開く', (tester) async {
    var tapped = 0;
    await pumpChip(
      tester,
      anomalies: [anomaly(kind: BoatAnomalyKind.lost)],
      onTap: () => tapped++,
    );

    await tester.tap(find.text('異常 1隻'));
    await tester.pump();

    expect(tapped, 1);
  });

  testWidgets('指で押せる大きさ(44pt以上)を確保する', (tester) async {
    await pumpChip(
      tester,
      anomalies: [anomaly(kind: BoatAnomalyKind.lost)],
      onTap: () {},
    );

    final size = tester.getSize(find.byType(InkWell));
    expect(size.height, greaterThanOrEqualTo(44));
    expect(size.width, greaterThanOrEqualTo(44));
  });

  testWidgets('更新途絶だけなら danger ではなく caution で示す', (tester) async {
    // 赤い塗りつぶしをやめた趣旨。日常的な異常で画面を赤くしない。
    await pumpChip(tester, anomalies: [anomaly(kind: BoatAnomalyKind.lost)]);

    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.color, AppColors.light.caution);
    expect(icon.icon, Icons.info_outline);
  });

  testWidgets('長時間停止は danger の枠線で示す', (tester) async {
    await pumpChip(tester, anomalies: [
      anomaly(kind: BoatAnomalyKind.lost, boatId: 'a'),
      anomaly(kind: BoatAnomalyKind.stopped, boatId: 'b'),
    ]);

    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.color, AppColors.light.danger);
    expect(icon.icon, Icons.warning_amber_rounded);

    // 枠線だけで、面は danger で塗らない。
    final decoration = tester
        .widgetList<Container>(find.byType(Container))
        .map((container) => container.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((decoration) => decoration.border != null);
    expect(decoration.color, AppColors.light.chipScrim);
    expect(
      (decoration.border! as Border).top.color,
      AppColors.light.danger,
    );
  });

  testWidgets('タップで艇一覧を開き、同時に重い異常の艇へ寄せる', (tester) async {
    var opened = 0;
    final focused = <String>[];
    await pumpChip(
      tester,
      anomalies: [
        // 日常的に起こる更新途絶が先に並んでいても、沈の疑いを優先する。
        anomaly(kind: BoatAnomalyKind.lost, boatId: 'routine'),
        anomaly(kind: BoatAnomalyKind.stopped, boatId: 'serious'),
      ],
      onTap: () => opened++,
      onFocusBoat: focused.add,
    );

    await tester.tap(find.byType(InkWell));
    await tester.pump();

    // 既存の「艇一覧を開く」動作は残す。
    expect(opened, 1);
    expect(focused, ['serious']);
  });

  test('重い異常が無ければ先頭の艇へ寄せる', () {
    expect(
      CoachAnomalyChip.focusTargetBoatId([
        anomaly(kind: BoatAnomalyKind.lost, boatId: 'first'),
        anomaly(kind: BoatAnomalyKind.lost, boatId: 'second'),
      ]),
      'first',
    );
    expect(CoachAnomalyChip.focusTargetBoatId(const []), isNull);
  });
}
