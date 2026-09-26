import 'package:flutter/material.dart';

import '../../../models/workout_plan.dart';
import '../../../screens/workout_setup_screen.dart';
import '../../../services/workout_menu_store.dart';
import '../../../theme/nav_palette.dart';

/// 航行中のワークアウトのボタンから開く、呼び出し用のシート。
///
/// 練習前に作って登録したメニュー・過去のメニューを選んで、すぐ始める。
/// 細かい設定は「新しく作る・細かく変える」(設定画面)。実行中は「終える」。
Future<void> showWorkoutQuickSheet(
  BuildContext context, {
  required WorkoutPlan? running,
  required void Function(WorkoutPlan) onStart,
  required void Function() onStop,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NavPalette.surface,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.62,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => _WorkoutQuickSheet(
      running: running,
      onStart: (plan) {
        Navigator.of(sheetContext).pop();
        onStart(plan);
      },
      onStop: () {
        Navigator.of(sheetContext).pop();
        onStop();
      },
    ),
  );
}

class _WorkoutQuickSheet extends StatefulWidget {
  const _WorkoutQuickSheet({
    required this.running,
    required this.onStart,
    required this.onStop,
  });

  final WorkoutPlan? running;
  final void Function(WorkoutPlan) onStart;
  final void Function() onStop;

  @override
  State<_WorkoutQuickSheet> createState() => _WorkoutQuickSheetState();
}

class _WorkoutQuickSheetState extends State<_WorkoutQuickSheet> {
  final _store = WorkoutMenuStore();
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

  @override
  Widget build(BuildContext context) {
    final running = widget.running;
    return SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: 12, bottom: 16),
        children: [
          if (running != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('実行中', style: _eyebrow),
                        Text(
                          workoutShortName(running),
                          style: const TextStyle(
                            color: NavPalette.value,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: widget.onStop,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF6B6B),
                      minimumSize: const Size(88, 44),
                    ),
                    child: const Text('終える'),
                  ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Text('登録したメニュー', style: _eyebrow),
          ),
          _MenuRow(
            empty: '練習の前に「新しく作る」で作って登録しておくと、ここから呼び出せます。',
            items: [
              for (final w in _favorites) (top: '★ ${w.name}', plan: w.plan),
            ],
            onTap: widget.onStart,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text('過去のメニュー', style: _eyebrow),
          ),
          _MenuRow(
            empty: 'まだありません。',
            items: [
              for (final w in _history)
                (top: '${w.usedAt.month}/${w.usedAt.day}', plan: w.plan),
            ],
            onTap: widget.onStart,
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text(
              '新しく作る・細かく変える',
              style: TextStyle(
                color: NavPalette.value,
                fontWeight: FontWeight.w800,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, color: NavPalette.label),
            onTap: () async {
              final plan = await Navigator.of(context).push<WorkoutPlan>(
                MaterialPageRoute(
                  builder: (_) => WorkoutSetupScreen(initial: running),
                ),
              );
              if (plan != null) widget.onStart(plan);
            },
          ),
        ],
      ),
    );
  }
}

const _eyebrow = TextStyle(
  color: NavPalette.label,
  fontSize: 12,
  fontWeight: FontWeight.w800,
  letterSpacing: 1,
);

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.items,
    required this.onTap,
    required this.empty,
  });

  final List<({String top, WorkoutPlan plan})> items;
  final void Function(WorkoutPlan) onTap;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(empty, style: const TextStyle(color: NavPalette.label)),
      );
    }
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final item = items[i];
          return WorkoutMenuCard(
            top: item.top,
            plan: item.plan,
            onTap: () => onTap(item.plan),
            dark: true,
          );
        },
      ),
    );
  }
}
