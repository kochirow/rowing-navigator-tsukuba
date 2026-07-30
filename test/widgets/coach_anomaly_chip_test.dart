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
    bool practiceAreaUnavailable = false,
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: CoachAnomalyChip(
          anomalies: anomalies,
          practiceAreaUnavailable: practiceAreaUnavailable,
          onTap: onTap,
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

  testWidgets('練習水域を読めないことを併記する', (tester) async {
    await pumpChip(
      tester,
      anomalies: [anomaly(kind: BoatAnomalyKind.lost)],
      practiceAreaUnavailable: true,
    );

    expect(find.text('異常 1隻'), findsOneWidget);
    expect(find.text('水域外の自動検知が停止中'), findsOneWidget);
  });

  testWidgets('異常が無くても水域外検知の停止だけで出す', (tester) async {
    // 能力が欠けていることは消さない(DESIGN_PRINCIPLES 原則1)。
    await pumpChip(tester, practiceAreaUnavailable: true);

    expect(find.text('水域外の自動検知が停止中'), findsOneWidget);
    expect(find.textContaining('隻'), findsNothing);
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

  testWidgets('長時間停止・水域外は danger の枠線で示す', (tester) async {
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
}
