import 'package:flutter_hooks/flutter_hooks.dart';

import '../models/boat_model.dart';
import '../models/workout_plan.dart';
import '../services/rowing_motion_fusion.dart';
import '../services/workout_engine.dart';
import '../services/workout_menu_store.dart';

/// 航行中のワークアウト。**表示専用**で、記録・安全判定に関わらない。
///
/// 計器の下半分での操作(2026-10-23 利用者):
/// - 待機(準備したメニューがあり、まだ始めていない)と READY は ▶ で始める。
/// - 実行中は ■ で止める。止めると同じメニューの待機へ戻るので、▶ で
///   1本目からやり直せる(■→▶ がリセット)。押し間違いは [undoStop] で戻す。
/// - 待機の × で下半分を元の計器へ戻す([dismiss])。
class UseWorkout {
  const UseWorkout({
    required this.plan,
    required this.status,
    required this.start,
    required this.startNow,
    required this.stop,
    required this.undoStop,
    required this.dismiss,
    required this.prepared,
    required this.prepare,
  });

  /// 実行中のメニュー。無ければ null。
  final WorkoutPlan? plan;
  final WorkoutStatus? status;

  /// メニューを選んで始める(シートから)。「漕ぎ出したら始める」なら READY。
  final void Function(WorkoutPlan plan) start;

  /// ▶。待機中なら準備したメニューの1本目を、READY なら漕ぎ出しを待たずに
  /// 1本目を始める。どちらでもなければ何もしない。
  final void Function() startNow;

  /// ■。実行中のメニューを止め、同じメニューの待機へ戻す。
  final void Function() stop;

  /// 直前の ■ を取り消し、止める前の続きへ戻す。
  final void Function() undoStop;

  /// 実行中・待機中のメニューをどちらも外し、下半分を元の計器へ戻す。
  final void Function() dismiss;

  /// 航行前に決めておいたメニュー、または ■ で止めたメニュー。無ければ null。
  ///
  /// 航行が始まると、「漕ぎ出したらワークを始める」のメニューは READY で始まり
  /// (漕ぎ出しで1本目)、そうでないメニューは待機のまま残って ▶ で始める。
  /// どちらも航行が終われば消える。
  final WorkoutPlan? prepared;

  /// 航行前のメニューを決める。null で取り消す。
  final void Function(WorkoutPlan? plan) prepare;
}

/// 本物の測位([fixProcessedAt] が進んだとき)と 1本ごとの解析結果で進める。
/// 推測した自艇の位置(GPS 途絶中)では進めない。値は描画の最中に同期して
/// 進める(`useLapMetrics` と同じ理由)。航行が終われば止める。
/// 航行前に決めたメニュー([UseWorkout.prepared])も、航行が終われば消す。
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
  final prepared = useState<WorkoutPlan?>(null);
  final wasNavigating = useRef(false);
  // ■ の取り消し用に、止める前の進み具合を持っておく。
  final stopped = useRef<WorkoutEngine?>(null);
  // エンジンの中身だけが変わったとき(READY→WORK)に描き直すため。
  final revision = useState(0);

  void begin(WorkoutPlan plan, {bool? waitForRowing}) {
    lastFix.value = null;
    lastStroke.value = motion?.latestStrokeBoundary;
    stopped.value = null;
    engine.value = WorkoutEngine(plan, waitForRowing: waitForRowing);
    // 始めたメニューが準備ぶんの役目を引き継ぐ(二重に残さない)。
    prepared.value = null;
    store.recordUse(plan, DateTime.now());
  }

  if (navigating != wasNavigating.value) {
    wasNavigating.value = navigating;
    final plan = prepared.value;
    if (plan != null) {
      if (!navigating) {
        // 航行が終わったら消す(次の航行へ持ち越さない)。
        Future.microtask(() => prepared.value = null);
      } else if (plan.autoStart) {
        // 航行開始。READY で待ち、漕ぎ出しで1本目が始まる。
        // 「漕ぎ出したら始める」でないメニューは、桟橋で1本目が始まって
        // しまうので自動では始めず、待機のまま残す(▶ で始める)。
        Future.microtask(() => begin(plan));
      }
    }
    if (!navigating) stopped.value = null;
  }

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

  void startNow() {
    final running = engine.value;
    if (running != null) {
      running.startNow();
      revision.value++;
      return;
    }
    final plan = prepared.value;
    // 自分で押したのだから、漕ぎ出しを待たずに1本目から始める。
    if (plan != null) begin(plan, waitForRowing: false);
  }

  void stop() {
    final running = engine.value;
    if (running == null) return;
    stopped.value = running;
    engine.value = null;
    prepared.value = running.plan;
  }

  void undoStop() {
    final previous = stopped.value;
    // 止めたあとに別のメニューを始めた・外したなら戻さない。
    if (previous == null ||
        engine.value != null ||
        prepared.value != previous.plan) {
      return;
    }
    stopped.value = null;
    prepared.value = null;
    // 止めていた間の本数は数えない(測位の空白は engine 側が飛ばす)。
    lastStroke.value = motion?.latestStrokeBoundary;
    engine.value = previous;
  }

  return UseWorkout(
    plan: e?.plan,
    status: e?.status,
    start: begin,
    startNow: startNow,
    stop: stop,
    undoStop: undoStop,
    dismiss: () {
      stopped.value = null;
      engine.value = null;
      prepared.value = null;
    },
    prepared: prepared.value,
    prepare: (plan) => prepared.value = plan,
  );
}
