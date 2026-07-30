import 'package:shared_preferences/shared_preferences.dart';

import '../config/risk_evaluator_config.dart';

/// 衝突警告の提示と予測に使う2つの先読み時間。
///
/// [primaryWarningLeadSeconds] は連続音へ上げる切替点、
/// [advanceWarningLeadSeconds] は断続音の開始点かつ予測地平である。
/// 予測地平を本警告より長く保つことで、予測が届かない先では音を鳴らさない。
class WarningLeadTimes {
  const WarningLeadTimes({
    required this.primaryWarningLeadSeconds,
    required this.advanceWarningLeadSeconds,
  });

  final double primaryWarningLeadSeconds;
  final double advanceWarningLeadSeconds;
}

/// 衝突リスク評価の端末内設定を保存・読み込みする。
class RiskEvaluatorSettingsService {
  // v1 は単一の「予測地平」だった。保存済みの値は予告側へ引き継ぐ。
  static const _legacyWarningTimeKey = 'risk_warning_time_seconds_v1';
  static const _primaryWarningLeadKey = 'risk_primary_warning_lead_seconds_v2';
  static const _advanceWarningLeadKey = 'risk_advance_warning_lead_seconds_v2';

  Future<WarningLeadTimes> loadWarningLeadTimes() async {
    final prefs = await SharedPreferences.getInstance();
    return _validated(
      primary: prefs.getDouble(_primaryWarningLeadKey),
      // v2がまだ無い既存端末では、従来の予測地平を予告時間として保つ。
      advance: prefs.getDouble(_advanceWarningLeadKey) ??
          prefs.getDouble(_legacyWarningTimeKey),
    );
  }

  Future<void> saveWarningLeadTimes(WarningLeadTimes values) async {
    final validated = _validated(
      primary: values.primaryWarningLeadSeconds,
      advance: values.advanceWarningLeadSeconds,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      _primaryWarningLeadKey,
      validated.primaryWarningLeadSeconds,
    );
    await prefs.setDouble(
      _advanceWarningLeadKey,
      validated.advanceWarningLeadSeconds,
    );
  }

  /// 旧API。外部呼出しが残っても、予測地平(予告)として安全に移行する。
  Future<double> loadWarningTime() async {
    return (await loadWarningLeadTimes()).advanceWarningLeadSeconds;
  }

  /// 旧API。単一値は予測地平(予告)だけを更新し、本警告は保持する。
  Future<void> saveWarningTime(double seconds) async {
    final current = await loadWarningLeadTimes();
    await saveWarningLeadTimes(WarningLeadTimes(
      primaryWarningLeadSeconds: current.primaryWarningLeadSeconds,
      advanceWarningLeadSeconds: seconds,
    ));
  }

  WarningLeadTimes _validated({
    required double? primary,
    required double? advance,
  }) {
    var resolvedAdvance = (advance == null || !advance.isFinite)
        ? advanceWarningLeadSeconds
        : advance
            .clamp(minWarningTimeSeconds, maxWarningTimeSeconds)
            .toDouble();
    var resolvedPrimary = (primary == null || !primary.isFinite)
        ? primaryWarningLeadSeconds
        : primary
            .clamp(
              minPrimaryWarningLeadSeconds,
              maxWarningTimeSeconds - primaryWarningLeadStepSeconds,
            )
            .toDouble();

    // 本警告は予告より必ず手前に置く。壊れた保存値を理由に予測地平を
    // 縮めないため、まず予告側を残し、その直前へ本警告を寄せる。
    if (resolvedPrimary >= resolvedAdvance) {
      resolvedPrimary = resolvedAdvance - primaryWarningLeadStepSeconds;
    }
    if (resolvedPrimary < minPrimaryWarningLeadSeconds) {
      resolvedAdvance = advanceWarningLeadSeconds;
      resolvedPrimary = primaryWarningLeadSeconds;
    }
    return WarningLeadTimes(
      primaryWarningLeadSeconds: resolvedPrimary,
      advanceWarningLeadSeconds: resolvedAdvance,
    );
  }
}
