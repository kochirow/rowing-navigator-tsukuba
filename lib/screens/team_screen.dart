import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

import '../config/store_config.dart';
import '../models/team_model.dart';
import '../services/account_display_name_service.dart';
import '../services/team_service.dart';
import '../widgets/team_invite_share_button.dart';
import '../widgets/team_administration_card.dart';
import 'app_entry_gate.dart';
import 'display_name_registration_screen.dart';

class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  final TeamService _teamService = TeamService();
  final AccountDisplayNameService _displayNameService =
      AccountDisplayNameService();
  bool _isClaiming = false;
  String? _accountName;

  @override
  void initState() {
    super.initState();
    _displayNameService.load().then((name) {
      if (mounted) setState(() => _accountName = name);
    }).catchError((Object error) {
      debugPrint('Failed to load account display name: $error');
    });
    // 別の端末で管理者が交代していれば反映する。通信できなければ手元のまま。
    _teamService.refreshActiveTeam().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _editAccountName(TeamMembership membership) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (routeContext) => DisplayNameRegistrationScreen(
          service: _displayNameService,
          initialName: _accountName,
          firstRegistration: false,
          onSaved: (name) {
            Navigator.of(routeContext).pop();
            if (mounted) setState(() => _accountName = name);
            // メンバー一覧への写し。失敗しても次の起動で送り直す。
            _displayNameService.publishIfNeeded(
              userId: membership.userId,
              serverName: TeamService.activeMembership?.displayName,
              publish: _teamService.updateMyDisplayName,
            );
          },
        ),
      ),
    );
  }

  Future<void> _claimAdministrator() async {
    if (_isClaiming) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('管理者を引き継ぎますか？'),
            content: const Text(
              '管理者がチームを退出した、またはアカウントを削除した場合だけ引き継げます。'
              '管理者がまだチームにいる場合は、管理者に交代を依頼してください。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('引き継ぐ'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _isClaiming = true);
    try {
      await _teamService.claimAdministrator();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('このチームの管理者になりました。')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) setState(() => _isClaiming = false);
    }
  }

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
                  Text(
                    'あなたのメンバーID: ${TeamMemberSummary(userId: membership.userId).shortId}'
                    '${membership.isAdministrator ? '(管理者)' : ''}',
                    style: TextStyle(
                        fontSize: 12, color: context.colors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              key: const ValueKey('team-account-name'),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              leading: const Icon(Icons.badge_outlined),
              title: Text(
                _accountName ?? '名前未登録',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              // 行全体で変更できるので「変更」ボタンは重ねない。
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editAccountName(membership),
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
                  const SizedBox(height: 12),
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
                    label: const Text('コピー'),
                  ),
                  const SizedBox(height: 10),
                  TeamInviteShareButton(
                    teamName: membership.team.name,
                    inviteCode: membership.inviteCode,
                    label: '共有',
                    filled: true,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'コードを知る人は誰でも参加できます。SNS等に公開しないでください。',
                    style: TextStyle(
                        fontSize: 12, color: context.colors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 危険区域の権限の説明カードは「使い方」のチームのページへ移した
          // (操作の無い説明だけのカードだった)。
          Card(
            child: ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('通報・お問い合わせ'),
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
          ] else ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: const Text('管理者を引き継ぐ'),
                subtitle: const Text(
                  '管理者が退出・アカウント削除してチームに管理者がいないときに使います。',
                ),
                trailing: _isClaiming
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: _isClaiming ? null : _claimAdministrator,
              ),
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
        content: Text(
          'この端末の現在地・艇情報の共有を停止して、チームの危険区域と位置情報は見られなくなります。\n\n'
          'チームや他のメンバーのデータ、保存済みの練習記録は削除されません。再参加には招待コードが必要です。'
          '${TeamService.activeMembership?.isAdministrator == true ? '\n\nあなたは管理者です。退出の前に、チーム管理のメンバー一覧から管理者を交代してください。'
              '交代せずに退出した場合は、残ったメンバーが「管理者を引き継ぐ」で引き継げます。' : ''}',
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
            // 見出しと説明は置かない。ボタン名が言い、失うものは確認ダイアログが示す。
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
