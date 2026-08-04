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

  testWidgets('自分のレーン側にいるときは、状態と距離を出す', (tester) async {
    await tester.pumpWidget(wrap(const ChannelCrossSection(
      status: ChannelCrossSectionStatus.available,
      distanceFromCenterMeters: 12.4,
      boatSide: RowerSide.left,
      expectedSide: RowerSide.left,
    )));

    expect(find.text('自分のレーン側'), findsOneWidget);
    expect(find.text('中央線から 12m'), findsOneWidget);
  });

  testWidgets('対向レーン側は言葉で言う(色だけに頼らない)', (tester) async {
    await tester.pumpWidget(wrap(const ChannelCrossSection(
      status: ChannelCrossSectionStatus.available,
      distanceFromCenterMeters: 8,
      boatSide: RowerSide.right,
      expectedSide: RowerSide.left,
    )));

    expect(find.text('対向レーン側にいます'), findsOneWidget);
    expect(find.text('中央線から 8m'), findsOneWidget);
  });

  testWidgets('方位が不安定でも距離は消さない(原則6)', (tester) async {
    await tester.pumpWidget(wrap(const ChannelCrossSection(
      status: ChannelCrossSectionStatus.distanceOnly,
      distanceFromCenterMeters: 5.2,
    )));

    expect(find.text('左右は方位が定まってから'), findsOneWidget);
    expect(find.text('中央線から 5m'), findsOneWidget);
  });

  testWidgets('目盛りを振り切っても実距離は数値で必ず出す', (tester) async {
    // 河口・霞ヶ浦は片側100m以上ある。端に張り付いた印を「岸にいる」と
    // 読ませないため、数値を消さない。
    await tester.pumpWidget(wrap(const ChannelCrossSection(
      status: ChannelCrossSectionStatus.available,
      distanceFromCenterMeters: 120,
      boatSide: RowerSide.right,
      expectedSide: RowerSide.right,
    )));

    expect(find.text('中央線から 120m'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('航路外でも表示は消さず、同じ場所に残す', (tester) async {
    // 桟橋・休憩では航路外が正常。要素ごと消えると「いつもの場所」が
    // 毎回変わり、探す動作が増える。
    await tester.pumpWidget(wrap(ChannelCrossSection.unavailable));

    expect(
      find.byKey(const ValueKey('lane-cross-section-strip')),
      findsOneWidget,
    );
    expect(find.text('航路の外'), findsOneWidget);
  });
}
