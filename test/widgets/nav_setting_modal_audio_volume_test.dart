import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_setting_modal.dart';
import 'package:rowing_navigator/features/home_map/widgets/warning_audio_volume_sheet.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  void setView(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpModal(
    WidgetTester tester, {
    ValueNotifier<double>? volume,
    Future<void> Function(double)? onChanged,
    Future<void> Function()? onTest,
  }) async {
    SharedPreferences.setMockInitialValues({});
    setView(tester);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: NavSettingModal(
              onPressStartNav: (_, __) async {},
              onPressTestAudio: onTest ?? () async {},
              warningAudioVolume: volume,
              onWarningAudioVolumeChanged: onChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder verticalScrollable() => find
      .byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      )
      .first;

  testWidgets('航行開始画面ではスライダーを出さず、小さな入口だけ置く', (tester) async {
    await pumpModal(
      tester,
      volume: ValueNotifier<double>(0.7),
      onChanged: (_) async {},
    );
    expect(find.byType(Slider), findsNothing);
    await tester.scrollUntilVisible(
      find.text('警告音の音量 70%'),
      200,
      scrollable: verticalScrollable(),
    );
    expect(find.text('警告音の音量 70%'), findsOneWidget);
  });

  testWidgets('入口を押すと説明つきのスライダーが出て、30%で止まる', (tester) async {
    final volume = ValueNotifier<double>(1.0);
    final changed = <double>[];
    var tested = 0;
    await pumpModal(
      tester,
      volume: volume,
      onChanged: (v) async => changed.add(v),
      onTest: () async => tested++,
    );
    final link = find.text('警告音の音量 100%');
    await tester.scrollUntilVisible(
      link,
      200,
      scrollable: verticalScrollable(),
    );
    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(find.textContaining('本体の音量とは別'), findsOneWidget);
    expect(find.textContaining('トランシーバーの声が聞き取りにくいとき'), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(changed, isNotEmpty);
    expect(changed.every((v) => v >= 0.3 && v <= 1.0), isTrue);
    expect(volume.value, 0.3);
    expect(find.text('30%'), findsOneWidget);

    await tester.tap(find.text('この音量で鳴らす'));
    expect(tested, 1);
  });

  testWidgets('音量を渡さなければ入口を出さない', (tester) async {
    await pumpModal(tester);
    expect(find.textContaining('警告音の音量'), findsNothing);
  });

  testWidgets('監視中の地図の「音量」ボタンは1回でスライダーを出し、試し鳴らしは出さない', (tester) async {
    setView(tester);
    final volume = ValueNotifier<double>(0.8);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Center(
            child: WarningAudioVolumeMapButton(
              volume: volume,
              onChanged: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    // 監視中・航行中の試し鳴らしは、鳴っている本物の警告を止めてしまう。
    expect(find.text('この音量で鳴らす'), findsNothing);
  });
}
