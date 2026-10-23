import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_setting_modal.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    ValueNotifier<double>? volume,
    Future<void> Function(double)? onChanged,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: NavSettingModal(
              onPressStartNav: (_, __) async {},
              onPressTestAudio: () async {},
              warningAudioVolume: volume,
              onWarningAudioVolumeChanged: onChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('音量を動かすと30%〜100%の値で知らせる', (tester) async {
    final volume = ValueNotifier<double>(1.0);
    final changed = <double>[];
    await pump(tester, volume: volume, onChanged: (v) async => changed.add(v));

    final slider = find.byType(Slider);
    await tester.scrollUntilVisible(
      slider,
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.text('100%'), findsOneWidget);

    // 左端まで動かしても下限(30%)で止まる。
    await tester.drag(slider, const Offset(-1000, 0));
    await tester.pumpAndSettle();

    expect(changed, isNotEmpty);
    expect(changed.every((v) => v >= 0.3 && v <= 1.0), isTrue);
    expect(volume.value, 0.3);
    expect(find.text('30%'), findsOneWidget);
  });

  testWidgets('音量を渡さなければ欄を出さない', (tester) async {
    await pump(tester);
    expect(find.byType(Slider), findsNothing);
  });
}
