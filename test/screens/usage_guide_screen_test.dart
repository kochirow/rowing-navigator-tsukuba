import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/ashore_config.dart';
import 'package:rowing_navigator/config/coach_config.dart';
import 'package:rowing_navigator/screens/first_run_guide_screen.dart';
import 'package:rowing_navigator/screens/usage_guide/map_and_alerts_guide_page.dart';
import 'package:rowing_navigator/screens/usage_guide/troubleshooting_guide_page.dart';
import 'package:rowing_navigator/screens/usage_guide/watch_guide_page.dart';
import 'package:rowing_navigator/screens/usage_guide_screen.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

Widget _app(Widget home) => MaterialApp(theme: buildAppTheme(), home: home);

Future<void> _openEntry(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('目次から各章へ進める', (tester) async {
    await tester.pumpWidget(_app(const UsageGuideScreen()));

    // 検出できるものの限界は、目次の先頭に常に出す。
    expect(find.textContaining('衝突回避を保証しません'), findsOneWidget);

    for (final title in const [
      '航行',
      '監視',
      '地図と警告音',
      'チームと危険区域',
      '故障かな？と思ったら',
    ]) {
      await _openEntry(tester, title);
      expect(find.widgetWithText(AppBar, title), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('はじめての案内をもう一度見る'));
    await tester.pumpAndSettle();
    expect(find.byType(FirstRunGuideScreen), findsOneWidget);
  });

  testWidgets('橋脚は外周を直接囲む方式として案内する', (tester) async {
    await tester.pumpWidget(_app(const UsageGuideScreen()));
    await _openEntry(tester, 'チームと危険区域');

    await tester.scrollUntilVisible(
      find.text('橋脚の登録'),
      400,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('橋脚の登録'), findsOneWidget);
    expect(
      find.textContaining('実際の外周を3点以上で直接囲みます'),
      findsOneWidget,
    );
    expect(find.textContaining('幅[m]'), findsNothing);
  });

  testWidgets('警告音の鳴り始めの秒数は、実際に効いている設定値で説明する', (tester) async {
    // 以前は「約7秒」「約10秒」と直書きで、既定の10秒・13秒と食い違っていた。
    await tester.pumpWidget(_app(const UsageGuideScreen()));
    await _openEntry(tester, '地図と警告音');
    expect(find.textContaining('あと13秒以内に届きます'), findsOneWidget);
    expect(find.textContaining('あと10秒以内になってから鳴らします'), findsOneWidget);
    // 警告音は1種類(2026-10-23)。断続音の説明は残さない。
    expect(find.textContaining('断続音'), findsNothing);
    expect(find.textContaining('約7秒'), findsNothing);

    // 設定画面やチーム共有で変えた値は、目次からそのまま下位ページへ届く。
    await tester.pumpWidget(_app(const UsageGuideScreen(
      primaryWarningLeadSeconds: 8.5,
      advanceWarningLeadSeconds: 15,
    )));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _openEntry(tester, '地図と警告音');
    expect(find.textContaining('あと15秒以内に届きます'), findsOneWidget);
    expect(find.textContaining('あと8.5秒以内になってから鳴らします'), findsOneWidget);
  });

  testWidgets('警告の見た目は刷新後の航行画面どおりに説明する', (tester) async {
    // 2026-09 の画面刷新で警告バナーを外し、画面の縁を光らせる表示にした。
    // 刷新前の説明(太い枠・「右 5秒」)が残っていると、画面と食い違う。
    await tester.pumpWidget(_app(const MapAndAlertsGuidePage(
      primaryWarningLeadSeconds: 10,
      advanceWarningLeadSeconds: 13,
    )));
    expect(find.textContaining('画面の縁が赤く点滅'), findsOneWidget);
    expect(find.textContaining('太い枠'), findsNothing);
    expect(find.textContaining('右 5秒'), findsNothing);
    expect(find.text('地図の色（航行中）'), findsOneWidget);
  });

  testWidgets('故障かな？の秒数・速度は設定値から出す', (tester) async {
    await tester.pumpWidget(_app(const TroubleshootingGuidePage()));
    expect(find.textContaining('分速100mより遅い間'), findsOneWidget);
    expect(
      find.textContaining('陸側に${ashoreConfirmationDuration.inSeconds}秒いると'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.text('監視中、止まっている艇がいても音が鳴らない'),
      400,
      scrollable: find.byType(Scrollable),
    );
    expect(find.textContaining('3分動いていない'), findsOneWidget);
    expect(find.textContaining('$lostAlertSec秒更新がない'), findsOneWidget);
    expect(stoppedAlertSec, 180, reason: '「3分」の表記はこの値を前提にしている');
  });

  testWidgets('監視の章は異常の秒数を設定値から出す', (tester) async {
    await tester.pumpWidget(_app(const WatchGuidePage()));
    expect(find.textContaining('3分以上動いていない艇'), findsOneWidget);
    expect(find.textContaining('$lostAlertSec秒以上更新がない艇'), findsOneWidget);
  });
}
