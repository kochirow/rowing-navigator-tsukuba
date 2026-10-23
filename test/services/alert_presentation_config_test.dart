import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/alert_presentation_config.dart';
import 'package:rowing_navigator/config/risk_evaluator_config.dart';

/// 設定値どうしの不等式を固定する。
///
/// Duration は const 式で比較できないため、コンストラクタの assert では
/// 表現できない。設定値の意図と実効値の乖離を検出する唯一の手段として
/// ここで担保する(CLAUDE.md「設定値には前提を書く」)。
void main() {
  const config = defaultAlertPresentationConfig;

  test('鳴り始め13秒は予測地平と一致し、確度が低いときは10秒まで待つ', () {
    expect(
      config.lowConfidenceAudioStartDeadline,
      Duration(milliseconds: (primaryWarningLeadSeconds * 1000).round()),
    );
    expect(
      config.audioStartDeadline,
      Duration(milliseconds: (advanceWarningLeadSeconds * 1000).round()),
    );
    expect(
      config.lowConfidenceAudioStartDeadline,
      lessThanOrEqualTo(config.audioStartDeadline),
    );
    expect(advanceWarningLeadSeconds, greaterThan(primaryWarningLeadSeconds));
    expect(primaryWarningLeadSeconds, greaterThanOrEqualTo(8.5));
    expect(defaultWarningTimeSeconds, advanceWarningLeadSeconds);
  });

  test('区域進入の読み上げ周期は5秒(衝突警告の繰り返しより薄い)', () {
    // カーブ・逆走は「いま操作を変えろ」ではなく「この先の形に備えろ」。
    // 衝突警告と同じ密度で鳴らすと、5m/sで20〜40秒かかるカーブ区域の
    // 通過中に何度も鳴り、原則4(過剰警告は安全機能の破壊)へ直行する。
    // 衝突警告は読み上げを間を空けずに繰り返す(1種類)。
    expect(config.guidanceRepeatInterval, const Duration(seconds: 5));
  });

  test('区域進入の読み上げ周期は再武装間隔と衝突しない', () {
    // 周期 <= 再武装間隔 だと、区域の境界を跨ぐたびに
    // 「再進入の1回目」と「滞在中の鳴り直し」が区別できなくなる。
    expect(
      config.guidanceRepeatInterval,
      greaterThanOrEqualTo(config.guidanceRearmDuration),
    );
  });
}
