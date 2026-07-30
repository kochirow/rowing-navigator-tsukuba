import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/danger_zone_settings.dart';
import '../models/fixed_obstacle_calibration.dart';

/// 固定障害物の校正画面で、地図と操作パネルへ割り当てる領域。
///
/// 端末幅より大きいパネルを作らないため、小さい横画面でも横方向へ
/// はみ出さず、操作部分はパネル内でスクロールできる。
class FixedObstacleCalibrationLayoutSpec {
  final bool isLandscape;
  final double panelWidth;
  final double portraitPanelHeight;

  const FixedObstacleCalibrationLayoutSpec._({
    required this.isLandscape,
    required this.panelWidth,
    required this.portraitPanelHeight,
  });

  factory FixedObstacleCalibrationLayoutSpec.fromConstraints(
    BoxConstraints constraints,
  ) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;
    final isLandscape = width > height;
    final desiredLandscapeWidth = (width * 0.4).clamp(300.0, 420.0).toDouble();
    final desiredPortraitHeight =
        (height * 0.54).clamp(280.0, 390.0).toDouble();
    return FixedObstacleCalibrationLayoutSpec._(
      isLandscape: isLandscape,
      panelWidth: isLandscape ? math.min(width, desiredLandscapeWidth) : width,
      portraitPanelHeight: math.min(height, desiredPortraitHeight),
    );
  }

  EdgeInsets get mapPadding => isLandscape
      ? EdgeInsets.only(right: panelWidth)
      : EdgeInsets.only(bottom: portraitPanelHeight);
}

/// 保存中の画面離脱を防ぎ、書込完了前に呼出元が再読込する競合を避ける。
class FixedObstacleCalibrationSaveGuard extends StatelessWidget {
  final bool saving;
  final VoidCallback onBlockedPop;
  final Widget child;

  const FixedObstacleCalibrationSaveGuard({
    super.key,
    required this.saving,
    required this.onBlockedPop,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && saving) onBlockedPop();
      },
      child: child,
    );
  }
}

/// 地図タップによる選択変更にも表示を同期する、校正対象の選択欄。
class FixedObstacleCalibrationTargetDropdown extends StatelessWidget {
  final List<FixedObstacleCalibrationTarget> targets;
  final String? selectedId;
  final bool saving;
  final ValueChanged<String?> onChanged;

  const FixedObstacleCalibrationTargetDropdown({
    super.key,
    required this.targets,
    required this.selectedId,
    required this.saving,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: ValueKey('calibration-target-$selectedId'),
      initialValue: selectedId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '調整する固定障害物',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final target in targets)
          DropdownMenuItem(
            value: target.sourceId,
            child: Text(
              '${target.kind.displayLabel}｜${target.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: saving ? null : onChanged,
    );
  }
}

enum FixedObstacleCalibrationPublishStatus {
  idle,
  publishing,
  success,
  conflict,
  failure,
}

/// 端末内の下書きと、チームへ確定公開する操作を視覚的に分離する。
class FixedObstacleCalibrationPublishPanel extends StatelessWidget {
  final FixedObstacleCalibrationPublishStatus status;
  final String? statusMessage;
  final bool enabled;
  final bool showPublishButton;
  final VoidCallback? onPublish;

