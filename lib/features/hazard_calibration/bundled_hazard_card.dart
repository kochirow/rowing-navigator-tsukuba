import 'package:flutter/material.dart';

import '../../models/static_obstacle_model.dart';
import '../../theme/app_theme.dart';
import '../../widgets/effect_scope_badge.dart';

/// 同梱の危険区域を押したときのカード。ここから位置合わせを始める。
class BundledHazardCard extends StatelessWidget {
  final StaticObstacle obstacle;
  final String? blockedReason;
  final VoidCallback onStartCalibration;
  final VoidCallback onClose;

  const BundledHazardCard({
    super.key,
    required this.obstacle,
    required this.blockedReason,
    required this.onStartCalibration,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final reason = blockedReason;
    return SafeArea(
      top: false,
      child: Material(
        key: const Key('bundled-hazard-card'),
        elevation: 12,
        color: colors.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(obstacle.name ?? obstacle.kind.displayLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              // 臨時の区域と違い、位置合わせは公開するまで他の人には効かない。
              const Center(
                  child: EffectScopeBadge(EffectScope.teamAfterPublish)),
              const SizedBox(height: 8),
              const Text(
                '同梱の危険区域（アプリに入っている区域）です。形や幅は変えられませんが、'
                '実際の位置とずれているときは、位置合わせで現地に合わせられます。',
              ),
              if (reason != null) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: colors.textSecondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        reason,
                        key: const Key('calibration-blocked-reason'),
                        style: TextStyle(color: colors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: onClose, child: const Text('閉じる')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const Key('start-calibration'),
                    onPressed: reason == null ? onStartCalibration : null,
                    icon: const Icon(Icons.straighten),
                    label: const Text('位置合わせを始める'),
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
