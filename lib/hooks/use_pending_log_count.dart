import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../services/session_store_service.dart';
import '../types/home_phase.dart';

/// メニューの「練習記録」に出す、未送信のログ(15分・2km以上)の件数。表示だけに使う。
class PendingLogCount {
  final int value;

  /// すぐに数え直す(練習記録から戻ったとき用)。
  final Future<void> Function() refresh;

  const PendingLogCount(this.value, this.refresh);
}

/// 陸上の姿勢になったとき(地図を開いたとき・航行や監視を終えたとき)に数え直す。
/// メニューを開くたびには数えない(記録を全部読むので時間がかかる)。
/// 数えられなくても副題が出ないだけで、メニューは開ける。
PendingLogCount usePendingLogCount(HomePhase phase,
    {SessionStoreService? store}) {
  final count = useState(0);
  final context = useContext();
  Future<void> refresh() async {
    try {
      final n =
          await (store ?? SessionStoreService()).countPendingBulkLogExports();
      if (context.mounted) count.value = n;
    } catch (error) {
      debugPrint('Pending log count unavailable: $error');
    }
  }

  useEffect(() {
    if (phase != HomePhase.ashore) return null;
    // 航行の終わりの保存より先に数えないよう、少し待つ。
    final timer = Timer(const Duration(seconds: 3), () => unawaited(refresh()));
    return timer.cancel;
  }, [phase]);
  return PendingLogCount(count.value, refresh);
}
