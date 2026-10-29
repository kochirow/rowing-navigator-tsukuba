import '../config/navigator_config.dart';
import 'conservative_position_estimator.dart';
import 'gnss_motion_validity.dart';

export 'gnss_motion_validity.dart';

/// 加速度センサー側の推定(`RowingMotionFusion.observeGnss`)へ渡す基準(純Dart)。
///
/// GNSSの速度が使えればその値(従来どおり)。使えない間は、保守側の推定が
/// 位置の変化から求めた速度を、速度精度の代わりの値
/// ([positionDerivedSpeedAccuracyMetersPerSecond])を付けて渡す。
/// iOSの速度精度±3.75m/sの値(実際の約1/4)を基準にすると、融合結果が
/// 高い信頼度のまま実際と違う速度を出す(2026-10-27 6:36)。
class FusionBase {
  final double speedMetersPerSecond;
  final double? headingDegrees;
  final GnssMotionSource source;
  final double? speedAccuracyMetersPerSecond;

  const FusionBase({
    required this.speedMetersPerSecond,
    required this.headingDegrees,
    required this.source,
    required this.speedAccuracyMetersPerSecond,
  });

  /// どちらの速度も無ければ null(基準を更新しない)。
  static FusionBase? select({
    required double? speedMetersPerSecond,
    required double? speedAccuracyMetersPerSecond,
    required double? headingDegrees,
    required double? headingAccuracyDegrees,
    required ConservativeUpdateResult? conservativeResult,
  }) {
    final validity = GnssMotionValidity.evaluate(
      speedMetersPerSecond: speedMetersPerSecond,
      speedAccuracyMetersPerSecond: speedAccuracyMetersPerSecond,
      headingDegrees: headingDegrees,
      headingAccuracyDegrees: headingAccuracyDegrees,
    );
    // 棄却された測位では、前回の出力が返ってくる。それを今回の基準にしない。
    final conservative =
        conservativeResult != null && conservativeResult.accepted
            ? conservativeResult.output
            : null;
    final double speed;
    final GnssMotionSource source;
    double? speedAccuracy;
    if (validity.speedUsable) {
      speed = speedMetersPerSecond!;
      source = GnssMotionSource.gnss;
    } else if (conservative != null &&
        conservative.speedSource == GnssMotionSource.position) {
      speed = conservative.observedSpeedMetersPerSecond;
      source = GnssMotionSource.position;
      speedAccuracy = positionDerivedSpeedAccuracyMetersPerSecond;
    } else {
      return null;
    }
    final double? heading;
    if (speed <= 0.05) {
      // 停止速度は方位に依存しない(従来どおり)。
      heading = 0.0;
    } else if (validity.headingUsable && speed >= stoppedSpeedThreshold) {
      heading = headingDegrees;
    } else if (conservative != null && conservative.headingReliable) {
      heading = conservative.headingDegrees;
    } else {
      heading = null;
    }
    return FusionBase(
      speedMetersPerSecond: speed,
      headingDegrees: heading,
      source: source,
      speedAccuracyMetersPerSecond: speedAccuracy,
    );
  }
}
