import 'package:flutter/material.dart';

import '../../widgets/effect_scope_badge.dart';
import '../../widgets/fixed_obstacle_calibration_controls.dart';
import 'fixed_obstacle_calibration_controller.dart';

// # 同梱の危険区域の位置合わせ(画面の部品)
//
// 「危険区域の追加・編集」画面で位置合わせを始めたときに、地図の上に出す部品。
// 中身は以前の専用画面と同じ(対象の選択・比較する航跡・座標点の矢印・チームに公開)。

/// 地図の上端に出す、注意と色の凡例。
class FixedObstacleCalibrationLegendCard extends StatelessWidget {
  const FixedObstacleCalibrationLegendCard({super.key});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.black.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(12),
        // 色の説明は文章でなく、見本+1語の凡例にする。
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '航行中は操作しないでください。GPSの1点で決めず、往復の航跡と見比べてください。',
                style:
                    TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _LegendItem.line(Colors.white, '補正前'),
                  _LegendItem.line(Colors.lightBlueAccent, '調整後'),
                  _LegendItem.dot(Colors.lightBlue, '座標点'),
                  _LegendItem.dot(Colors.green, '選択中'),
                  _LegendItem.line(Colors.lightGreenAccent, '航跡'),
                  _LegendItem.line(Color(0xFFB0BEC5), '生GPS', dashed: true),
                  _LegendItem.dot(Colors.red, '警告開始'),
                  _LegendItem.dot(Colors.purpleAccent, '位置ずれ'),
                ],
              ),
            ],
          ),
        ),
      );
}

/// すべての位置合わせを解除する前の確認。解除したら true。
Future<bool> confirmResetAllCalibrations(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('すべての位置合わせを解除しますか？'),
        content: const Text(
          'この端末で行った同梱の危険区域の位置合わせをすべて削除し、'
          '同梱された基準位置へ戻します。区域の幅は変わりません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('すべて解除'),
          ),
        ],
      ),
    ) ??
    false;

/// 位置合わせの操作パネル(縦画面は下、横画面は右)。
class FixedObstacleCalibrationPanel extends StatelessWidget {
  final FixedObstacleCalibrationController controller;

  /// 「位置合わせを終える」。保存中は押せない。
  final VoidCallback onFinish;

