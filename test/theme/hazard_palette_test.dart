import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/theme/app_theme.dart';
import 'package:rowing_navigator/theme/hazard_palette.dart';

void main() {
  /// HazardPalette は BuildContext からトークンを引くため、Theme 配下で評価する。
  Future<T> underTheme<T>(
    WidgetTester tester,
    T Function(BuildContext context) read,
  ) async {
    late T value;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) {
            value = read(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return value;
  }

  test('常時ある岸は薄く、点在する物体は濃く塗る', () {
    // 岸は release で約310枚に展開される。同じ濃さだと川の両側が一様に
    // 埋まり、本当に避けたい流木や中州がその中へ紛れる。
    expect(
      HazardPalette.fillOpacityOf('shore'),
      lessThan(HazardPalette.fillOpacityOf('driftwood')),
    );
    expect(
      HazardPalette.fillOpacityOf('shore'),
      lessThan(HazardPalette.fillOpacityOf('island')),
    );
    // 案内区域はその中間。
    expect(
      HazardPalette.fillOpacityOf('bridge'),
      inInclusiveRange(
        HazardPalette.fillOpacityOf('shore'),
        HazardPalette.fillOpacityOf('driftwood'),
      ),
    );
  });

  test('現地で登録した臨時区域は同じ種類の常設区域より目立たせる', () {
    expect(
      HazardPalette.fillOpacityOf('driftwood', isTemporary: true),
      greaterThan(HazardPalette.fillOpacityOf('driftwood')),
    );
    // 不透明度は1を超えない。
    expect(
      HazardPalette.fillOpacityOf('driftwood', isTemporary: true),
      lessThanOrEqualTo(1.0),
    );
  });

  test('岸は枚数が多いので輪郭線を細くする', () {
    expect(
      HazardPalette.strokeWidthOf('shore'),
      lessThan(HazardPalette.strokeWidthOf('driftwood')),
    );
  });

  testWidgets('種類ごとに違う色を返す', (tester) async {
    final colors = await underTheme(
      tester,
      (context) => [
        for (final category in const [
          'shore',
          'bridge',
          'island',
          'driftwood',
          'curve',
          'reverse',
        ])
          HazardPalette.colorOf(context, category),
      ],
    );

    // すべて異なること。同じ色があるとバナーと地図の対応が崩れる。
    expect(colors.toSet().length, colors.length);
  });

  testWidgets('未知のカテゴリでも色を返し、描画を落とさない', (tester) async {
    final color = await underTheme(
      tester,
      (context) => HazardPalette.colorOf(context, 'unknown_kind'),
    );
    expect(color, isNotNull);
  });

  testWidgets('テーマ色を先に読む版は、従来の版と同じ色を返す', (tester) async {
    // 地図の描画は useEffect の中で色を決めるため、build で読んだ AppColors を
    // 渡す版(…From)を使う。見た目を変えない置き換えであることを保証する。
    const categories = [
      'shore',
      'bridge',
      'bridgePier',
      'island',
      'driftwood',
      'pile',
      'other_boat',
      'curve',
      'reverse',
      'testZone',
      'unknown_kind',
    ];
    await underTheme(tester, (context) {
      final colors = context.colors;
      for (final category in categories) {
        expect(
          HazardPalette.colorFrom(colors, category),
          HazardPalette.colorOf(context, category),
          reason: category,
        );
        expect(
          HazardPalette.strokeColorFrom(colors, category),
          HazardPalette.strokeColorOf(context, category),
          reason: category,
        );
        for (final isTemporary in [false, true]) {
          expect(
            HazardPalette.fillColorFrom(
              colors,
              category,
              isTemporary: isTemporary,
            ),
            HazardPalette.fillColorOf(
              context,
              category,
              isTemporary: isTemporary,
            ),
            reason: '$category temporary=$isTemporary',
          );
        }
      }
      return null;
    });
  });

  testWidgets('useEffect の中で使っても flutter_hooks の assert で落ちない', (tester) async {
    // 2026-10-21: 地図画面が useEffect の中で HazardPalette.strokeColorOf
    // (= Theme.of)を呼び、debug ビルドで赤いエラー画面になった。
    // useEffect の本体は初回 build の途中(HookState.initHook)で走るため、
    // そこでは継承ウィジェットを読めない。build で読んだ色を渡せば通る。
    Color? stroke;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HookBuilder(
          builder: (context) {
            final colors = context.colors;
            useEffect(() {
              stroke = HazardPalette.strokeColorFrom(colors, 'driftwood');
              return null;
            }, [colors]);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(stroke, isNotNull);
  });
}