  const FixedObstacleCalibrationPublishPanel({
    super.key,
    required this.status,
    required this.statusMessage,
    required this.enabled,
    this.showPublishButton = true,
    required this.onPublish,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = switch (status) {
      FixedObstacleCalibrationPublishStatus.success => scheme.primary,
      FixedObstacleCalibrationPublishStatus.conflict => scheme.tertiary,
      FixedObstacleCalibrationPublishStatus.failure => scheme.error,
      _ => scheme.onSurfaceVariant,
    };
    final statusIcon = switch (status) {
      FixedObstacleCalibrationPublishStatus.publishing => const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      FixedObstacleCalibrationPublishStatus.success =>
        const Icon(Icons.cloud_done_outlined, size: 20),
      FixedObstacleCalibrationPublishStatus.conflict =>
        const Icon(Icons.sync_problem_outlined, size: 20),
      FixedObstacleCalibrationPublishStatus.failure =>
        const Icon(Icons.cloud_off_outlined, size: 20),
      FixedObstacleCalibrationPublishStatus.idle =>
        const Icon(Icons.info_outline, size: 20),
    };
    final message = statusMessage ??
        (status == FixedObstacleCalibrationPublishStatus.publishing
            ? 'チームへ公開しています…'
            : 'スライダー操作はこの端末だけに保存されます。'
                '確認後に公開すると、同じチームの端末へ反映されます。');

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconTheme(
                  data: IconThemeData(color: statusColor),
                  child: statusIcon,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message,
                    key: const ValueKey('calibration-publish-status'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: statusColor,
                        ),
                  ),
                ),
              ],
            ),
            if (showPublishButton) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const ValueKey('publish-calibration-button'),
                onPressed: enabled &&
                        status !=
                            FixedObstacleCalibrationPublishStatus.publishing
                    ? onPublish
                    : null,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(
                  status == FixedObstacleCalibrationPublishStatus.publishing
                      ? '公開中…'
                      : 'チームに公開',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// チーム公開の直前に、位置と根拠にした航行記録を一画面で確認する。
class FixedObstacleCalibrationPublishItem {
  final FixedObstacleCalibrationTarget target;
  final FixedObstacleCalibration calibration;
  final LatLng beforeCenter;
  final LatLng afterCenter;

  const FixedObstacleCalibrationPublishItem({
    required this.target,
    required this.calibration,
    required this.beforeCenter,
    required this.afterCenter,
  });
}

class FixedObstacleCalibrationPublishConfirmation extends StatelessWidget {
  final List<FixedObstacleCalibrationPublishItem> items;
  final List<String> referenceSessionLabels;

  const FixedObstacleCalibrationPublishConfirmation({
    super.key,
    required this.items,
    required this.referenceSessionLabels,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('チームへの公開内容を確認'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items) ...[
                Text(
                  '${item.target.kind.displayLabel}｜${item.target.name}',
                  style: textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                _PublishDetailRow(
                  label: '全体補正',
                  value: '北 ${_signedMeters(item.calibration.northMeters)}　'
                      '東 ${_signedMeters(item.calibration.eastMeters)}',
                ),
                if (item.calibration.vertexOffsets.isNotEmpty)
                  _PublishDetailRow(
                    label: '頂点補正',
                    value: '${item.calibration.vertexOffsets.length}点を個別に調整',
                  ),
                _PublishDetailRow(
                  label: '補正前',
                  value: _coordinateLabel(item.beforeCenter),
                ),
                _PublishDetailRow(
                  label: '補正後',
                  value: _coordinateLabel(item.afterCenter),
                ),
                const Divider(height: 20),
              ],
              const SizedBox(height: 12),
              Text('参照した航行記録', style: textTheme.labelLarge),
              const SizedBox(height: 4),
              if (referenceSessionLabels.isEmpty)
                const Text(
                  '選択なし',
                  key: ValueKey('publish-reference-sessions-empty'),
                )
              else
                for (final label in referenceSessionLabels)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('・$label'),
                  ),
              const SizedBox(height: 12),
              Text(
                '公開後は同じチームの端末で利用されます。'
                '現地と航空写真を照合したことを確認してください。',
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('戻って確認'),
        ),
        FilledButton(
          key: const ValueKey('confirm-publish-calibration-button'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('この内容で公開'),
        ),
      ],
    );
  }

  static String _signedMeters(double value) =>
      '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}m';

  static String _coordinateLabel(LatLng coordinate) =>
      '${coordinate.latitude.toStringAsFixed(6)}, '
      '${coordinate.longitude.toStringAsFixed(6)}';
}

class _PublishDetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _PublishDetailRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// 危険範囲だけを共有し、端末固有の警告開始秒数を混同しない確認画面。
class DangerZoneSettingsPublishConfirmation extends StatelessWidget {
  final DangerZoneSettings settings;

  const DangerZoneSettingsPublishConfirmation({
    super.key,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('チームへの危険範囲を確認'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final kind in DangerZoneKind.values)
                _PublishDetailRow(
                  label: _dangerZoneKindLabel(kind),
                  value: _dangerZoneOffsetsLabel(kind, settings[kind]),
                ),
              const SizedBox(height: 8),
              Text(
                '警告開始時間は公開されず、この端末の設定を維持します。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('戻って確認'),
        ),
        FilledButton(
          key: const ValueKey('confirm-publish-danger-zones-button'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('この内容で公開'),
        ),
      ],
    );
  }

  static String _dangerZoneKindLabel(DangerZoneKind kind) => switch (kind) {
        DangerZoneKind.shore => '岸',
        DangerZoneKind.bridge => '橋',
        DangerZoneKind.island => '中州',
        DangerZoneKind.driftwood => '固定流木',
        DangerZoneKind.testZone => 'テスト',
      };

  static String _dangerZoneOffsetsLabel(
    DangerZoneKind kind,
    DangerZoneOffsets offsets,
  ) {
    if (kind == DangerZoneKind.driftwood) {
      return '周囲 ${offsets.waterSideMeters.toStringAsFixed(1)}m';
    }
    return '水上/内側 ${offsets.waterSideMeters.toStringAsFixed(1)}m　'
        '陸/外側 ${offsets.landSideMeters.toStringAsFixed(1)}m';
  }
}
