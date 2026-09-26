import 'package:flutter_hooks/flutter_hooks.dart';

import '../models/boat_model.dart';
import '../models/workout_plan.dart';
import '../services/rowing_motion_fusion.dart';
import '../services/workout_engine.dart';
import '../services/workout_menu_store.dart';

/// 航行中のワークアウト。**表示専用**で、記録・安全判定に関わらない。
class UseWorkout {
  const UseWorkout({
    required this.plan,
    required this.status,
    required this.start,
    required this.stop,
  });

  /// 実行中のメニュー。無ければ null。
  final WorkoutPlan? plan;
  final WorkoutStatus? status;
  final void Function(WorkoutPlan plan) start;
  final void Function() stop;
}

/// 本物の測位([fixProcessedAt] が進んだとき)と 1本ごとの解析結果で進める。
/// 推測した自艇の位置(GPS 途絶中)では進めない。値は描画の最中に同期して
/// 進める(`useLapMetrics` と同じ理由)。航行が終われば止める。
UseWorkout useWorkout({
  required Boat? myBoat,
  required DateTime fixProcessedAt,
  required double totalDistanceMeters,
  required RowingMotionMetrics? motion,
  required bool navigating,
}) {
  final engine = useState<WorkoutEngine?>(null);
  final lastFix = useRef<DateTime?>(null);
  final lastStroke = useRef<DateTime?>(null);
  final store = useMemoized(WorkoutMenuStore.new);

  final e = engine.value;
  if (e != null && !navigating) {
    // 航行が終わったら止める(次の航行へ持ち越さない)。
    Future.microtask(() => engine.value = null);
  }
  if (e != null && myBoat != null && fixProcessedAt != lastFix.value) {
    lastFix.value = fixProcessedAt;
    e.onFix(
      at: myBoat.timestamp,
      speedMetersPerSecond: myBoat.speed,
      totalDistanceMeters: totalDistanceMeters,
    );
  }
  final boundary = motion?.latestStrokeBoundary;
  if (e != null && boundary != null) {
    final last = lastStroke.value;
    if (last == null || boundary.isAfter(last)) {
      if (last != null) e.onStroke();
      lastStroke.value = boundary;
    }
  }

  return UseWorkout(
    plan: e?.plan,
    status: e?.status,
    start: (plan) {
      lastFix.value = null;
      lastStroke.value = motion?.latestStrokeBoundary;
      engine.value = WorkoutEngine(plan);
      store.recordUse(plan, DateTime.now());
    },
    stop: () => engine.value = null,
  );
}
