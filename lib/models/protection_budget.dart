import 'dart:math' as math;

/// 保護領域を広げる要因を由来別に記録する台帳。
///
/// **なぜ内訳を持つのか。** 以前の `pairGpsCenterDistanceGuardMeters` は
/// `sqrt(accA²+accB²)×0.20` を上限2.5mでクランプしていた。推定器が報告する
/// accuracy は95%半径(≈10m)なので、この式は**常に上限で飽和**しており、
/// 測位が良くても悪くても同じ2.5mだった。つまり帯が情報を持っていなかった。
/// 由来別に持てば「なぜ広いのか」を説明でき、どの改善がどの誤差を
/// 減らしたかも測れる。
///
/// **相対と絶対を分ける(DGNSS の原理)。** 同じ水域・同じ時刻の2受信機は
/// 誤差の共通成分(電離層・軌道・衛星時計)が相殺する。2026-08-06 の実機ログで
/// 実測した: 同一艇に載せた2台の真の位置差 1.5〜2m に対し、raw の位置差は
/// 中央値 1.7m だった。したがって艇間の相対誤差はほぼ 0 であり、
/// 絶対精度を2乗和する式は**二重計上**になる。
///
/// - 静的危険区域(絶対座標に固定)には [absoluteTotalMeters]
/// - 他艇(相対幾何)には [relativeTotalMeters]
///
/// ## 未達: 飽和の解消（2026-08-06 時点）
///
/// 内訳は持てるようになったが、[gnssMeasurementMeters] は呼出側
/// (`pairProtectionBudget`)で**上限 2.5m にクランプしたまま**である。
/// 「測位品質に応じて伸び縮みさせる」という当初の狙いは達成していない。
///
/// クランプを外すと、DESIGN_PRINCIPLES 3.2 の検算(狭所で 8+ 同士が
/// すれ違うと最悪 13.90m 必要で、レーン幅 12.5m を既に 1.4m 超過)が
/// さらに悪化し、桜川の狭所で過剰警告になる(原則4)。外してよいかは
/// **Stage 2 後の accuracy 分布を実機ログで確認してから**判断する。
/// それまでは飽和したままのほうが安全側である。
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

  /// 他艇との相対幾何へ加える保護量 [m]。
  ///
  /// **成分ごとに合成の仕方を変える。全部を二乗和にしない。**
  ///
  /// - 独立な確率誤差(測位雑音・モデル不一致)は二乗和。
  ///   互いに打ち消し合うことがあるため。
  /// - 「最悪どこまで動けたか」を表す上限成分(fixAge・通信遅延・
  ///   速度不明・方位不明・解の食い違い)は**線形加算**。
  ///   これらは確率的に相殺しないので、二乗和にすると過小評価になる。
  double get relativeTotalMeters =>
      _quadrature(gnssMeasurementMeters, modelMismatchMeters) +
      fixAgeMotionMeters +
      remoteLatencyMeters +
      solutionDisagreementMeters +
      headingUnknownMeters +
      speedUnknownMeters;

  /// 静的危険区域(絶対座標に固定)へ加える保護量 [m]。
  ///
  /// 相対と違い共通誤差が相殺しないため、測位誤差をそのまま使う。
  /// 通信遅延は自艇には効かないので含めない。
  double get absoluteTotalMeters =>
      _quadrature(gnssMeasurementMeters, modelMismatchMeters) +
      fixAgeMotionMeters +
      solutionDisagreementMeters +
      headingUnknownMeters +
      speedUnknownMeters;

  static double _quadrature(double a, double b) =>
      a == 0 ? b : (b == 0 ? a : math.sqrt(a * a + b * b));

  ProtectionBudget copyWith({
    double? gnssMeasurementMeters,
    double? fixAgeMotionMeters,
    double? solutionDisagreementMeters,
    double? remoteLatencyMeters,
    double? headingUnknownMeters,
    double? speedUnknownMeters,
    double? modelMismatchMeters,
  }) =>
      ProtectionBudget(
        gnssMeasurementMeters:
            gnssMeasurementMeters ?? this.gnssMeasurementMeters,
        fixAgeMotionMeters: fixAgeMotionMeters ?? this.fixAgeMotionMeters,
        solutionDisagreementMeters:
            solutionDisagreementMeters ?? this.solutionDisagreementMeters,
        remoteLatencyMeters: remoteLatencyMeters ?? this.remoteLatencyMeters,
        headingUnknownMeters:
            headingUnknownMeters ?? this.headingUnknownMeters,
        speedUnknownMeters: speedUnknownMeters ?? this.speedUnknownMeters,
        modelMismatchMeters: modelMismatchMeters ?? this.modelMismatchMeters,
      );

  Map<String, double> toDiagnosticDetails() => {
        'gnssMeasurementMeters': gnssMeasurementMeters,
        'fixAgeMotionMeters': fixAgeMotionMeters,
        'solutionDisagreementMeters': solutionDisagreementMeters,
        'remoteLatencyMeters': remoteLatencyMeters,
        'headingUnknownMeters': headingUnknownMeters,
        'speedUnknownMeters': speedUnknownMeters,
        'modelMismatchMeters': modelMismatchMeters,
        'diagnosticTotalMeters': totalMeters,
        'relativeTotalMeters': relativeTotalMeters,
        'absoluteTotalMeters': absoluteTotalMeters,
      };
}