  const FixedObstacleCalibrationPanel({
    super.key,
    required this.controller,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('同梱の危険区域の位置合わせ',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  // 臨時の区域と違い、公開するまで他の人には効かない。
                  EffectScopeBadge(EffectScope.teamAfterPublish),
                ],
              ),
            ),
            FilledButton.tonal(
              key: const Key('calibration-finish'),
              onPressed: c.busy ? null : onFinish,
              child: const Text('終える'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FixedObstacleCalibrationTargetDropdown(
          targets: c.targets,
          selectedId: c.selectedId,
          saving: c.busy,
          onChanged: c.select,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: c.recentSessions.isEmpty
              ? null
              : () => _chooseOverlaySessions(context),
          icon: const Icon(Icons.layers_outlined),
          label: Text(c.overlaySelectionLabel),
        ),
        if (c.overlaySessions.isNotEmpty) ...[
          const SizedBox(height: 8),
          _OverlayLegend(controller: c),
        ],
        const SizedBox(height: 8),
        _VertexControls(controller: c),
        const SizedBox(height: 8),
        FixedObstacleCalibrationPublishPanel(
          status: c.publishStatus,
          statusMessage: c.hasTeamMembership
              ? c.publishMessage
              : 'チームに公開済みの版: ${c.sharedRevision}。'
                  'いまの地図は、この端末だけの変更です（チームに公開するまで、ほかの人の端末には反映されません）。'
                  'チームに参加すると公開できます。',
          enabled: !c.busy,
          showPublishButton: c.hasTeamMembership,
          onPublish: () => _publish(context),
        ),
        TextButton.icon(
          onPressed: c.busy || c.calibrations.isEmpty
              ? null
              : () async {
                  if (await confirmResetAllCalibrations(context)) {
                    await c.resetAll();
                  }
                },
          icon: const Icon(Icons.restore_page_outlined),
          label: const Text('すべての位置合わせを解除'),
        ),
      ],
    );
  }

  Future<void> _publish(BuildContext context) async {
    final c = controller;
    if (!c.hasTeamMembership || c.busy) return;
    final items = c.publishItems();
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => FixedObstacleCalibrationPublishConfirmation(
            items: items,
            referenceSessionLabels: c.referenceSessionLabels,
          ),
        ) ??
        false;
    if (!confirmed) return;
    await c.publishToTeam();
  }

  Future<void> _chooseOverlaySessions(BuildContext context) async {
    final c = controller;
    if (c.recentSessions.isEmpty) return;
    final selected = Set<String>.from(c.overlaySessionIds);
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('比較する航行記録'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 360),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final session in c.recentSessions)
                  CheckboxListTile(
                    value: selected.contains(session.id),
                    title: Text(c.sessionLabel(session)),
                    subtitle: Text(
                      '${session.points.length}点'
                      '・${c.trackOverlayService.directionLabel(session)}'
                      '${session.alertEvents.isEmpty ? '' : '・警告記録あり'}',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (checked) => setDialogState(() {
                      if (checked ?? false) {
                        selected.add(session.id);
                      } else {
                        selected.remove(session.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, <String>{}),
              child: const Text('すべて非表示'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: const Text('適用'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    c.setOverlaySessions(result);
  }
}

class _VertexControls extends StatelessWidget {
  final FixedObstacleCalibrationController controller;
  const _VertexControls({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    const step = FixedObstacleCalibrationController.stepMeters;
    final pointIndex = c.selectedPointIndex;
    if (pointIndex == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '地図上の青い座標点をタップして選択してください。選んだ点だけが緑色になり、矢印で動かせます。',
          ),
        ),
      );
    }
    final offset = c.draft.vertexOffsetFor(pointIndex);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '調整中の座標点 #${pointIndex + 1}',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '北 ${_signedMeters(offset.northMeters)}　'
                  '東 ${_signedMeters(offset.eastMeters)}'
                  '${c.saving ? '　保存中…' : '　端末内に保存'}',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filledTonal(
              tooltip: '西へ0.5m',
              onPressed: c.busy ? null : () => c.nudge(eastDelta: -step),
              icon: const Icon(Icons.west),
            ),
            const SizedBox(width: 8),
            Column(
              children: [
                IconButton.filledTonal(
                  tooltip: '北へ0.5m',
                  onPressed: c.busy ? null : () => c.nudge(northDelta: step),
                  icon: const Icon(Icons.north),
                ),
                IconButton.filledTonal(
                  tooltip: '南へ0.5m',
                  onPressed: c.busy ? null : () => c.nudge(northDelta: -step),
                  icon: const Icon(Icons.south),
                ),
              ],
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: '東へ0.5m',
              onPressed: c.busy ? null : () => c.nudge(eastDelta: step),
              icon: const Icon(Icons.east),
            ),
          ],
        ),
        TextButton.icon(
          onPressed: c.busy || offset.isZero ? null : c.resetSelectedPoint,
          icon: const Icon(Icons.restore),
          label: const Text('この座標点を基準位置へ戻す'),
        ),
      ],
    );
  }

  String _signedMeters(double value) =>
      '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}m';
}

class _OverlayLegend extends StatelessWidget {
  final FixedObstacleCalibrationController controller;
  const _OverlayLegend({required this.controller});

  @override
  Widget build(BuildContext context) {
    final sessions = controller.overlaySessions;
    if (sessions.isEmpty) return const SizedBox.shrink();
    final textStyle = Theme.of(context).textTheme.bodySmall;
    const colors = FixedObstacleCalibrationController.trackColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in sessions.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 5,
                      decoration: BoxDecoration(
                        color: colors[entry.$1 % colors.length],
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${controller.sessionLabel(entry.$2)}・'
                        '${controller.trackOverlayService.directionLabel(entry.$2)}',
                        style: textStyle,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 3),
            Text(
              '小さい黒縁が開始、大きい白縁が終了。薄い線はGPS精度12〜25m、'
              '25m超は線を接続しません。',
              style: textStyle,
            ),
          ],
        ),
      ),
    );
  }
}

/// 地図の凡例1項目(線または点の見本+1語)。
class _LegendItem extends StatelessWidget {
  const _LegendItem.line(this.color, this.label, {this.dashed = false})
      : isDot = false;
  const _LegendItem.dot(this.color, this.label)
      : isDot = true,
        dashed = false;

  final Color color;
  final String label;
  final bool isDot;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final swatch = isDot
        ? Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          )
        : SizedBox(
            width: 18,
            height: 3,
            child: dashed
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (var i = 0; i < 3; i++)
                        Container(width: 4, height: 3, color: color),
                    ],
                  )
                : ColoredBox(color: color),
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        swatch,
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ],
    );
  }
}
