import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../config/stroke_rate_config.dart';
import '../models/shared_stroke_trace.dart';
import '../services/rowing_motion_fusion.dart';
import '../services/stroke_rate_analyzer.dart';
import '../services/stroke_speed_trace.dart';

/// 加速度センサからストロークレート(SPM)を計測するフック。
/// [active]かつ[enabled]がtrueの間だけセンサを購読する(電池への配慮)。
/// SPM不要の運用では[enabled]をfalseにし、加速度センサと解析タイマーを
/// 完全に停止できる。
///
/// グラフ用の連続波形は[enabled]と同時に動き出す。表示ON/OFFや監視共有の
/// ON/OFFでは切らない。**1サンプルあたりの追加処理は積分1回**で、
/// リングバッファも14秒ぶん(350点)しかない。ここを別スイッチにすると、
/// 「計測はONなのにグラフだけ出ない」状態を作るだけで得るものがない。
UseStrokeRate useStrokeRate({
  required bool active,
  bool enabled = false,
  void Function(String type, Map<String, dynamic> details)? onDiagnosticEvent,
}) {
  final spm = useState<double?>(null);
  final motion = useState<RowingMotionMetrics?>(null);
  final latestStrokeTrace = useState<SharedStrokeTrace?>(null);
  final accelerationSubscription = useState<StreamSubscription?>(null);
  final gravitySubscription = useState<StreamSubscription?>(null);
  final gyroscopeSubscription = useState<StreamSubscription?>(null);
  final updateTimer = useState<Timer?>(null);
  final fusion = useMemoized(RowingMotionFusion.new);
  final lastLoggedStrokeBoundary = useRef<DateTime?>(null);
  final lastHealthLogAt = useRef<DateTime?>(null);

  useEffect(() {
    fusion.setTraceEnabled(active && enabled);
    if (!(active && enabled)) latestStrokeTrace.value = null;
    return null;
  }, [active, enabled]);

  useEffect(() {
    if (!active || !enabled) {
      accelerationSubscription.value?.cancel();
      gravitySubscription.value?.cancel();
      gyroscopeSubscription.value?.cancel();
      accelerationSubscription.value = null;
      gravitySubscription.value = null;
      gyroscopeSubscription.value = null;
      updateTimer.value?.cancel();
      updateTimer.value = null;
      fusion.reset();
      spm.value = null;
      motion.value = null;
      latestStrokeTrace.value = null;
      return null;
    }

    try {
      accelerationSubscription.value = userAccelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: spmSamplingMs),
      ).listen((event) {
        final sample = StrokeRateSample(
          timestamp: event.timestamp,
          x: event.x,
          y: event.y,
          z: event.z,
        );
        fusion.addUserAcceleration(sample);
      }, onError: (e) {
        debugPrint('Accelerometer error: $e');
        onDiagnosticEvent?.call('imu_sensor_error', {
          'sensor': 'user_accelerometer',
          'error': e.runtimeType.toString(),
        });
      });
      gravitySubscription.value = accelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: spmSamplingMs),
      ).listen((event) {
        fusion.addGravity(RowingGravitySample(
          timestamp: event.timestamp,
          x: event.x,
          y: event.y,
          z: event.z,
        ));
      }, onError: (e) {
        debugPrint('Raw accelerometer error: $e');
        onDiagnosticEvent?.call('imu_sensor_error', {
          'sensor': 'accelerometer',
          'error': e.runtimeType.toString(),
        });
      });
      gyroscopeSubscription.value = gyroscopeEventStream(
        samplingPeriod: const Duration(milliseconds: spmSamplingMs),
      ).listen((event) {
        fusion.addGyroscope(RowingGyroscopeSample(
          timestamp: event.timestamp,
          x: event.x,
          y: event.y,
          z: event.z,
        ));
      }, onError: (e) {
        debugPrint('Gyroscope error: $e');
        onDiagnosticEvent?.call('imu_sensor_error', {
          'sensor': 'gyroscope',
          'error': e.runtimeType.toString(),
        });
      });
    } catch (e) {
      debugPrint('Motion sensor unavailable: $e');
      onDiagnosticEvent?.call('imu_sensor_error', {
        'sensor': 'startup',
        'error': e.runtimeType.toString(),
      });
    }

    updateTimer.value =
        Timer.periodic(const Duration(seconds: spmUpdateIntervalSec), (_) {
      final estimate = fusion.analyze();
      motion.value = estimate;
      spm.value = estimate?.spm;
      final now = DateTime.now();
      if (estimate != null) {
        final boundary = estimate.latestStrokeBoundary;
        if (lastLoggedStrokeBoundary.value == null ||
            boundary.isAfter(lastLoggedStrokeBoundary.value!)) {
          lastLoggedStrokeBoundary.value = boundary;
          onDiagnosticEvent?.call(
            'stroke_motion_analyzed',
            estimate.toDiagnosticDetails(),
          );
          // 新しい1ストロークが確定したときだけ共有候補を作る。
          // 波形が切り出せなければ null のまま(欠測を捏造しない)。
          final trace = fusion.buildSharedStrokeTrace(estimate);
          if (trace != null) latestStrokeTrace.value = trace;
        }
      }
      if (lastHealthLogAt.value == null ||
          now.difference(lastHealthLogAt.value!) >=
              const Duration(seconds: 10)) {
        lastHealthLogAt.value = now;
        onDiagnosticEvent?.call('imu_fusion_health', {
          'available': estimate != null,
          if (estimate != null) ...{
            'quality': estimate.quality.name,
            'confidence': estimate.confidence,
            'accelerometerSamples': estimate.accelerometerSampleCount,
            'gyroscopeSamples': estimate.gyroscopeSampleCount,
          },
        });
      }
    });

    return () {
      accelerationSubscription.value?.cancel();
      gravitySubscription.value?.cancel();
      gyroscopeSubscription.value?.cancel();
      updateTimer.value?.cancel();
    };
  }, [active, enabled]);

  return UseStrokeRate(
    spm: spm,
    motion: motion,
    latestStrokeTrace: latestStrokeTrace,
    // 描画フレームごとに呼ばれる。状態を変えず、リングから切り出すだけ。
    traceWindow: ({required DateTime now, double? windowSeconds}) =>
        fusion.traceWindow(
      now: now,
      windowSeconds:
          windowSeconds ?? strokeTraceWindowSecondsFor(spm: spm.value),
    ),
    observeGnss: ({
      required timestamp,
      required speedMetersPerSecond,
      required accuracyMeters,
      headingDegrees,
    }) {
      fusion.observeGnss(
        timestamp: timestamp,
        speedMetersPerSecond: speedMetersPerSecond,
        accuracyMeters: accuracyMeters,
        headingDegrees: headingDegrees,
      );
      final estimate = fusion.analyze(now: timestamp);
      if (estimate != null) {
        motion.value = estimate;
        spm.value = estimate.spm;
      }
    },
  );
}

class UseStrokeRate {
  final ValueNotifier<double?> spm;
  final ValueNotifier<RowingMotionMetrics?> motion;

  /// 直近に確定した1ストロークを、監視端末へ送れる形にしたもの。
  /// **作るだけで送らない。** 送るかどうかは共有の設定が決める。
  final ValueNotifier<SharedStrokeTrace?> latestStrokeTrace;

  /// グラフ1画面ぶんの切り出し。**再buildを起こさない**ため
  /// ValueNotifierではなく関数で渡す(描画側がフレームごとに引く)。
  final StrokeSpeedTraceWindow? Function({
    required DateTime now,
    double? windowSeconds,
  }) traceWindow;

  final void Function({
    required DateTime timestamp,
    required double speedMetersPerSecond,
    required double accuracyMeters,
    double? headingDegrees,
  }) observeGnss;

  UseStrokeRate({
    required this.spm,
    required this.motion,
    required this.latestStrokeTrace,
    required this.traceWindow,
    required this.observeGnss,
  });
}
