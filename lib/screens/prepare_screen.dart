import 'package:flutter/material.dart';

import '../features/home_map/home_shell_bridge.dart';
import '../theme/app_theme.dart';
import 'danger_zone_settings_screen.dart';
import 'device_status_screen.dart';
import 'fixed_obstacle_calibration_screen.dart';
import 'team_screen.dart';
import 'usage_guide_screen.dart';

/// 出艇前の「準備」タブ。
///
/// 陸上で両手が空いていて、時間があるときにだけ行う操作を集めた。
/// 航行中・監視中のメニューには出さない(艇の上では触れないか、
/// チーム全体へ影響する操作のため)。
class PrepareScreen extends StatelessWidget {
  final HomeShellBridge bridge;

  const PrepareScreen({super.key, required this.bridge});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('準備'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          dimens.space4,
          dimens.space4,
          dimens.space4,
          dimens.space6,
        ),
        children: [
          Text(
            '出艇前に確かめること',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
              color: colors.textSecondary,
            ),
          ),
          SizedBox(height: dimens.space3),
          _PrepareTile(
            icon: Icons.groups_outlined,
            title: 'チーム',
            description: '招待コードの確認・共有',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TeamScreen()),
            ),
          ),
          _PrepareTile(
            icon: Icons.shield_outlined,
            title: '警告の設定',
            description: 'いつ・どこまで近づいたら・何に対して鳴らすか',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const DangerZoneSettingsScreen(),
                ),
              );
              // 設定を変えたら、地図側の危険区域と開発者用の表示設定を
              // 読み直す。読み直しは地図画面が持っている(状態の持ち主を
              // 変えないため、シェル経由で呼び戻す)。
              await bridge.reloadObstacles?.call();
              await bridge.reloadDeveloperOverlay?.call();
            },
          ),
          _PrepareTile(
            icon: Icons.straighten,
            title: '既設危険区域を位置合わせ',
            // 「危険区域を追加」とは別の操作である。追加は見つけた流木を
            // その場で報告する行為で、こちらは既設データを0.5m単位で
            // 校正してチームへ公開する行為。成功すればチーム全員の
            // 警告位置が動くので、航行中・監視中のメニューには置かない。
            description: '橋・岸・中州を0.5m単位で校正し、チームへ公開',
            emphasis: true,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const FixedObstacleCalibrationScreen(),
                ),
              );
              await bridge.reloadObstacles?.call();
            },
          ),
          _PrepareTile(
            icon: Icons.monitor_heart_outlined,
            title: '端末とデータ',
            description: 'GPS精度・安全機能の状態・プライバシー',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    bridge.buildDeviceStatusScreen?.call() ??
                    const DeviceStatusScreen(),
              ),
            ),
          ),
          _PrepareTile(
            icon: Icons.help_outline,
            title: '使い方',
            description: '警告の3段階・地図の色・警告音の試聴',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const UsageGuideScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrepareTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  /// チーム全体へ影響する操作を、色で他と区別する。
  final bool emphasis;

  const _PrepareTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.emphasis = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final accent = emphasis ? colors.warning : colors.primary;

    return Padding(
      padding: EdgeInsets.only(bottom: dimens.space3),
      child: Material(
        color: colors.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: dimens.borderMd,
          side: BorderSide(color: colors.canvas),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(dimens.space4),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: dimens.borderSm,
                  ),
                  child: Icon(icon, size: 24, color: accent),
                ),
                SizedBox(width: dimens.space4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: dimens.space2),
                Icon(Icons.chevron_right, color: colors.textDisabled),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
