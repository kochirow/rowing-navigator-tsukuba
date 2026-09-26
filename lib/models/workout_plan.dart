/// ワークアウトのメニュー(Concept2 PM5 に倣う)。**表示専用**で安全判定に関わらない。
///
/// ワークとレストを、それぞれ 距離・時間・本数 で決め、本数(回数)×セットを掛ける。
/// 例: 500m×8 r2:00、30:00×2 r5:00、30本×6 r3本×2セット。
/// 1本ごとの休み=**本間レスト**、セットとセットの間=**セット間レスト**。
library;

enum WorkUnit { distance, time, strokes }

/// 本間レストの単位。[open] は「未定」(次のワークを漕ぎ出したら始まる。
/// Concept2 の undefined rest)。回頭・待ち合わせで長さが変わる水上向け。
enum RestUnit { time, strokes, distance, open }

class WorkoutPlan {
  const WorkoutPlan({
    required this.workUnit,
    required this.workValue,
    required this.reps,
    required this.restUnit,
    required this.restValue,
    this.sets = 1,
    this.setRestSeconds = 300,
    this.excludeSlow = true,
    this.slowPaceSecondsPer500 = 180,
    this.autoStart = true,
  });

  /// 1本の長さ(m・秒・本)。
  final WorkUnit workUnit;
  final int workValue;

  /// 1セットの本数(回数)。
  final int reps;

  /// 本間レスト(秒・本・m。open のときは使わない)。
  final RestUnit restUnit;
  final int restValue;

  final int sets;
  final int setRestSeconds;

  /// 遅いときはワークに数えない(回頭・停止をワークの距離・時間・本数に入れない)。
  final bool excludeSlow;

  /// 「遅い」の目安(このペースより遅いとき)。秒/500m。
  final int slowPaceSecondsPer500;

  /// 漕ぎ出したらワークを始める(合図を押さなくてよい)。
  final bool autoStart;

  int get totalReps => reps * sets;

  /// 「遅い」の境目の速度 [m/s]。
  double get slowSpeedMetersPerSecond => 500 / slowPaceSecondsPer500;

  WorkoutPlan copyWith({
    WorkUnit? workUnit,
    int? workValue,
    int? reps,
    RestUnit? restUnit,
    int? restValue,
    int? sets,
    int? setRestSeconds,
    bool? excludeSlow,
    int? slowPaceSecondsPer500,
    bool? autoStart,
  }) =>
      WorkoutPlan(
        workUnit: workUnit ?? this.workUnit,
        workValue: workValue ?? this.workValue,
        reps: reps ?? this.reps,
        restUnit: restUnit ?? this.restUnit,
        restValue: restValue ?? this.restValue,
        sets: sets ?? this.sets,
        setRestSeconds: setRestSeconds ?? this.setRestSeconds,
        excludeSlow: excludeSlow ?? this.excludeSlow,
        slowPaceSecondsPer500:
            slowPaceSecondsPer500 ?? this.slowPaceSecondsPer500,
        autoStart: autoStart ?? this.autoStart,
      );

  /// メニューの中身が同じか(履歴のまとめ・登録の重複判定用)。
  bool sameMenuAs(WorkoutPlan o) =>
      workUnit == o.workUnit &&
      workValue == o.workValue &&
      reps == o.reps &&
      restUnit == o.restUnit &&
      (restUnit == RestUnit.open || restValue == o.restValue) &&
      sets == o.sets &&
      (sets == 1 || setRestSeconds == o.setRestSeconds);

  Map<String, dynamic> toJson() => {
        'workUnit': workUnit.name,
        'workValue': workValue,
        'reps': reps,
        'restUnit': restUnit.name,
        'restValue': restValue,
        'sets': sets,
        'setRestSeconds': setRestSeconds,
        'excludeSlow': excludeSlow,
        'slowPaceSecondsPer500': slowPaceSecondsPer500,
        'autoStart': autoStart,
      };

  static WorkoutPlan? tryFromJson(Map<String, dynamic> j) {
    try {
      return WorkoutPlan(
        workUnit: WorkUnit.values.byName(j['workUnit'] as String),
        workValue: (j['workValue'] as num).toInt(),
        reps: (j['reps'] as num).toInt(),
        restUnit: RestUnit.values.byName(j['restUnit'] as String),
        restValue: (j['restValue'] as num).toInt(),
        sets: (j['sets'] as num?)?.toInt() ?? 1,
        setRestSeconds: (j['setRestSeconds'] as num?)?.toInt() ?? 300,
        excludeSlow: j['excludeSlow'] as bool? ?? true,
        slowPaceSecondsPer500:
            (j['slowPaceSecondsPer500'] as num?)?.toInt() ?? 180,
        autoStart: j['autoStart'] as bool? ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// `30:00` / `1:00:00`。
String formatWorkoutClock(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// 1本の長さの表記(`500m` / `30:00` / `30本`)。
String formatWorkValue(WorkUnit unit, int value) => switch (unit) {
      WorkUnit.distance => '${value}m',
      WorkUnit.time => formatWorkoutClock(value),
      WorkUnit.strokes => '$value本',
    };

/// レストの表記(`r2:00` / `r3本` / `r200m` / `レスト未定`)。
String formatRest(RestUnit unit, int value) => switch (unit) {
      RestUnit.time => 'r${formatWorkoutClock(value)}',
      RestUnit.strokes => 'r$value本',
      RestUnit.distance => 'r${value}m',
      RestUnit.open => 'レスト未定',
    };

/// 短い名前(`500m×8`、`30本×6×2セット`)。
String workoutShortName(WorkoutPlan p) {
  final base = '${formatWorkValue(p.workUnit, p.workValue)}×${p.reps}';
  return p.sets > 1 ? '$base×${p.sets}セット' : base;
}
