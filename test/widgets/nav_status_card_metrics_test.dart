import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/features/home_map/widgets/nav_status_card.dart';
import 'package:rowing_navigator/services/gps_health_monitor.dart';
import 'package:rowing_navigator/features/home_map/widgets/stroke_speed_chart.dart';
import 'package:rowing_navigator/services/rowing_motion_fusion.dart';
import 'package:rowing_navigator/services/stroke_speed_trace.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

/// 計器の大きさが状況で変わらないことを守るテスト。
///
/// 元の実装は連続音の警告中に主計器を縮めていた(`deemphasized`)。
/// 大きさが変わること自体が読み取りを遅らせるため廃止した。
/// 「警告中だから縮める」たぐいの分岐が戻ってきたら、ここで落ちる。
void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    bool spmEnabled = true,
    bool compact = false,
    bool portraitCompact = false,
    GpsHealthQuality quality = GpsHealthQuality.good,
    bool degraded = false,
    RowingMotionMetrics? strokeMotion,
    bool showStrokeMotion = false,
    StrokeSpeedTraceWindow? Function(DateTime now)? traceWindowBuilder,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: NavStatusCard(
            paceSeconds: 120,
            distanceMeters: 1000,
            elapsedTimeSeconds: 60,
            spm: 24,
            spmMeasurementEnabled: spmEnabled,
            strokeMotion: strokeMotion,
            strokeMotionDisplayEnabled: showStrokeMotion,
            strokeTraceWindowBuilder: traceWindowBuilder,
            compact: compact,
            portraitCompact: portraitCompact,
            gpsQuality: quality,
            otherBoatReceiveUnavailable: degraded,
          ),
        ),
      ),
    );
  }

  double fontSizeOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!.fontSize!;

  testWidgets('主計器はペース52px・SPM44px', (tester) async {
    await pumpCard(tester);

    expect(fontSizeOf(tester, '2:00'), 52);
    expect(fontSizeOf(tester, '24'), 44);
  });

  testWidgets('補助情報(距離・経過時間)は主計器よりはっきり小さい', (tester) async {
    await pumpCard(tester);

    expect(fontSizeOf(tester, '1.00 km'), 16);
    expect(fontSizeOf(tester, '1:00'), 16);
    expect(fontSizeOf(tester, '1.00 km'), lessThan(fontSizeOf(tester, '2:00')));
  });

  testWidgets('GPS途絶・受信不可が出ても主計器の大きさは変わらない', (tester) async {
    await pumpCard(tester);
    final normalPace = fontSizeOf(tester, '2:00');
    final normalSpm = fontSizeOf(tester, '24');

    await pumpCard(
      tester,
      quality: GpsHealthQuality.unusable,
      degraded: true,
    );

    expect(fontSizeOf(tester, '2:00'), normalPace);
    expect(fontSizeOf(tester, '24'), normalSpm);
  });

  testWidgets('SPMは計測ONなら常時表示する', (tester) async {
    await pumpCard(tester, spmEnabled: true);
    expect(find.text('24'), findsOneWidget);

    // OFFのときだけ表示領域ごと取り除く(従来どおり)。
    await pumpCard(tester, spmEnabled: false);
    expect(find.text('24'), findsNothing);
  });

  testWidgets('縦向き小型でもSPMを消さない', (tester) async {
    await pumpCard(tester, portraitCompact: true);

    expect(find.text('24 spm'), findsOneWidget);
    expect(fontSizeOf(tester, '2:00'), 46);
  });

  testWidgets('横向き小型でもSPMを消さない', (tester) async {
    await pumpCard(tester, compact: true);

    expect(find.text('24 spm'), findsOneWidget);
    expect(fontSizeOf(tester, '2:00'), 30);
  });

  testWidgets('1ストローク艇速指標を信頼度付き計測時だけ表示する', (tester) async {
    final metrics = RowingMotionMetrics(
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
      lateDriveSpeedGainMetersPerSecond: 0.18,
      recoverySpeedRetention: 0.84,
      strokeSpeedRangeMetersPerSecond: 0.8,
      strokeDurationSeconds: 2.5,
      finishPhaseFraction: 0.62,
      accelerometerSampleCount: 125,
      gyroscopeSampleCount: 125,
    );
    await pumpCard(
      tester,
      strokeMotion: metrics,
      showStrokeMotion: true,
    );

    expect(find.byKey(const ValueKey('stroke-motion-metrics')), findsOneWidget);
    // 値はラベルと数値に分けて並べる。符号を隠さない。
    // ラベルは競技の用語(キャッチ・ドライブ・リカバリー)に揃える。
    expect(find.text('1ストローク'), findsOneWidget);
    expect(find.text('10.2m'), findsOneWidget);
    expect(find.text('キャッチ減速'), findsOneWidget);
    expect(find.text('−0.31'), findsOneWidget);
    expect(find.text('リカバリー保持'), findsOneWidget);
    expect(find.text('84%'), findsOneWidget);
    expect(find.text('ドライブ後半加速'), findsOneWidget);
    expect(find.text('+0.18'), findsOneWidget);

    await pumpCard(tester, strokeMotion: metrics);
    expect(find.byKey(const ValueKey('stroke-motion-metrics')), findsNothing);

    await pumpCard(
      tester,
      spmEnabled: false,
      strokeMotion: metrics,
      showStrokeMotion: true,
    );
    expect(find.byKey(const ValueKey('stroke-motion-metrics')), findsOneWidget);
  });

  testWidgets('艇速分析は主計器の直下に表示する', (tester) async {
    final metrics = RowingMotionMetrics(
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
      lateDriveSpeedGainMetersPerSecond: 0.18,
      recoverySpeedRetention: 0.84,
      strokeSpeedRangeMetersPerSecond: 0.8,
      strokeDurationSeconds: 2.5,
      finishPhaseFraction: 0.62,
      accelerometerSampleCount: 125,
      gyroscopeSampleCount: 125,
    );
    await pumpCard(tester, strokeMotion: metrics, showStrokeMotion: true);

    final analysisY = tester
        .getTopLeft(find.byKey(const ValueKey('stroke-motion-metrics')))
        .dy;
    final distanceY = tester.getTopLeft(find.text('1.00 km')).dy;
    expect(analysisY, lessThan(distanceY));
  });

  testWidgets('ドライブ後半の失速は符号ごとラベルを切り替えて出す', (tester) async {
    await pumpCard(
      tester,
      strokeMotion: _metrics(lateDriveSpeedGainMetersPerSecond: -0.22),
      showStrokeMotion: true,
    );

    expect(find.text('ドライブ後半失速'), findsOneWidget);
    expect(find.text('−0.22'), findsOneWidget);
    expect(find.text('ドライブ後半加速'), findsNothing);
  });

  testWidgets('解析が確定する前でもグラフの枠は出す(壊れて見せない)', (tester) async {
    await pumpCard(
      tester,
      showStrokeMotion: true,
      // 立ち上がり直後は窓を作れない。それでもグラフ領域は残す(原則1)。
      traceWindowBuilder: (_) => null,
    );

    expect(find.byType(StrokeSpeedChart), findsOneWidget);
    expect(find.byKey(const ValueKey('stroke-motion-metrics')), findsNothing);
  });

  testWidgets('表示OFFならグラフごと領域を取り除く', (tester) async {
    await pumpCard(tester, traceWindowBuilder: (_) => null);

    expect(find.byType(StrokeSpeedChart), findsNothing);
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
