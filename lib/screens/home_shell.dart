import 'package:flutter/material.dart';

import '../features/home_map/home_shell_bridge.dart';
import '../theme/app_theme.dart';
import '../types/home_phase.dart';
import '../utils/tactile_feedback.dart';
import 'home_map_screen.dart';
import 'prepare_screen.dart';
import 'record_list_screen.dart';

/// 出艇前だけタブを持つ、アプリの外枠。
///
/// **なぜタブが出艇前にしかないのか。**
/// このアプリの操作は機能の種類ではなく時間と姿勢で分かれる(`HomePhase`)。
/// 出艇前は陸上で両手が空いていて、準備と記録の閲覧をする。航行中と監視中は
/// 地図が主役で、タブは水面を隠すだけになる。だから出艇したらタブごと畳み、
/// 地図を全画面へ戻す。
///
/// **なぜ地図画面を作り直さないのか。**
/// 位置共有・警告・練習一括ログ・Wakelock はすべて `HomeMapScreen` の
/// `useNavigator` が持っている。タブを切り替えるたびに作り直すと、その
/// すべてが止まって作り直される。[IndexedStack] は選ばれていない子も
/// 同じ制約でレイアウトしたまま保持するので、地図画面は一度も破棄されない。
/// 地図の platform view も生きたまま残る。
class HomeShell extends StatefulWidget {
  /// 地図画面の組み立て。テストから差し替えるためだけの穴で、
  /// 既定は本物の [HomeMapScreen]。
  final Widget Function(HomeShellBridge bridge)? mapBuilder;

  const HomeShell({super.key, this.mapBuilder});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final HomeShellBridge _bridge = HomeShellBridge();

  int _tab = 0;

  /// まだ一度も開いていないタブは組み立てない。起動時に練習記録を
  /// 読み込みに行くのを避ける。
  final Set<int> _visited = {0};

  /// 記録・準備タブは開くたびに作り直す。航行を終えて戻ってきたとき、
  /// 前回の一覧が残っていると新しい記録が無いように見える。
  /// タブごとに数えるのは、片方を開いたときにもう片方まで読み直させない
  /// ため(地図タブは対象外。作り直してはいけない)。
  final Map<int, int> _epochs = {1: 0, 2: 0};

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }

  void _select(int index) {
    TactileFeedback.selection();
    setState(() {
      _tab = index;
      _visited.add(index);
      if (_epochs.containsKey(index)) _epochs[index] = _epochs[index]! + 1;
    });
  }

  Widget _rebuiltOnEntry(int index, Widget Function() build) =>
      _visited.contains(index)
          ? KeyedSubtree(
              key: ValueKey<String>('tab-$index-${_epochs[index]}'),
              child: build(),
            )
          : const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HomePhase>(
      valueListenable: _bridge.phase,
      builder: (context, phase, _) {
        // 出艇したらタブを畳む。航行・監視の開始は地図タブからしか
        // できないので、ここで _tab を書き換える必要はない
        // (戻ってきたときに元のタブを選び直させない)。
        final showTabs = phase.showsTabs;
        return Scaffold(
          body: IndexedStack(
            index: showTabs ? _tab : 0,
            children: [
              widget.mapBuilder?.call(_bridge) ??
                  HomeMapScreen(shellBridge: _bridge),
              _rebuiltOnEntry(1, () => const RecordListScreen(embedded: true)),
              _rebuiltOnEntry(2, () => PrepareScreen(bridge: _bridge)),
            ],
          ),
          bottomNavigationBar: showTabs
              ? _HomeTabBar(current: _tab, onSelect: _select)
              : null,
        );
      },
    );
  }
}

class _HomeTabBar extends StatelessWidget {
  final int current;
  final ValueChanged<int> onSelect;

  const _HomeTabBar({required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return NavigationBarTheme(
      data: NavigationBarThemeData(
        backgroundColor: colors.card,
        indicatorColor: colors.primary.withValues(alpha: 0.14),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.bold
                : FontWeight.normal,
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.textSecondary,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.textSecondary,
          ),
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.canvas)),
        ),
        child: NavigationBar(
          height: 68,
          selectedIndex: current,
          onDestinationSelected: onSelect,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.rowing_outlined),
              selectedIcon: Icon(Icons.rowing),
              label: '出艇',
            ),
            NavigationDestination(
              icon: Icon(Icons.timeline_outlined),
              selectedIcon: Icon(Icons.timeline),
              label: '記録',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: '準備',
            ),
          ],
        ),
      ),
    );
  }
}
