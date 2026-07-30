import 'package:flutter/material.dart';

import '../../../config/boat_config.dart';
import '../../../theme/app_theme.dart';
import '../../../hooks/use_coach_watch.dart';
import '../../../widgets/app_state_views.dart';

/// コーチ(観察者)モードで表示する艇一覧パネル。
/// 各艇の艇種・速度・電池残量・最終更新・異常を一覧できる。
///
/// 強調度は**異常の重さに合わせる**。
/// - 長時間停止(沈の疑い)・水域外 → 行ごと赤系で強調し、岸から一目で気づける
/// - 更新途絶([BoatAnomaly.isRoutine]) → 控えめ。停止中送信10秒 + 画面OFF +
///   通信ジッタで日常的に起こるため、赤枠で出すと一覧が常時赤くなり
///   本当にまずい艇が埋もれる(DESIGN_PRINCIPLES 原則4)
///
/// **どの種類でも情報は減らさない。** ラベル・継続時間・最終更新秒数は
/// 常に出す(原則1・原則6)。変えるのは目立たせ方だけ。
class BoatListPanel extends StatelessWidget {
  final List<BoatStatus> statuses;

  const BoatListPanel({super.key, required this.statuses});

  Widget _row(BuildContext context, BoatStatus status) {
    final colors = context.colors;
    final boat = status.boat;
    final label = boatConfigs.byBoatType(boat.boatType).label;
    final shortId =
        boat.boatId.length > 4 ? boat.boatId.substring(0, 4) : boat.boatId;
    final anomaly = status.anomaly;
    final hasAnomaly = anomaly != null;
    // 日常的に起こる異常(更新途絶)は強調しない。表示は残す。
    final isRoutineAnomaly = anomaly?.isRoutine ?? false;
    final emphasized = hasAnomaly && !isRoutineAnomaly;
    final lowBattery = boat.battery != null && boat.battery! <= 20;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: emphasized
            ? colors.danger.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border:
            emphasized ? Border.all(color: colors.danger, width: 1.5) : null,
      ),
      child: Row(
        children: [
          Icon(
            // 更新途絶は「通信が来ていない」ことであって、艇の異常とは限らない。
            // 警告アイコンではなく中立的な cloud_off で示す。
            emphasized
                ? Icons.warning
                : isRoutineAnomaly
                    ? Icons.cloud_off
                    : Icons.check_circle,
            size: 20,
            color: emphasized
                ? colors.danger
                : isRoutineAnomaly
                    ? colors.textSecondary
                    : colors.ok,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  boat.displayName,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '$label ($shortId)',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (hasAnomaly)
                  Text(
                    // 「いつから」が分からないと、様子見か即対応かを
                    // コーチが判断できない。初検知からの経過を添える。
                    // これは強調度によらず全種類で出す。
                    [
                      anomaly.label,
                      if (anomaly.continuedLabel(DateTime.now()) != null)
                        anomaly.continuedLabel(DateTime.now())!,
                    ].join('  '),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          emphasized ? FontWeight.bold : FontWeight.normal,
                      color: emphasized ? colors.danger : colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            '${boat.speed.toStringAsFixed(1)} m/s',
            style: TextStyle(fontSize: 13, color: colors.textPrimary),
          ),
          const SizedBox(width: 10),
          if (boat.battery != null) ...[
            Icon(
              lowBattery ? Icons.battery_alert : Icons.battery_full,
              size: 16,
              color: lowBattery ? colors.danger : colors.textSecondary,
            ),
            Text(
              '${boat.battery}%',
              style: TextStyle(
                fontSize: 13,
                fontWeight: lowBattery ? FontWeight.bold : FontWeight.normal,
                color: lowBattery ? colors.danger : colors.textPrimary,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text(
            '${status.ageSec.round()}秒前',
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.card.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: statuses.isEmpty
          ? const AppEmptyView(
              icon: Icons.rowing,
              title: '航行中の艇はありません',
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '航行中の艇 ${statuses.length}隻',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                ...statuses.map((status) => _row(context, status)),
              ],
            ),
    );
  }
}
