import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../config/stroke_rate_config.dart';
import '../services/stroke_rate_analyzer.dart';

/// 加速度センサからストロークレート(SPM)を計測するフック。
/// [active]かつ[enabled]がtrueの間だけセンサを購読する(電池への配慮)。
/// SPM不要の運用では[enabled]をfalseにし、加速度センサと解析タイマーを
/// 完全に停止できる。
UseStrokeRate useStrokeRate({required bool active, bool enabled = false}) {
  final spm = useState<double?>(null);
  final sensorSubscription = useState<StreamSubscription?>(null);
  final updateTimer = useState<Timer?>(null);
  // 実際のセンサー時刻を含む3軸加速度のリングバッファ。
  final buffer = useRef<Queue<StrokeRateSample>>(Queue<StrokeRateSample>());
  final analyzer = StrokeRateAnalyzer();

  useEffect(() {
    if (!active || !enabled) {
      sensorSubscription.value?.cancel();
      sensorSubscription.value = null;
      updateTimer.value?.cancel();
      updateTimer.value = null;
      buffer.value.clear();
      spm.value = null;
      return null;
    }

    try {
      sensorSubscription.value = userAccelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: spmSamplingMs),
      ).listen((event) {
        final sample = StrokeRateSample(
          timestamp: event.timestamp,
          x: event.x,
          y: event.y,
          z: event.z,
        );
        buffer.value.addLast(sample);
        while (buffer.value.isNotEmpty &&
            sample.timestamp.difference(buffer.value.first.timestamp) >
                const Duration(seconds: spmWindowSec)) {
          buffer.value.removeFirst();
        }
      }, onError: (e) {
        debugPrint('Accelerometer error: $e'); // センサ非搭載端末では計測しない
      });
    } catch (e) {
      debugPrint('Accelerometer unavailable: $e');
    }

    updateTimer.value =
        Timer.periodic(const Duration(seconds: spmUpdateIntervalSec), (_) {
      spm.value = analyzer.estimate(buffer.value.toList())?.spm;
    });

    return () {
      sensorSubscription.value?.cancel();
      updateTimer.value?.cancel();
    };
  }, [active, enabled]);

  return UseStrokeRate(spm: spm);
}

class UseStrokeRate {
  final ValueNotifier<double?> spm;

  UseStrokeRate({required this.spm});
}
