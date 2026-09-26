import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/workout_plan.dart';

/// 登録したメニュー(名前つき)。
class SavedWorkout {
  const SavedWorkout({required this.name, required this.plan});
  final String name;
  final WorkoutPlan plan;
}

/// 過去のメニュー(使った日時つき)。
class UsedWorkout {
  const UsedWorkout({required this.usedAt, required this.plan});
  final DateTime usedAt;
  final WorkoutPlan plan;
}

/// ワークアウトのメニューを端末内に保存する。サーバーへは送らない。
///
/// - 登録したメニュー: 練習前に作って「★ 登録」したもの。航行中はここから呼び出すだけ。
/// - 過去のメニュー: 使うたびに先頭へ。同じ中身はまとめる。最大 [historyLimit] 件。
/// 読み書きに失敗しても航行・警告は止めない(空として扱う)。
class WorkoutMenuStore {
  static const _favoritesKey = 'workout_favorites_v1';
  static const _historyKey = 'workout_history_v1';
  static const historyLimit = 30;

  Future<List<SavedWorkout>> loadFavorites() async {
    final raw = await _readList(_favoritesKey);
    return [
      for (final e in raw)
        if (WorkoutPlan.tryFromJson(e['plan'] as Map<String, dynamic>)
            case final plan?)
          SavedWorkout(name: e['name'] as String? ?? '', plan: plan),
    ];
  }

  Future<List<UsedWorkout>> loadHistory() async {
    final raw = await _readList(_historyKey);
    return [
      for (final e in raw)
        if (WorkoutPlan.tryFromJson(e['plan'] as Map<String, dynamic>)
            case final plan?)
          UsedWorkout(
            usedAt: DateTime.tryParse(e['usedAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
            plan: plan,
          ),
    ];
  }

  /// 登録する。同じ中身がすでにあれば名前だけ差し替える。
  Future<void> saveFavorite(SavedWorkout workout) async {
    final list = await loadFavorites();
    list.removeWhere((w) => w.plan.sameMenuAs(workout.plan));
    list.add(workout);
    await _writeList(_favoritesKey, [
      for (final w in list) {'name': w.name, 'plan': w.plan.toJson()},
    ]);
  }

  Future<void> removeFavorite(WorkoutPlan plan) async {
    final list = await loadFavorites();
    list.removeWhere((w) => w.plan.sameMenuAs(plan));
    await _writeList(_favoritesKey, [
      for (final w in list) {'name': w.name, 'plan': w.plan.toJson()},
    ]);
  }

  /// 使ったメニューを過去の先頭へ。
  Future<void> recordUse(WorkoutPlan plan, DateTime at) async {
    final list = await loadHistory();
    list.removeWhere((w) => w.plan.sameMenuAs(plan));
    list.insert(0, UsedWorkout(usedAt: at, plan: plan));
    await _writeList(_historyKey, [
      for (final w in list.take(historyLimit))
        {'usedAt': w.usedAt.toIso8601String(), 'plan': w.plan.toJson()},
    ]);
  }

  Future<List<Map<String, dynamic>>> _readList(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(key);
      if (text == null) return const [];
      return (jsonDecode(text) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeList(String key, List<Map<String, dynamic>> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(list));
    } catch (_) {
      // 保存できなくても航行は続ける。
    }
  }
}
