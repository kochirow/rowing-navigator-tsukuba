import 'package:flutter/material.dart';

import '../../../hooks/use_coach_watch.dart';
import '../../../theme/app_theme.dart';

/// 機能・状態系を主バナーから退避する、小さな青い詳細入口。
///
/// 文字は件数だけ。重さは枠の色で分ける: 長時間停止(沈の疑い)を含むときは
/// 琥珀、日常的に起こる更新途絶([BoatAnomaly.isRoutine])だけなら青。
/// 同じ見た目だと、沈の疑いと電池切れを件数を開くまで見分けられない。
class ObserverStatusIcon extends StatelessWidget {
  final List<BoatAnomaly> anomalies;
  final int additionalIssueCount;
  final VoidCallback? onTap;

  const ObserverStatusIcon({
    super.key,
    required this.anomalies,
    this.additionalIssueCount = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final boatCount = anomalies.map((item) => item.boatId).toSet().length;
    final count = boatCount + additionalIssueCount;
    if (count == 0) return const SizedBox.shrink();
    final serious = anomalies.any((item) => !item.isRoutine);
    final borderColor =
        serious ? context.colors.caution : const Color(0xFF4FA3FF);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Semantics(
            button: onTap != null,
            label: serious
                ? '艇の状態 $count件。長時間停止の艇があります。タップで詳細を開く'
                : '艇の状態 $count件。タップで詳細を開く',
            child: Container(
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xE61A365D),
                borderRadius: BorderRadius.circular(999),
                border:
                    Border.all(color: borderColor, width: serious ? 2.5 : 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.info_outline,
                      color: Color(0xFFB9DCFF), size: 19),
                  const SizedBox(width: 4),
                  Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
