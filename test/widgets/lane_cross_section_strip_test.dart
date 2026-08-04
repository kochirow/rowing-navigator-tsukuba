import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/lane_cross_section_strip.dart';
import 'package:rowing_navigator/services/channel_cross_section.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

void main() {
  Widget wrap(ChannelCrossSection section) => MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: LaneCrossSectionStrip(crossSection: section, portrait: true),
        ),
      );

  Finder strip() => find.byKey(const ValueKey('lane-cross-section-strip'));

  testWidgets('帯だけを描き、文字は一切持たない', (tester) async {
    // 「自分のレーン側」「中央線から◯m」といった読ませる文字は外した。
    // 帯が示すのは中央線からの位置だけで、それは形を見れば分かる。
    await tester.pumpWidget(wrap(const ChannelCrossSection(
      status: ChannelCrossSectionStatus.available,
      distanceFromCenterMeters: 12.4,
      boatSide: RowerSide.left,
      expectedSide: RowerSide.left,
    )));

    expect(strip(), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('対向レーン側でも文字は増やさない', (tester) async {
    await tester.pumpWidget(wrap(const ChannelCrossSection(
      status: ChannelCrossSectionStatus.available,
      distanceFromCenterMeters: 8,
      boatSide: RowerSide.right,
      expectedSide: RowerSide.left,
    )));

    expect(strip(), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('方位が不安定でも帯は消さない(原則6)', (tester) async {
    await tester.pumpWidget(wrap(const ChannelCrossSection(
      status: ChannelCrossSectionStatus.distanceOnly,
      distanceFromCenterMeters: 5.2,
    )));

    expect(strip(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('目盛りを振り切っても破綻しない', (tester) async {
    // 河口・霞ヶ浦は片側100m以上ある。端に張り付いた印を「岸にいる」と
    // 読ませないため、振り切りは丸印ではなく矢印で描く。
    await tester.pumpWidget(wrap(const ChannelCrossSection(
      status: ChannelCrossSectionStatus.available,
      distanceFromCenterMeters: 120,
      boatSide: RowerSide.right,
      expectedSide: RowerSide.right,
    )));

    expect(strip(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('航路外でも表示は消さず、同じ場所に残す', (tester) async {
    // 桟橋・休憩では航路外が正常。要素ごと消えると「いつもの場所」が
    // 毎回変わり、探す動作が増える。
    await tester.pumpWidget(wrap(ChannelCrossSection.unavailable));

    expect(strip(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
