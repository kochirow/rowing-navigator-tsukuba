import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/stroke_trace_config.dart';
import 'package:rowing_navigator/features/home_map/widgets/stroke_speed_chart.dart';
import 'package:rowing_navigator/features/home_map/widgets/stroke_trace_sheet.dart';
import 'package:rowing_navigator/models/shared_stroke_trace.dart';
import 'package:rowing_navigator/theme/app_theme.dart';

SharedStrokeTrace _trace(DateTime startedAt) => SharedStrokeTrace(
      strokeStartedAt: startedAt,
      strokeDuration: const Duration(milliseconds: 2400),
      baseSpeedMetersPerSecond: 4.2,
      relativeSpeeds: List<double>.generate(
        sharedStrokeWaveformSamples,
        (index) =>
            0.35 * math.sin(2 * math.pi * index / sharedStrokeWaveformSamples),
        growable: false,
      ),
      spm: 25,
      confidence: 0.8,
      distancePerStrokeMeters: 10.1,
      catchSpeedLossMetersPerSecond: 0.4,
      lateDriveSpeedGainMetersPerSecond: 0.12,
      recoverySpeedRetention: 0.75,
      finishPhaseFraction: 0.4,
    );

void main() {
  late DateTime now;
  late StreamController<SharedStrokeTrace?> controller;

  setUp(() {
    now = DateTime.utc(2026, 8, 3, 6);
    controller = StreamController<SharedStrokeTrace?>.broadcast();
  });

  tearDown(() => controller.close());

  /// broadcast streamの配信は1フレーム遅れる。受信後の描画まで進める。
  Future<void> deliver(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: StrokeTraceSheet(
            boatId: 'u2',
            displayName: '桜川一号',
            watch: (_) => controller.stream,
            clock: () => now,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('共有していない艇では、空白ではなく理由を出す', (tester) async {
    await pumpSheet(tester);

    expect(find.text('桜川一号'), findsOneWidget);
    expect(find.text('この艇は艇速変化を共有していません'), findsOneWidget);
    // グラフの枠は残す。消すと「壊れている」ように見える。
    expect(find.byType(StrokeSpeedChart), findsOneWidget);
  });

  testWidgets('波形を受け取ると指標と鮮度を出す', (tester) async {
    await pumpSheet(tester);

    controller.add(_trace(now.subtract(const Duration(milliseconds: 2400))));
    await deliver(tester);

    expect(find.text('0秒前のストローク'), findsOneWidget);
    expect(find.text('25 spm'), findsOneWidget);
    expect(find.text('1ストローク'), findsOneWidget);
    expect(find.text('10.1m'), findsOneWidget);
    expect(find.text('リカバリー保持'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
  });

  testWidgets('受信が途絶えたら、古い波形を今の漕ぎとして出し続けない', (tester) async {
    await pumpSheet(tester);
    controller.add(_trace(now.subtract(const Duration(milliseconds: 2400))));
    await deliver(tester);
    expect(find.textContaining('秒前のストローク'), findsOneWidget);

    now = now.add(
      const Duration(seconds: sharedStrokeTraceFreshnessSeconds + 2),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('秒前のストローク'), findsNothing);
    expect(find.textContaining('を最後に途絶'), findsOneWidget);
  });

  testWidgets('壊れたレコード(null)で表示を止めない', (tester) async {
    await pumpSheet(tester);

    controller.add(null);
    await deliver(tester);

    expect(find.byType(StrokeSpeedChart), findsOneWidget);
    expect(find.text('この艇は艇速変化を共有していません'), findsOneWidget);

    controller.add(_trace(now.subtract(const Duration(milliseconds: 2400))));
    await deliver(tester);
    expect(find.text('25 spm'), findsOneWidget);
  });

  testWidgets('受信経路の障害は理由として表示する', (tester) async {
    await pumpSheet(tester);

    controller.addError(StateError('permission-denied'));
    await deliver(tester);

    expect(find.text('受信できません'), findsOneWidget);
  });
}
