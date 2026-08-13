import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/features/home_map/widgets/map_display_panel.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  late ValueNotifier<MapType> mapType;
  late ValueNotifier<bool> centerline;
  late ValueNotifier<bool> highContrast;
  late ValueNotifier<bool> laneCrossSection;

  setUp(() {
    mapType = ValueNotifier(MapType.normal);
    centerline = ValueNotifier(true);
    highContrast = ValueNotifier(false);
    laneCrossSection = ValueNotifier(false);
  });

  tearDown(() {
    mapType.dispose();
    centerline.dispose();
    highContrast.dispose();
    laneCrossSection.dispose();
  });

  Widget wrap({bool navigating = true}) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: MapDisplayPanel(
            mapType: mapType,
            onMapTypeChanged: (value) => mapType.value = value,
            showChannelCenterline: centerline,
            onShowChannelCenterlineChanged: (value) => centerline.value = value,
            highContrast: highContrast,
            onHighContrastChanged: (value) => highContrast.value = value,
            laneCrossSection: navigating ? laneCrossSection : null,
            onLaneCrossSectionChanged:
                navigating ? (value) => laneCrossSection.value = value : null,
          ),
        ),
      );

  testWidgets('切り替えても閉じず、続けて操作できる', (tester) async {
    // メニューの一覧に混ぜていた頃は、1つ押すたびにシートが閉じていた。
    await tester.pumpWidget(wrap());

    await tester.tap(find.text('航路の中央線'));
    await tester.pump();
    expect(centerline.value, isFalse);
    // パネルは開いたまま。
    expect(find.text('表示'), findsOneWidget);

    await tester.tap(find.text('高コントラスト'));
    await tester.pump();
    expect(highContrast.value, isTrue);
    expect(find.text('表示'), findsOneWidget);
  });

  testWidgets('航空写真では高コントラストが効かないことをその場で書く', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.text('地図を淡いグレーにし、危険区域を目立たせます'), findsOneWidget);

    await tester.tap(find.text('航空写真'));
    await tester.pump();

    expect(mapType.value, MapType.hybrid);
    expect(find.text('航空写真では適用されません'), findsOneWidget);
  });

  testWidgets('監視端末では航行中だけの行そのものを出さない', (tester) async {
    // 使えない項目を無効表示で並べるより、その状態に無い機能は
    // 最初から現れないほうが読む量が減る。
    await tester.pumpWidget(wrap(navigating: false));

    expect(find.text('航路の断面'), findsNothing);
    expect(find.text('航路の中央線'), findsOneWidget);
  });

  testWidgets('1ストロークの艇速の行は無い(航行中の波形は廃止)', (tester) async {
    await tester.pumpWidget(wrap());

    expect(find.text('1ストロークの艇速'), findsNothing);
  });
}
