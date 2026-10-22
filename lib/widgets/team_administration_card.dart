import 'package:flutter/material.dart';

import '../models/team_model.dart';
import '../services/team_service.dart';

/// 作成者だけに表示する、公開版に必要な最小限のチーム管理。
///
/// 管理対象の匿名UIDを完全表示せず、招待コード更新とメンバー削除だけを行う。
/// 削除時はサービス側でコードも回転し、古いコードによる再参加を防ぐ。
class TeamAdministrationCard extends StatefulWidget {
  final VoidCallback onMembershipChanged;

  const TeamAdministrationCard({
    super.key,
    required this.onMembershipChanged,
  });

  @override
  State<TeamAdministrationCard> createState() => _TeamAdministrationCardState();
}

class _TeamAdministrationCardState extends State<TeamAdministrationCard> {
  final TeamService _teamService = TeamService();
  bool _isRotating = false;
  String? _removingUid;

  Future<void> _rotateInviteCode() async {
    if (_isRotating || _removingUid != null) return;
    setState(() => _isRotating = true);
    try {
      final membership = await _teamService.rotateInviteCode();
      if (!mounted) return;
      widget.onMembershipChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '招待コードを更新しました: ${TeamInviteCode.format(membership.inviteCode)}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('招待コードを更新できませんでした: $error')),
      );
    } finally {
      if (mounted) setState(() => _isRotating = false);
    }
  }

  Future<void> _removeMember(TeamMemberSummary member) async {
    if (_isRotating || _removingUid != null) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('メンバーをチームから外しますか？'),
            content: Text(
              '${member.displayLabel}(メンバーID ${member.shortId}…)のFirestore・位置共有へのアクセスを停止します。'
              '同時に招待コードも更新されるため、古いコードでの再参加はできません。',
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
                child: const Text('外す'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _removingUid = member.userId);
    try {
      await _teamService.removeMember(member.userId);
      if (!mounted) return;
      widget.onMembershipChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('メンバーを外し、招待コードを更新しました。'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('メンバーを外せませんでした: $error')),
      );
    } finally {
      if (mounted) setState(() => _removingUid = null);
    }
  }

  Future<void> _transferAdministrator(TeamMemberSummary member) async {
    if (_isRotating || _removingUid != null) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('管理者を交代しますか？'),
            content: Text(
              '${member.displayLabel}(メンバーID ${member.shortId}…)を管理者にします。'
              '交代すると、あなたは招待コードの更新やメンバーの削除ができなくなります。'
              '相手のチーム画面に表示される「あなたのメンバーID」と一致することを確認してください。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('交代する'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _removingUid = member.userId);
    try {
      await _teamService.transferAdministrator(member.userId);
      if (!mounted) return;
      widget.onMembershipChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${member.displayLabel} を管理者にしました。')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('管理者を交代できませんでした: $error')),
      );
    } finally {
      if (mounted) setState(() => _removingUid = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final membership = TeamService.activeMembership;
    if (membership == null || !membership.isAdministrator) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'チーム管理',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              '管理者は招待コードの更新と、メンバーの即時削除を行えます。削除時はコードも更新されます。'
              '機種変更・引退の前には、メンバー右端のメニューから管理者を交代してください。',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _isRotating || _removingUid != null
                  ? null
                  : _rotateInviteCode,
              icon: _isRotating
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_isRotating ? '更新しています…' : '招待コードを更新'),
            ),
            const SizedBox(height: 12),
            Text(
              'メンバー',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            StreamBuilder<List<TeamMemberSummary>>(
              stream: _teamService.watchManagedTeamMembers(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text('メンバー一覧を取得できませんでした。通信を確認してください。');
                }
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final members = snapshot.data!;
                return Column(
                  children: members.map((member) {
                    final isSelf = member.userId == membership.userId;
                    final isRemoving = _removingUid == member.userId;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(isSelf
                          ? Icons.admin_panel_settings
                          : Icons.person_outline),
                      // 同じ名前の人がいてもよいので、メンバーIDを必ず併記する。
                      title: Text(
                        isSelf
                            ? '${member.displayLabel}（あなた・管理者）'
                            : member.displayLabel,
                      ),
                      subtitle: Text(
                        [
                          'メンバーID ${member.shortId}…',
                          if (member.joinedAt != null)
                            '参加日: ${member.joinedAt!.toLocal().toString().split(' ').first}',
                        ].join('　'),
                      ),
                      trailing: isSelf
                          ? null
                          : isRemoving
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : PopupMenuButton<_MemberAction>(
                                  tooltip: 'メンバーの操作',
                                  enabled: !_isRotating && _removingUid == null,
                                  onSelected: (action) {
                                    switch (action) {
                                      case _MemberAction.makeAdministrator:
                                        _transferAdministrator(member);
                                      case _MemberAction.remove:
                                        _removeMember(member);
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: _MemberAction.makeAdministrator,
                                      child: Text('管理者にする'),
                                    ),
                                    PopupMenuItem(
                                      value: _MemberAction.remove,
                                      child: Text('チームから外す'),
                                    ),
                                  ],
                                ),
                    );
                  }).toList(growable: false),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum _MemberAction { makeAdministrator, remove }
