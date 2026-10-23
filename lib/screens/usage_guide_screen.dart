import 'package:flutter/material.dart';

import '../config/risk_evaluator_config.dart' as risk_config;
import '../theme/app_theme.dart';
import 'first_run_guide_screen.dart';
import 'usage_guide/guide_widgets.dart';
import 'usage_guide/map_and_alerts_guide_page.dart';
import 'usage_guide/navigation_guide_page.dart';
import 'usage_guide/team_guide_page.dart';
import 'usage_guide/troubleshooting_guide_page.dart';
import 'usage_guide/watch_guide_page.dart';

/// 使い方の目次。ここは表示の意味と操作の順序を説明するだけで、設定は何も変えない。
///
/// 以前は1枚の長いページに、初心者向けの警告の説明と管理者向けの橋脚の登録が
/// 並んでいた。漕ぐ人と陸で見る人ではやることが違うので、章の名前を画面の
/// ボタン(「航行スタート」「監視スタート」)と同じ語にして分けた。
///
/// 警告の段階の秒数は、呼び出し側から「いま効いている値」を受け取り、
/// 下位ページへそのまま渡す。本警告・予告の時間は設定画面とチーム共有で変わる。
class UsageGuideScreen extends StatelessWidget {
  const UsageGuideScreen({
    super.key,
    this.primaryWarningLeadSeconds = risk_config.primaryWarningLeadSeconds,
    this.advanceWarningLeadSeconds = risk_config.advanceWarningLeadSeconds,
  });

  /// 確度の低い当たり予測で警告音が鳴り始める残り時間(秒)。
  final double primaryWarningLeadSeconds;

  /// 確実な当たり予測で警告音が鳴り始める残り時間(秒)。予測地平と同じ値。
  final double advanceWarningLeadSeconds;

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    final entries = <(IconData, String, String, Widget)>[
      (
        Icons.rowing,
        NavigationGuidePage.title,
        '艇に乗る人。出艇前の準備・航行中の画面・練習記録',
        const NavigationGuidePage(),
      ),
      (
        Icons.visibility_outlined,
        WatchGuidePage.title,
        '陸から全艇を見る人。航跡・異常の知らせ・練習一括ログ',
        const WatchGuidePage(),
      ),
      (
        Icons.volume_up_outlined,
        MapAndAlertsGuidePage.title,
        '警告の3段階・画面の縁の光り方・地図の色・警告音の試聴',
        MapAndAlertsGuidePage(
          primaryWarningLeadSeconds: primaryWarningLeadSeconds,
          advanceWarningLeadSeconds: advanceWarningLeadSeconds,
        ),
      ),
      (
        Icons.groups_outlined,
        TeamGuidePage.title,
        '招待コード・臨時危険区域の追加・位置の調整・橋脚の登録',
        const TeamGuidePage(),
      ),
      (
        Icons.build_outlined,
        TroubleshootingGuidePage.title,
        '音が鳴らない・他の艇が出ないなど',
        const TroubleshootingGuidePage(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('使い方')),
      body: ListView(
        padding: EdgeInsets.all(dimens.space4),
        children: [
          const GuideLimitsNotice(),
          SizedBox(height: dimens.space3),
          for (final entry in entries)
            Card(
              margin: EdgeInsets.only(bottom: dimens.space2),
              child: ListTile(
                minVerticalPadding: dimens.space3,
                leading: Icon(entry.$1),
                title: Text(
                  entry.$2,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(entry.$3),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(context, entry.$4),
              ),
            ),
          SizedBox(height: dimens.space2),
          TextButton.icon(
            onPressed: () => _push(
              context,
              FirstRunGuideScreen(
                primaryWarningLeadSeconds: primaryWarningLeadSeconds,
                advanceWarningLeadSeconds: advanceWarningLeadSeconds,
              ),
            ),
            icon: const Icon(Icons.replay),
            label: const Text('はじめての案内をもう一度見る'),
          ),
        ],
      ),
    );
  }
}
