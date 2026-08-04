import 'package:flutter/widgets.dart';

import '../../types/home_phase.dart';

/// 出艇前のタブシェルと、地図画面のあいだの細い連絡路。
///
/// **状態の持ち主は変えない。** 位置共有・警告・記録・Wakelock は
/// すべて `HomeMapScreen` の `useNavigator` が持っている。タブを足すために
/// その持ち主を上へ移すと、フックの生存期間が変わって航行開始・終了、
/// `onDisconnect`、練習一括ログ、バックグラウンド復帰が巻き添えになる。
///
/// そこでシェル側は状態を一切持たず、
///
/// - いまどの [HomePhase] か(タブを出すかどうかの判断だけに使う)
/// - 地図画面が持っている処理を呼び戻すための関数
///
/// だけを受け取る。関数は `HomeMapScreen` が起動時に差し込み、
/// 破棄時に外す。差し込まれていなければ何もしない(準備タブは開ける)。
class HomeShellBridge {
  /// 地図画面が書き、シェルが読む。シェルからは書かない。
  final ValueNotifier<HomePhase> phase = ValueNotifier(HomePhase.ashore);

  /// 危険区域データを読み直す。設定画面や位置合わせ画面から戻ったあとに呼ぶ。
  Future<void> Function()? reloadObstacles;

  /// 開発者用の判定形状オーバーレイ設定を読み直す。
  Future<void> Function()? reloadDeveloperOverlay;

  /// 現在の端末状態画面を組み立てる。
  ///
  /// 表示する値(測位・受信状態・危険区域の件数)は地図画面が持っているので、
  /// 組み立てだけを預ける。準備タブから開いても、メニューから開いたときと
  /// 同じ値が出る。
  Widget Function()? buildDeviceStatusScreen;

  void dispose() {
    phase.dispose();
  }
}
