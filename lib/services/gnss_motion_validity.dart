import '../config/navigator_config.dart';

/// 採用した速度・方位の出どころ。診断ログ(`speed_source` / `heading_source`)に残す。
enum GnssMotionSource {
  /// 使えると判定したGNSS(iOS/Android)の値。
  gnss,

  /// 直前の測位からの位置の変化で求めた値。
  position,

  /// どちらも得られず、前の値を保持している。
  held,
}

/// 速度・方位を「使えない」とした理由。診断ログに残す。
enum GnssMotionRejectReason {
  /// 使える。
  none,

  /// 値そのものが無い・負・非有限。
  invalidValue,

  /// 精度の値がしきい値以上。
  accuracy,
}

/// 1回の測位ごとの、GNSSの速度と方位の「使える/使えない」判定(純Dart)。
///
/// 位置の品質(`gnss_quality`)とは別物である。iOSは位置の品質が `good` のまま、
/// 速度精度±3.75m/s・方位精度±180°の状態に入り、その間の速度は実際の約1/4、
/// 方位は直前の値で止まる(2026-10-27・28 実機ログ)。
///
/// 精度が0以下・非有限(Androidで精度を出さない端末など)は「精度不明」として、
/// 今までどおり値を使う。Androidの実機ログはまだ分析していないため挙動を変えない。
class GnssMotionValidity {
  final bool speedUsable;
  final bool headingUsable;
  final GnssMotionRejectReason speedReason;
  final GnssMotionRejectReason headingReason;

  /// 精度が出ていた(0より大きい有限値)か。
  final bool speedAccuracyKnown;
  final bool headingAccuracyKnown;

  const GnssMotionValidity({
    required this.speedUsable,
    required this.headingUsable,
    required this.speedReason,
    required this.headingReason,
    required this.speedAccuracyKnown,
    required this.headingAccuracyKnown,
  });

  static GnssMotionValidity evaluate({
    required double? speedMetersPerSecond,
    required double? speedAccuracyMetersPerSecond,
    required double? headingDegrees,
    required double? headingAccuracyDegrees,
  }) {
    final speedAccuracyKnown = _known(speedAccuracyMetersPerSecond);
    final headingAccuracyKnown = _known(headingAccuracyDegrees);
    final speedValueValid = speedMetersPerSecond != null &&
        speedMetersPerSecond.isFinite &&
        speedMetersPerSecond >= 0;
    final headingValueValid = headingDegrees != null &&
        headingDegrees.isFinite &&
        headingDegrees >= 0 &&
        headingDegrees < 360;
    final speedReason = !speedValueValid
        ? GnssMotionRejectReason.invalidValue
        : speedAccuracyKnown &&
                speedAccuracyMetersPerSecond! >=
                    gnssSpeedUnusableAccuracyMetersPerSecond
            ? GnssMotionRejectReason.accuracy
            : GnssMotionRejectReason.none;
    final headingReason = !headingValueValid
        ? GnssMotionRejectReason.invalidValue
        : headingAccuracyKnown &&
                headingAccuracyDegrees! >= gnssHeadingUnusableAccuracyDegrees
            ? GnssMotionRejectReason.accuracy
            : GnssMotionRejectReason.none;
    return GnssMotionValidity(
      speedUsable: speedReason == GnssMotionRejectReason.none,
      headingUsable: headingReason == GnssMotionRejectReason.none,
      speedReason: speedReason,
      headingReason: headingReason,
      speedAccuracyKnown: speedAccuracyKnown,
      headingAccuracyKnown: headingAccuracyKnown,
    );
  }

  static bool _known(double? accuracy) =>
      accuracy != null && accuracy.isFinite && accuracy > 0;

  Map<String, Object?> toDiagnosticDetails() => {
        'speedUsable': speedUsable,
        'headingUsable': headingUsable,
        'speedReason': speedReason.name,
        'headingReason': headingReason.name,
        'speedAccuracyKnown': speedAccuracyKnown,
        'headingAccuracyKnown': headingAccuracyKnown,
      };
}
