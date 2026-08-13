import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/stroke_metrics_chips.dart';
import 'package:rowing_navigator/services/rowing_motion_fusion.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

/// 1ストローク指標の見せ方を守るテスト。
///
/// 航行中の計器カードからは艇速変化グラフごと外した(2026-08-13)ので、
/// この widget は監視端末の [StrokeTraceSheet] だけが使う。それでも
/// 「良い・悪いを断定しない」「符号を隠さない」は残す方針なので、
/// 値の組み方はここで固定しておく。
void main() {
  Future<void> pumpChips(
    WidgetTester tester,
    RowingMotionMetrics metrics,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: StrokeMetricsChips.fromMetrics(metrics),
        ),
      ),
    );
  }

  testWidgets('ラベルと数値の対で並べ、競技の用語に揃える', (tester) async {
    await pumpChips(tester, _metrics());

    expect(find.byKey(const ValueKey('stroke-motion-metrics')), findsOneWidget);
    expect(find.text('1ストローク'), findsOneWidget);
    expect(find.text('10.2m'), findsOneWidget);
    expect(find.text('キャッチ減速'), findsOneWidget);
    expect(find.text('−0.31'), findsOneWidget);
    expect(find.text('リカバリー保持'), findsOneWidget);
    expect(find.text('84%'), findsOneWidget);
    expect(find.text('ドライブ後半加速'), findsOneWidget);
    expect(find.text('+0.18'), findsOneWidget);
  });

  testWidgets('ドライブ後半の失速は符号ごとラベルを切り替えて出す', (tester) async {
    await pumpChips(
      tester,
      _metrics(lateDriveSpeedGainMetersPerSecond: -0.22),
    );

    expect(find.text('ドライブ後半失速'), findsOneWidget);
    expect(find.text('−0.22'), findsOneWidget);
    expect(find.text('ドライブ後半加速'), findsNothing);
  });
}

RowingMotionMetrics _metrics({
  double lateDriveSpeedGainMetersPerSecond = 0.18,
}) =>
    RowingMotionMetrics(
      calculatedAt: DateTime(2026, 8, 3),
      latestStrokeBoundary: DateTime(2026, 8, 3),
      quality: RowingMotionQuality.good,
      confidence: 0.9,
      spm: 24,
      fusedSpeedMetersPerSecond: 4,
      fusedSpeedAccuracyMetersPerSecond: 0.5,
      fusedHeadingDegrees: 90,
      distancePerStrokeMeters: 10.2,
      catchSpeedLossMetersPerSecond: 0.31,
      lateDriveSpeedGainMetersPerSecond: lateDriveSpeedGainMetersPerSecond,
      recoverySpeedRetention: 0.84,
      strokeSpeedRangeMetersPerSecond: 0.8,
      strokeDurationSeconds: 2.5,
      finishPhaseFraction: 0.62,
      accelerometerSampleCount: 125,
      gyroscopeSampleCount: 125,
    );
