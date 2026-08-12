import 'package:flutter/material.dart';

import '../../../models/shared_stroke_trace.dart';
import '../../../services/rowing_motion_fusion.dart';
import '../../../theme/app_theme.dart';

/// 1ストロークの指標を、ラベルと数値の対で並べる。
///
/// グラフが「形」を見せ、ここが「量」を見せる。**良い・悪いは断定しない**
/// (設計メモ 2026-08-03 の安全設計8)。色分けもしない。値が読めれば足りる。
///
/// ラベルは競技の用語に揃える。キャッチ(入水)・ドライブ(押している間)・
/// フィニッシュ(抜水)・リカバリー(戻し)は、漕手が普段そのまま使う言葉で、
/// 別の言い方にすると指標がどの局面の話か分からなくなる。
class StrokeMetricsChips extends StatelessWidget {
  final double distancePerStrokeMeters;
  final double catchSpeedLossMetersPerSecond;
  final double lateDriveSpeedGainMetersPerSecond;
  final double recoverySpeedRetention;
  final bool onDarkSurface;
  final bool compact;

  const StrokeMetricsChips({
    super.key,
    required this.distancePerStrokeMeters,
    required this.catchSpeedLossMetersPerSecond,
    required this.lateDriveSpeedGainMetersPerSecond,
    required this.recoverySpeedRetention,
    this.onDarkSurface = true,
    this.compact = false,
  });

  StrokeMetricsChips.fromMetrics(
    RowingMotionMetrics metrics, {
    super.key,
    this.onDarkSurface = true,
    this.compact = false,
  })  : distancePerStrokeMeters = metrics.distancePerStrokeMeters,
        catchSpeedLossMetersPerSecond = metrics.catchSpeedLossMetersPerSecond,
        lateDriveSpeedGainMetersPerSecond =
            metrics.lateDriveSpeedGainMetersPerSecond,
        recoverySpeedRetention = metrics.recoverySpeedRetention;

  StrokeMetricsChips.fromSharedTrace(
    SharedStrokeTrace trace, {
    super.key,
    this.onDarkSurface = false,
    this.compact = false,
  })  : distancePerStrokeMeters = trace.distancePerStrokeMeters,
        catchSpeedLossMetersPerSecond = trace.catchSpeedLossMetersPerSecond,
        lateDriveSpeedGainMetersPerSecond =
            trace.lateDriveSpeedGainMetersPerSecond,
        recoverySpeedRetention = trace.recoverySpeedRetention;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final base = onDarkSurface ? colors.onDark : colors.textPrimary;
    // ドライブ後半は加速と失速の両方が起こる。符号を隠さずラベルを切り替える。
    final lateDrivePositive = lateDriveSpeedGainMetersPerSecond >= 0;
    final items = <_ChipData>[
      _ChipData('1ストローク', '${distancePerStrokeMeters.toStringAsFixed(1)}m'),
      _ChipData(
        'キャッチ減速',
        '−${catchSpeedLossMetersPerSecond.toStringAsFixed(2)}',
      ),
      _ChipData(
        lateDrivePositive ? 'ドライブ後半加速' : 'ドライブ後半失速',
        '${lateDrivePositive ? '+' : '−'}'
        '${lateDriveSpeedGainMetersPerSecond.abs().toStringAsFixed(2)}',
      ),
      _ChipData('リカバリー保持', '${(recoverySpeedRetention * 100).round()}%'),
    ];

    return Wrap(
      key: const ValueKey('stroke-motion-metrics'),
      spacing: compact ? 6 : 10,
      runSpacing: 4,
      children: items
          .map((item) => _Chip(
                data: item,
                base: base,
                compact: compact,
              ))
          .toList(growable: false),
    );
  }
}

class _ChipData {
  final String label;
  final String value;

  const _ChipData(this.label, this.value);
}

class _Chip extends StatelessWidget {
  final _ChipData data;
  final Color base;
  final bool compact;

  const _Chip({required this.data, required this.base, required this.compact});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          data.label,
          style: TextStyle(
            color: base.withValues(alpha: 0.62),
            fontSize: compact ? 9 : 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 3),
        Text(
          data.value,
          style: TextStyle(
            color: base,
            fontSize: compact ? 12 : 14,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
