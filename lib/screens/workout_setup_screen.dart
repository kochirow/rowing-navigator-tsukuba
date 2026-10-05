import 'package:flutter/material.dart';

import '../models/workout_plan.dart';
import '../services/workout_menu_store.dart';
import '../theme/app_theme.dart';
import '../theme/nav_palette.dart';

/// ワークアウトの設定(Concept2 PM5 に倣う)。
///
/// 練習の前にここで作って「★ 登録」しておくと、航行中はワークアウトのボタンから
/// 呼び出すだけでよい。「このメニューで始める」で作ったメニューを返す(pop)。
///
/// 上から順に決める5つのかたまり(選ぶ → ワーク → 本間レスト → セット →
/// 数え方と始め方)に分け、いまの内容を画面の下へ常に出す。
class WorkoutSetupScreen extends StatefulWidget {
  const WorkoutSetupScreen({super.key, this.initial});

  final WorkoutPlan? initial;

  @override
  State<WorkoutSetupScreen> createState() => _WorkoutSetupScreenState();
}

class _WorkoutSetupScreenState extends State<WorkoutSetupScreen> {
  final _store = WorkoutMenuStore();
  late WorkoutPlan _plan = widget.initial ??
      const WorkoutPlan(
        workUnit: WorkUnit.distance,
        workValue: 500,
        reps: 8,
        restUnit: RestUnit.time,
        restValue: 120,
      );
  List<SavedWorkout> _favorites = const [];
  List<UsedWorkout> _history = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await _store.loadFavorites();
    final h = await _store.loadHistory();
    if (mounted) {
      setState(() {
        _favorites = f;
        _history = h;
      });
    }
  }

  void _set(WorkoutPlan p) => setState(() => _plan = p);

  int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  void _stepWork(int d) {
    final step = switch (_plan.workUnit) {
      WorkUnit.distance => 100,
      WorkUnit.time => 60,
      WorkUnit.strokes => 5,
    };
    final lo = _plan.workUnit == WorkUnit.time ? 60 : 5;
    final hi = switch (_plan.workUnit) {
      WorkUnit.distance => 20000,
      WorkUnit.time => 7200,
      WorkUnit.strokes => 500,
    };
    _set(_plan.copyWith(workValue: _clamp(_plan.workValue + d * step, lo, hi)));
  }

  void _stepRest(int d) {
    final step = switch (_plan.restUnit) {
      RestUnit.time => 15,
      RestUnit.strokes => 1,
      RestUnit.distance => 50,
      RestUnit.open => 0,
    };
    _set(
        _plan.copyWith(restValue: _clamp(_plan.restValue + d * step, 1, 3600)));
  }

  Future<void> _register() async {
    final name = workoutShortName(_plan);
    await _store.saveFavorite(SavedWorkout(name: name, plan: _plan));
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('このメニューを登録しました。航行中はワークアウトのボタンから呼び出せます'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final p = _plan;
    final workTotal = p.workValue * p.reps * p.sets;
    return Scaffold(
      appBar: AppBar(title: const Text('ワークアウト')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          dimens.space4,
          dimens.space3,
          dimens.space4,
          dimens.space5,
        ),
        children: [
          Text(
            '上から順に決めます。いまの内容は、いつも画面の下に出ています。',
            style: TextStyle(color: colors.textSecondary),
          ),
          _SettingCard(
            step: 1,
            title: 'メニューを選ぶ',
            caption: '前に作ったメニューを使うときは、ここから選びます。'
                '新しく作るときは、そのまま 2 へ。',
            children: [
              const _SubLabel('登録したメニュー'),
              _Row(
                empty: 'まだありません。下で作って「登録」を押すと、ここに並びます。',
                children: [
                  for (final w in _favorites)
                    WorkoutMenuCard(
                      top: '★ ${w.name}',
                      plan: w.plan,
                      selected: w.plan.sameMenuAs(p),
                      onTap: () => _set(w.plan),
                      onLongPress: () async {
                        await _store.removeFavorite(w.plan);
                        await _load();
                      },
                    ),
                ],
              ),
              if (_favorites.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: dimens.space1),
                  child: Text(
                    '長く押すと、登録から外します。',
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                ),
              SizedBox(height: dimens.space3),
              const _SubLabel('過去のメニュー'),
              _Row(
                empty: 'まだありません。',
                children: [
                  for (final w in _history)
                    WorkoutMenuCard(
                      top: '${w.usedAt.month}/${w.usedAt.day}',
                      plan: w.plan,
                      selected: w.plan.sameMenuAs(p),
                      onTap: () => _set(w.plan),
                    ),
                ],
              ),
            ],
          ),
          _SettingCard(
            step: 2,
            title: 'ワーク',
            caption: '1本を何で区切るかと、その長さ・本数。',
            children: [
              _Seg<WorkUnit>(
                values: const {
                  WorkUnit.distance: '距離',
                  WorkUnit.time: '時間',
                  WorkUnit.strokes: '本数',
                },
                selected: p.workUnit,
                onChanged: (u) => _set(p.copyWith(
                  workUnit: u,
                  workValue: switch (u) {
                    WorkUnit.distance => 500,
                    WorkUnit.time => 300,
                    WorkUnit.strokes => 30,
                  },
                )),
              ),
              _Stepper(
                label: '1本の長さ',
                value: formatWorkValue(p.workUnit, p.workValue),
                onStep: _stepWork,
              ),
              _Stepper(
                label: '本数(回数)',
                value: '× ${p.reps}',
                onStep: (d) =>
                    _set(p.copyWith(reps: _clamp(p.reps + d, 1, 30))),
              ),
            ],
          ),
          _SettingCard(
            step: 3,
            title: '本間レスト',
            caption: '1本ごとの休み。',
            children: [
              _Seg<RestUnit>(
                values: const {
                  RestUnit.time: '時間',
                  RestUnit.strokes: '本数',
                  RestUnit.distance: '距離',
                  RestUnit.open: '未定',
                },
                selected: p.restUnit,
                onChanged: (u) => _set(p.copyWith(
                  restUnit: u,
                  restValue: switch (u) {
                    RestUnit.time => 120,
                    RestUnit.strokes => 3,
                    RestUnit.distance => 200,
                    RestUnit.open => 0,
                  },
                )),
              ),
              if (p.restUnit == RestUnit.open)
                Padding(
                  padding: EdgeInsets.only(top: dimens.space2),
                  child: Text(
                    '次のワークを漕ぎ出したら、自動で始まります。回頭・待ち合わせの長さが毎回違うときに。',
                    style: TextStyle(color: colors.textSecondary),
                  ),
                )
              else
                _Stepper(
                  label: 'レストの長さ',
                  value: formatRest(p.restUnit, p.restValue).substring(1),
                  onStep: _stepRest,
                ),
            ],
          ),
          _SettingCard(
            step: 4,
            title: 'セット',
            caption: '2〜3 を何回か繰り返すときだけ。1 のままなら繰り返しません。',
            children: [
              _Stepper(
                label: 'セット数',
                value: '× ${p.sets}',
                onStep: (d) =>
                    _set(p.copyWith(sets: _clamp(p.sets + d, 1, 10))),
              ),
              if (p.sets > 1)
                _Stepper(
                  label: 'セット間レスト',
                  value: formatWorkoutClock(p.setRestSeconds),
                  onStep: (d) => _set(p.copyWith(
                      setRestSeconds:
                          _clamp(p.setRestSeconds + d * 60, 60, 1800))),
                ),
            ],
          ),
          _SettingCard(
            step: 5,
            title: '数え方と始め方',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('遅いときはワークに数えない'),
                subtitle: const Text('回頭・止まっている間を、ワークの距離・時間・本数に入れない'),
                value: p.excludeSlow,
                onChanged: (v) => _set(p.copyWith(excludeSlow: v)),
              ),
              if (p.excludeSlow)
                _Stepper(
                  label: '遅いとみなすペース',
                  value: '${formatWorkoutClock(p.slowPaceSecondsPer500)} /500m',
                  onStep: (d) => _set(p.copyWith(
                      slowPaceSecondsPer500:
                          _clamp(p.slowPaceSecondsPer500 + d * 5, 120, 300))),
                ),
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('漕ぎ出したらワークを始める'),
                subtitle: const Text('スタートの合図を押さなくてよい'),
                value: p.autoStart,
                onChanged: (v) => _set(p.copyWith(autoStart: v)),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: EdgeInsets.fromLTRB(
            dimens.space4,
            dimens.space3,
            dimens.space4,
            dimens.space3,
          ),
          decoration: BoxDecoration(
            color: colors.card,
            border: Border(top: BorderSide(color: colors.textDisabled)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'いまの内容',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '${workoutShortName(p)} ・ ${formatRest(p.restUnit, p.restValue)}',
                key: const ValueKey('workout-setup-summary'),
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              Text(
                [
                  'ワーク合計 ${formatWorkValue(p.workUnit, workTotal)}',
                  if (p.sets > 1)
                    'セット間レスト ${formatWorkoutClock(p.setRestSeconds)}',
                  if (p.autoStart) '漕ぎ出しで開始',
                ].join(' ・ '),
                style: TextStyle(color: colors.textSecondary),
              ),
              SizedBox(height: dimens.space2),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _register,
                      icon: const Icon(Icons.star_outline),
                      label: const Text('登録'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                    ),
                  ),
                  SizedBox(width: dimens.space3),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(_plan),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      child: const Text('このメニューで始める'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// メニュー1つぶんのカード(登録・過去の横並びで使う)。
class WorkoutMenuCard extends StatelessWidget {
  const WorkoutMenuCard({
    super.key,
    required this.top,
    required this.plan,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.dark = false,
  });

  final String top;
  final WorkoutPlan plan;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  /// 航行中のシート(夜の配色)で使うとき。
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = dark ? NavPalette.value : colors.textPrimary;
    final sub = dark ? NavPalette.label : colors.textSecondary;
    final bg = dark ? NavPalette.cell : colors.card;
    final accent = dark ? NavPalette.work : colors.primary;
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? accent : sub.withValues(alpha: 0.3),
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 132),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(top,
                    style: TextStyle(
                        color: sub, fontSize: 12, fontWeight: FontWeight.w800)),
                Text(workoutShortName(plan),
                    style: TextStyle(
                        color: fg, fontSize: 17, fontWeight: FontWeight.w800)),
                Text(formatRest(plan.restUnit, plan.restValue),
                    style: TextStyle(
                        color: sub, fontSize: 12, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 設定のひとかたまり。番号つきの見出しで、上から順に決める流れを示す。
class _SettingCard extends StatelessWidget {
  const _SettingCard({
    required this.step,
    required this.title,
    required this.children,
    this.caption,
  });

  final int step;
  final String title;
  final String? caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    // スイッチの行(ListTile)は最近傍の Material へ描くので、色付きの
    // DecoratedBox ではなく Material を面にする。
    return Padding(
      padding: EdgeInsets.only(top: dimens.space3),
      child: Material(
        color: colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(dimens.radiusLg),
          side: BorderSide(color: colors.textDisabled),
        ),
        child: Padding(
          padding: EdgeInsets.all(dimens.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$step',
                      style: TextStyle(
                        color: colors.onPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  SizedBox(width: dimens.space2),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              if (caption case final caption?)
                Padding(
                  padding: EdgeInsets.only(top: dimens.space1),
                  child: Text(
                    caption,
                    style: TextStyle(color: colors.textSecondary, fontSize: 13),
                  ),
                ),
              SizedBox(height: dimens.space3),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: context.dimens.space2),
        child: Text(
          text,
          style: TextStyle(
            color: context.colors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.children, required this.empty});
  final List<Widget> children;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return Text(
        empty,
        style: TextStyle(color: context.colors.textSecondary),
      );
    }
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => children[i],
      ),
    );
  }
}

class _Seg<T> extends StatelessWidget {
  const _Seg({
    required this.values,
    required this.selected,
    required this.onChanged,
  });

  final Map<T, String> values;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [
            for (final e in values.entries)
              ButtonSegment(value: e.key, label: Text(e.value)),
          ],
          selected: {selected},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.onStep,
  });

  final String label;
  final String value;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: context.dimens.space3),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            IconButton.outlined(
              onPressed: () => onStep(-1),
              icon: const Icon(Icons.remove),
              tooltip: '減らす',
            ),
            SizedBox(
              width: 104,
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            IconButton.outlined(
              onPressed: () => onStep(1),
              icon: const Icon(Icons.add),
              tooltip: '増やす',
            ),
          ],
        ),
      );
}
