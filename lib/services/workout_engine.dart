import '../models/workout_plan.dart';

enum WorkoutPhase { ready, work, rest, setRest, done }

/// いまのワークアウトの状態(表示用)。
class WorkoutStatus {
  const WorkoutStatus({
    required this.phase,
    required this.rep,
    required this.totalReps,
    required this.remaining,
    this.restFraction,
    this.paused = false,
  });

  final WorkoutPhase phase;

  /// いまの本(1始まり、セットを通した通し番号)。レスト中は直前に終えた本。
  final int rep;
  final int totalReps;

  /// いまの区間の残り(m・秒・本)。レスト未定では経過秒。
  final double remaining;

  /// レストの残りの割合(1→0)。満タンから減っていく帯に使う。未定なら null。
  final double? restFraction;

  /// 遅いので数えていない(ワーク中だけ)。
  final bool paused;
}

/// ワークアウトの進み方(純Dart・表示専用)。安全判定・記録に関わらない。
///
/// 1秒ごとの測位([onFix])と、1本ごとの解析結果([onStroke])で進む。
/// - ワーク: 「遅いときは数えない」なら、目安の速度未満の間は距離・時間・本数を進めない。
/// - 本間レスト: 時間は満タンから減り 0 で次のワーク。本数・距離も同様。
///   未定は、漕ぎ出したら(目安の速度以上)次のワーク。
/// - セット間レスト: 時間で減り 0 で次のセット。
/// - 「漕ぎ出したら始める」なら、最初のワークは漕ぎ出しで始まる。
class WorkoutEngine {
  WorkoutEngine(this.plan)
      : _phase = plan.autoStart ? WorkoutPhase.ready : WorkoutPhase.work;

  final WorkoutPlan plan;

  WorkoutPhase _phase;
  int _rep = 1;
  double _progress = 0; // いまの区間で進んだ量
  double _elapsedRest = 0;
  bool _paused = false;
  DateTime? _lastAt;
  double? _lastDistance;

  /// 漕ぎ出し・遅い の境目。「遅いときは数えない」が無効でも、漕ぎ出しの
  /// 判定には 1m/s を使う(止まっている揺れで始まらないように)。
  double get _startSpeed =>
      plan.excludeSlow ? plan.slowSpeedMetersPerSecond : 1.0;

  void onFix({
    required DateTime at,
    required double speedMetersPerSecond,
    required double totalDistanceMeters,
  }) {
    final lastAt = _lastAt;
    final lastDistance = _lastDistance;
    _lastAt = at;
    _lastDistance = totalDistanceMeters;
    if (lastAt == null || lastDistance == null || !at.isAfter(lastAt)) return;
    final dt = at.difference(lastAt).inMilliseconds / 1000;
    if (dt > 5) return; // 測位の空白は数えない
    final dd = (totalDistanceMeters - lastDistance).clamp(0, 1000).toDouble();
    final moving = speedMetersPerSecond >= _startSpeed;
    switch (_phase) {
      case WorkoutPhase.ready:
        if (moving) _startWork();
      case WorkoutPhase.work:
        _paused = plan.excludeSlow && !moving;
        if (_paused) return;
        if (plan.workUnit == WorkUnit.distance) _advanceWork(dd);
        if (plan.workUnit == WorkUnit.time) _advanceWork(dt);
      case WorkoutPhase.rest:
        if (plan.restUnit == RestUnit.open) {
          _elapsedRest += dt;
          if (moving) _startWork();
        } else {
          if (plan.restUnit == RestUnit.time) _advanceRest(dt);
          if (plan.restUnit == RestUnit.distance) _advanceRest(dd);
        }
      case WorkoutPhase.setRest:
        _elapsedRest += dt;
        if (_elapsedRest >= plan.setRestSeconds) _startWork();
      case WorkoutPhase.done:
        break;
    }
  }

  void onStroke() {
    if (_phase == WorkoutPhase.work &&
        !_paused &&
        plan.workUnit == WorkUnit.strokes) {
      _advanceWork(1);
    } else if (_phase == WorkoutPhase.rest &&
        plan.restUnit == RestUnit.strokes) {
      _advanceRest(1);
    }
  }

  void _startWork() {
    _phase = WorkoutPhase.work;
    _progress = 0;
    _elapsedRest = 0;
    _paused = false;
  }

  void _advanceWork(double amount) {
    _progress += amount;
    if (_progress < plan.workValue) return;
    // 1本終わり。
    if (_rep >= plan.totalReps) {
      _phase = WorkoutPhase.done;
      return;
    }
    final endOfSet = _rep % plan.reps == 0;
    _rep++;
    _progress = 0;
    _elapsedRest = 0;
    _phase = endOfSet ? WorkoutPhase.setRest : WorkoutPhase.rest;
  }

  void _advanceRest(double amount) {
    _elapsedRest += amount;
    if (_elapsedRest >= plan.restValue) _startWork();
  }

  WorkoutStatus get status {
    final total = plan.totalReps;
    switch (_phase) {
      case WorkoutPhase.ready:
      case WorkoutPhase.work:
        return WorkoutStatus(
          phase: _phase,
          rep: _rep,
          totalReps: total,
          remaining: (plan.workValue - _progress).clamp(0, double.infinity),
          paused: _paused,
        );
      case WorkoutPhase.rest:
        if (plan.restUnit == RestUnit.open) {
          return WorkoutStatus(
            phase: _phase,
            rep: _rep,
            totalReps: total,
            remaining: _elapsedRest,
          );
        }
        final left = (plan.restValue - _elapsedRest).clamp(0, double.infinity);
        return WorkoutStatus(
          phase: _phase,
          rep: _rep,
          totalReps: total,
          remaining: left.toDouble(),
          restFraction: plan.restValue <= 0 ? 0 : left / plan.restValue,
        );
      case WorkoutPhase.setRest:
        final left =
            (plan.setRestSeconds - _elapsedRest).clamp(0, double.infinity);
        return WorkoutStatus(
          phase: _phase,
          rep: _rep,
          totalReps: total,
          remaining: left.toDouble(),
          restFraction:
              plan.setRestSeconds <= 0 ? 0 : left / plan.setRestSeconds,
        );
      case WorkoutPhase.done:
        return WorkoutStatus(
          phase: _phase,
          rep: total,
          totalReps: total,
          remaining: 0,
        );
    }
  }
}
