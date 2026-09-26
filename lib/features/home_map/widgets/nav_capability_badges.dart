import 'package:flutter/material.dart';

import '../../../models/navigation_warning.dart';
import '../../../services/gps_health_monitor.dart';
import '../../../theme/nav_palette.dart';

/// 航行中の能力低下を、画面の上端(計器カードの上)に絵+短い語で出す。
///
/// 大きな警告バナーを外したので、GPS の途絶・受信不可などはここで必ず見える
/// ようにする(機能を止めない・データ欠損を安全の根拠にしない。原則1・6)。
/// 漕ぎながら読ませないよう、文章にせず「GPS ±14m」「受信」のような短い語に
/// する。読み上げには従来の言い方(「他艇受信: 利用不可」など)を残す。
class NavCapabilityBadges extends StatelessWidget {
  const NavCapabilityBadges({
    super.key,
    required this.warnings,
    required this.gpsQuality,
    this.gpsAccuracyMeters,
  });

  final List<NavigationWarning> warnings;
  final GpsHealthQuality gpsQuality;
  final double? gpsAccuracyMeters;

  /// system fault の種類 → (短い語, 絵, 読み上げ)。
  static const _faults = {
    'gps_unavailable': ('GPS', Icons.gps_off, 'GPS: 利用不可'),
    'position_sharing_unavailable': ('共有', Icons.cloud_off, '位置共有: 利用不可'),
    'other_boat_receive_unavailable': ('受信', Icons.wifi_off, '他艇受信: 利用不可'),
    'other_boat_track_lost': ('受信', Icons.wifi_off, '他艇受信: 途絶'),
    'static_profile_unavailable': ('危険区域', Icons.layers_clear, '危険区域: 未検証'),
    'audio_unavailable': ('警告音', Icons.volume_off, '警告音: 利用不可'),
    'pipeline_unresponsive': ('判定停止', Icons.pause_circle, '安全判定: 停止'),
  };

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[];
    final seen = <String>{};
    for (final w in warnings) {
      final f = _faults[w.category];
      if (f == null || !seen.add(f.$1)) continue;
      badges.add(_Badge(label: f.$1, icon: f.$2, semantics: f.$3));
    }
    // GPS が途絶していないが弱いとき: 推定誤差を数字で。
    if (!seen.contains('GPS') && gpsQuality != GpsHealthQuality.good) {
      final acc = gpsAccuracyMeters;
      badges.insert(
        0,
        _Badge(
          label: acc == null || !acc.isFinite ? 'GPS' : 'GPS ±${acc.round()}m',
          icon: Icons.gps_not_fixed,
          semantics: 'GPS: 精度低下',
        ),
      );
    }
    if (badges.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 4),
      child: Wrap(spacing: 6, runSpacing: 4, children: badges),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.icon,
    required this.semantics,
  });

  final String label;
  final IconData icon;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Container(
        height: 30,
        padding: const EdgeInsets.only(left: 7, right: 10),
        decoration: BoxDecoration(
          color: NavPalette.surface,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: NavPalette.caution, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: NavPalette.caution),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: NavPalette.caution,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
