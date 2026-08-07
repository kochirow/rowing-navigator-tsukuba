/// 保護領域を広げる要因を由来別に記録する台帳。
///
/// Stage 1 では診断専用であり、[totalMeters] を安全判定に使ってはならない。
/// 合成規則（単純和か二乗和か）は Stage 3 で決定する。
class ProtectionBudget {
  final double gnssMeasurementMeters;
  final double fixAgeMotionMeters;
  final double solutionDisagreementMeters;
  final double remoteLatencyMeters;
  final double headingUnknownMeters;
  final double speedUnknownMeters;
  final double modelMismatchMeters;

  const ProtectionBudget({
    this.gnssMeasurementMeters = 0,
    this.fixAgeMotionMeters = 0,
    this.solutionDisagreementMeters = 0,
    this.remoteLatencyMeters = 0,
    this.headingUnknownMeters = 0,
    this.speedUnknownMeters = 0,
    this.modelMismatchMeters = 0,
  })  : assert(gnssMeasurementMeters >= 0),
        assert(fixAgeMotionMeters >= 0),
        assert(solutionDisagreementMeters >= 0),
        assert(remoteLatencyMeters >= 0),
        assert(headingUnknownMeters >= 0),
        assert(speedUnknownMeters >= 0),
        assert(modelMismatchMeters >= 0);

  /// 診断上の単純和。安全半径の合成規則ではない。
  double get totalMeters =>
      gnssMeasurementMeters +
      fixAgeMotionMeters +
      solutionDisagreementMeters +
      remoteLatencyMeters +
      headingUnknownMeters +
      speedUnknownMeters +
      modelMismatchMeters;

  Map<String, double> toDiagnosticDetails() => {
        'gnssMeasurementMeters': gnssMeasurementMeters,
        'fixAgeMotionMeters': fixAgeMotionMeters,
        'solutionDisagreementMeters': solutionDisagreementMeters,
        'remoteLatencyMeters': remoteLatencyMeters,
        'headingUnknownMeters': headingUnknownMeters,
        'speedUnknownMeters': speedUnknownMeters,
        'modelMismatchMeters': modelMismatchMeters,
        'diagnosticTotalMeters': totalMeters,
      };
}
