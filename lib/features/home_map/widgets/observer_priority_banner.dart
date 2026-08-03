import 'package:flutter/material.dart';

import '../../../services/observer_traffic_awareness_evaluator.dart';

/// 監視で即時に読むべき逆走・対向接近だけを、最大2本に圧縮して示す。
///
/// 航行中のSafetyBannerとは別物であり、音声・既存衝突警報を変更しない。
class ObserverPriorityBanner extends StatelessWidget {
  final ObserverTrafficSnapshot snapshot;
  final VoidCallback? onTapReverse;
  final VoidCallback? onTapApproaching;

  const ObserverPriorityBanner({
    super.key,
    required this.snapshot,
    this.onTapReverse,
    this.onTapApproaching,
  });

  @override
  Widget build(BuildContext context) {
    if (snapshot.reverseBoats.isEmpty && snapshot.groups.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (snapshot.reverseBoats.isNotEmpty)
            _PriorityRow(
              color: const Color(0xFFC62828),
              icon: Icons.u_turn_left_rounded,
              label:
                  '逆走：${_names(snapshot.reverseBoats.map((boat) => boat.displayName))}',
              onTap: onTapReverse,
            ),
          if (snapshot.reverseBoats.isNotEmpty && snapshot.groups.isNotEmpty)
            const SizedBox(height: 5),
          if (snapshot.groups.isNotEmpty)
            _PriorityRow(
              color: const Color(0xFFDE6B16),
              icon: Icons.swap_horiz_rounded,
              label: _approachingLabel(snapshot.groups),
              onTap: onTapApproaching,
            ),
        ],
      ),
    );
  }

  static String _names(Iterable<String> names) {
    final list = names.toList(growable: false);
    final visible = list.take(3).join('・');
    return list.length <= 3 ? visible : '$visible・ほか${list.length - 3}艇';
  }

  static String _approachingLabel(List<ObserverAwarenessGroup> groups) {
    final first = groups.first;
    final names = _names(first.displayNames);
    final suffix = groups.length > 1 ? '・ほか${groups.length - 1}組' : '';
    return '接近中：$names$suffix';
  }
}

class _PriorityRow extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _PriorityRow({
    required this.color,
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        button: onTap != null,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 1.5),
                boxShadow: const [
                  BoxShadow(color: Color(0x66000000), blurRadius: 4),
                ],
              ),
              child: Row(
                children: [
                  Icon(icon, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        height: 1.1,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
