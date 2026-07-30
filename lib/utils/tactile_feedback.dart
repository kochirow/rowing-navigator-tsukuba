import 'package:flutter/services.dart';

/// 触覚フィードバック。
///
/// 濡れた手・手袋・揺れる艇の上では、押せたかどうかを確かめる手段が視覚しか
/// ない。屋外では効果音も風に消える。触覚は音より確実に届く経路なので、
/// 主要操作と連続音警告にだけ足す。
///
/// **失敗しても決して投げない。** 触覚は補助であり、これが原因で航行開始や
/// 警告経路が止まってはいけない(端末に振動子が無い、OS が拒否する、
/// テスト環境でプラットフォームチャネルが無い、のいずれもあり得る)。
class TactileFeedback {
  const TactileFeedback._();

  /// ボタンを押したときの軽い手応え。
  static void selection() {
    unawaited(HapticFeedback.selectionClick());
  }

  /// 連続音の警告が出た瞬間の強い手応え。
  ///
  /// 音が聞こえない状況(風・イヤホン無し・エルゴ音)で、連続音が鳴り始めた
  /// ことに気づくための冗長経路。同じ警告が続く間は繰り返さない。
  static void alert() {
    unawaited(HapticFeedback.heavyImpact());
  }

  static void unawaited(Future<void> future) {
    future.catchError((Object _) {});
  }
}
