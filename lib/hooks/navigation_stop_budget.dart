import '../config/navigator_config.dart';

/// 航行終了の残り時間を各工程へ配分する純粋な計算。
///
/// Dart の `Future.timeout` は元の処理を中止しないため、終了処理全体を
/// timeout で包まず、各工程に残り予算だけを渡す。
class NavigationStopBudget {
  const NavigationStopBudget({
    this.totalBudget = navigationStopTotalBudget,
    this.defaultStepTimeout = navigationStopStepTimeout,
  });

  final Duration totalBudget;
  final Duration defaultStepTimeout;

  /// [elapsed] 時点で1工程を待てる最大時間。予算切れなら null。
  Duration? timeoutFor(
    Duration elapsed, {
    Duration? preferredTimeout,
  }) {
    final remaining = totalBudget - elapsed;
    if (remaining <= Duration.zero) return null;
    final requested = preferredTimeout ?? defaultStepTimeout;
    return requested < remaining ? requested : remaining;
  }
}

/// 古い終了処理が、新しい状態を後から書き換えないための世代確認。
bool isCurrentStopGeneration({
  required int expected,
  required int current,
}) =>
    expected == current;
