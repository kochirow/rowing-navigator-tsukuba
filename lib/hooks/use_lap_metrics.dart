import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/home_map/widgets/nav_lower_drums.dart';
import '../models/boat_model.dart';
import '../services/lap_metrics_tracker.dart';
import '../services/rowing_motion_fusion.dart';

/// 計器の下半分(ドラム)の値と操作。**表示専用**で、記録・安全判定に関わらない。
class UseLapMetrics {
  const UseLapMetrics({
    required this.values,
    required this.leftIndex,
    required this.rightIndex,
    required this.setLeftIndex,
    required this.setRightIndex,
    required this.reset,
    required this.undoReset,
  });

  final NavLowerValues values;
  final int leftIndex;
  final int rightIndex;
  final void Function(int) setLeftIndex;
  final void Function(int) setRightIndex;

  /// 距離・chrono・count の表示を0にする。
  final void Function() reset;

  /// 直前の RESET を取り消す。
  final void Function() undoReset;
}

const _leftKey = 'nav_lower_drum_left_v1';
const _rightKey = 'nav_lower_drum_right_v1';

/// [myBoat] の本物の測位([fixProcessedAt] が進んだとき)と [motion]
/// (1本ごとの解析結果)を受けて、リセットからの
/// 距離・chrono・count を進める。
///
/// 値は**描画の最中に同期して進める**(effect で進めると1回ぶん表示が遅れ、
/// 進めるたびに画面全体をもう一度描き直すことになる)。同じ更新を2度
/// 数えないよう、最後に処理した物を覚えておく。
UseLapMetrics useLapMetrics({
  required Boat? myBoat,
  required DateTime fixProcessedAt,
  required double totalDistanceMeters,
  required RowingMotionMetrics? motion,
  required DateTime? sessionStartedAt,
}) {
  final tracker = useMemoized(LapMetricsTracker.new);
  final lastSession = useRef<DateTime?>(null);
  final lastFix = useRef<DateTime?>(null);
  final lastMotion = useRef<RowingMotionMetrics?>(null);
  final version = useState(0);
  final left = useState(NavLowerMetric.distance.index);
  final right = useState(NavLowerMetric.chrono.index);

  if (sessionStartedAt != lastSession.value) {
    lastSession.value = sessionStartedAt;
    tracker.restart();
  }
  // 本物の測位を処理したときだけ進める(`UseNavigator.postProcessTime`)。
  // GPS が途切れている間は推測した自艇の位置が入るが、それを「漕いでいた」
  // ことにしない(データの欠けを安全・記録の根拠にしない。原則6)。
  if (myBoat != null && fixProcessedAt != lastFix.value) {
    lastFix.value = fixProcessedAt;
    tracker.onPosition(
      at: myBoat.timestamp,
      speedMetersPerSecond: myBoat.speed,
      totalDistanceMeters: totalDistanceMeters,
    );
  }
  if (motion != null && !identical(motion, lastMotion.value)) {
    lastMotion.value = motion;
    tracker.onStroke(motion.latestStrokeBoundary);
  }

  // 左右の選択は端末に残し、次の航行も同じ並びで始める。
  useEffect(() {
    var alive = true;
    SharedPreferences.getInstance().then((prefs) {
      if (!alive) return;
      final l = prefs.getInt(_leftKey), r = prefs.getInt(_rightKey);
      final count = NavLowerMetric.values.length;
      if (l != null && l >= 0 && l < count) left.value = l;
      if (r != null && r >= 0 && r < count) right.value = r;
    }).catchError((_) {
      // 読めなくても既定(距離・chrono)で続ける。
    });
    return () => alive = false;
  }, const []);

  void save(String key, int value) {
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt(key, value))
        .catchError((_) => false);
  }

  return UseLapMetrics(
    values: NavLowerValues(
      distanceMeters: tracker.lapDistanceMeters,
      chronoSeconds: tracker.lapRowingSeconds,
      dpsMeters: motion?.distancePerStrokeMeters,
      strokeCount: motion == null ? null : tracker.lapStrokes,
    ),
    leftIndex: left.value,
    rightIndex: right.value,
    setLeftIndex: (i) {
      left.value = i;
      save(_leftKey, i);
    },
    setRightIndex: (i) {
      right.value = i;
      save(_rightKey, i);
    },
    reset: () {
      tracker.reset();
      version.value++;
    },
    undoReset: () {
      if (tracker.undoReset()) version.value++;
    },
  );
}
