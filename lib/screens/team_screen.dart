import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

import '../config/store_config.dart';
import '../services/team_service.dart';
import '../widgets/team_invite_share_button.dart';
import '../widgets/team_administration_card.dart';
import 'app_entry_gate.dart';

class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  @override
  Widget build(BuildContext context) {
    final membership = TeamService.activeMembership;
    if (membership == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('チーム')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'チーム情報を確認できません。自動接続をもう一度確認してください。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const AppEntryGate()),
                      (_) => false,
                    );
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('接続を確認'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final formattedCode = TeamInviteCode.format(membership.inviteCode);
    return Scaffold(
      appBar: AppBar(title: const Text('チーム')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    membership.team.name,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '位置情報と共有危険区域は、このチーム内だけで表示されます。',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'この端末は次回以降も自動接続します。退出する場合は、この画面の下部から操作できます。',
                    style: TextStyle(
                        fontSize: 12, color: context.colors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'チーム招待コード',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'このコードを知る人は参加できます。管理者はコードを更新して、古いコードを即時無効にできます。',
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(
                      formattedCode,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: formattedCode),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('招待コードをコピーしました。')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('招待コードをコピー'),
                  ),
                  const SizedBox(height: 10),
                  TeamInviteShareButton(
                    teamName: membership.team.name,
                    inviteCode: membership.inviteCode,
                    label: '招待コードを共有',
                    filled: true,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '注意: コードを知る人はチームの位置情報と危険区域を共有できます。SNS等に公開しないでください。',
                    style: TextStyle(
                        fontSize: 12, color: context.colors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.edit_location_alt_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'チームメンバーは全員、臨時危険区域の追加・編集・削除と、共有固定危険区域の更新ができます。現場で安全を確認してから操作してください。問題のある利用や危険情報は、通報フォームから運営へ連絡できます。',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('通報・お問い合わせ'),
              subtitle: const Text('不適切な利用、危険情報、招待コードの漏洩は運営へ連絡してください。'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () async {
                final opened = await launchUrl(
                  Uri.parse(supportReportFormUrl),
                  mode: LaunchMode.externalApplication,
                );
                if (!opened && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('通報フォームを開けませんでした。')),
                  );
                }
              },
            ),
          ),
          if (membership.isAdministrator) ...[
            const SizedBox(height: 12),
            TeamAdministrationCard(
              onMembershipChanged: () => setState(() {}),
            ),
          ],
          const SizedBox(height: 12),
          const _LeaveTeamCard(),
        ],
      ),
    );
  }
}

class _LeaveTeamCard extends StatefulWidget {
  const _LeaveTeamCard();

  @override
  State<_LeaveTeamCard> createState() => _LeaveTeamCardState();
}

class _LeaveTeamCardState extends State<_LeaveTeamCard> {
  bool _isLeaving = false;

  Future<void> _confirmAndLeave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('チームから退出しますか？'),
        content: const Text(
          'この端末の現在地・艇情報の共有を停止して、チームの危険区域と位置情報は見られなくなります。\n\n'
          'チームや他のメンバーのデータ、保存済みの練習記録は削除されません。再参加には招待コードが必要です。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('退出する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isLeaving = true);
    try {
      await TeamService().leaveTeam();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppEntryGate()),
        (_) => false,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('チームを退出できませんでした。通信状態を確認して再試行してください。'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLeaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'チームから退出',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: errorColor,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'この端末をチームから外します。もう一度参加するには招待コードが必要です。',
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _isLeaving ? null : _confirmAndLeave,
              style: OutlinedButton.styleFrom(foregroundColor: errorColor),
              icon: _isLeaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout),
              label: Text(_isLeaving ? '退出しています…' : 'チームから退出'),
            ),
          ],
        ),
      ),
    );
  }
}
