import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

import '../config/store_config.dart';
import '../models/team_model.dart';
import '../services/team_service.dart';
import '../widgets/team_invite_share_button.dart';

enum _TeamOnboardingMode { create, join }

class TeamOnboardingScreen extends StatefulWidget {
  final TeamService teamService;
  final TeamRecoveryHint? recoveryHint;
  final ValueChanged<TeamMembership> onCompleted;

  const TeamOnboardingScreen({
    super.key,
    required this.teamService,
    this.recoveryHint,
    required this.onCompleted,
  });

  @override
  State<TeamOnboardingScreen> createState() => _TeamOnboardingScreenState();
}

class _TeamOnboardingScreenState extends State<TeamOnboardingScreen> {
  final _teamNameController = TextEditingController();
  final _inviteCodeController = TextEditingController();
  _TeamOnboardingMode? _mode;
  bool _submitting = false;
  bool _acceptedTerms = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final recovery = widget.recoveryHint;
    if (recovery != null) {
      _mode = _TeamOnboardingMode.join;
      _inviteCodeController.text = TeamInviteCode.format(recovery.inviteCode);
    }
  }

  @override
  void dispose() {
    _teamNameController.dispose();
    _inviteCodeController.dispose();
    super.dispose();
  }

  String _friendlyError(Object error) {
    if (error is InvalidInviteCodeException) {
      return '招待コードが正しくありません。区切りの有無はどちらでも入力できます。';
    }
    if (error is AlreadyInTeamException) {
      return 'この端末はすでにチームに参加しています。再試行してください。';
    }
    if (error is TermsNotAcceptedException) {
      return '利用規約への同意が必要です。';
    }
    if (error is ArgumentError) {
      return 'チーム名は1〜40文字で入力してください。';
    }
    return '処理を完了できませんでした。通信状態を確認して再試行してください。';
  }

  Future<void> _submit() async {
    if (_submitting || _mode == null) return;
    if (!_acceptedTerms) {
      setState(() => _error = '利用規約への同意が必要です。');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final membership = _mode == _TeamOnboardingMode.create
          ? await widget.teamService.createTeam(
              _teamNameController.text,
              acceptedTerms: _acceptedTerms,
            )
          : await widget.teamService.joinTeam(
              _inviteCodeController.text,
              acceptedTerms: _acceptedTerms,
            );
      if (!mounted) return;
      if (_mode == _TeamOnboardingMode.create) {
        final shouldContinue = await _showCreatedDialog(membership);
        if (!mounted || !shouldContinue) return;
      }
      widget.onCompleted(membership);
    } catch (error) {
      // Firestore所属の確定後、RTDB bridge更新中に一時的に
      // 通信が切れることがある。「失敗」と表示する前に復元を
      // 1回試し、確定済みチームを二重作成しない。
      try {
        final recovered = await widget.teamService.restoreMembership();
        if (recovered != null && mounted) {
          if (_mode == _TeamOnboardingMode.create) {
            final shouldContinue = await _showCreatedDialog(recovered);
            if (!mounted || !shouldContinue) return;
          }
          widget.onCompleted(recovered);
          return;
        }
      } catch (_) {
        // 復元もできないときだけ、元の理由を表示する。
      }
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<bool> _showCreatedDialog(TeamMembership membership) async {
    final formatted = TeamInviteCode.format(membership.inviteCode);
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('チームを作成しました'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'このコードは管理者が更新できます。チームメンバーだけに共有してください。',
                ),
                const SizedBox(height: 14),
                SelectableText(
                  formatted,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: formatted));
                  if (!dialogContext.mounted) return;
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('招待コードをコピーしました。')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('コピー'),
              ),
              TeamInviteShareButton(
                teamName: membership.team.name,
                inviteCode: membership.inviteCode,
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('マップへ'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _openExternalUrl(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URLを開けませんでした。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _mode == null ? _buildChoice() : _buildForm(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChoice() {
    return Column(
      key: const ValueKey('team-choice'),
      children: [
        Icon(Icons.rowing,
            size: 72, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 20),
        Text(
          'Rowing Navigator',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 10),
        const Text(
          '位置と危険区域は、同じチーム内だけで共有されます。',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => setState(() => _mode = _TeamOnboardingMode.create),
            icon: const Icon(Icons.add_circle_outline),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('チームを作成する', style: TextStyle(fontSize: 17)),
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => setState(() => _mode = _TeamOnboardingMode.join),
            icon: const Icon(Icons.vpn_key_outlined),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text(
                '招待コードでチームに参加する',
                style: TextStyle(fontSize: 17),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'メールアドレスやパスワードの登録はありません。',
          style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          '一度参加すると、通常は次回以降の操作なしで同じチームに自動接続します。',
          style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildForm() {
    final creating = _mode == _TeamOnboardingMode.create;
    return Column(
      key: ValueKey(_mode),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.recoveryHint != null && !creating) ...[
          Card(
            key: const ValueKey('team-recovery-notice'),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'チームへの再参加が必要です',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '以前「${widget.recoveryHint!.teamName}」に参加していましたが、端末の認証情報を確認できませんでした。保存されていた招待コードを確認し、もう一度参加してください。通常の再起動ではこの操作は不要です。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _submitting
                ? null
                : () => setState(() {
                      _mode = null;
                      _error = null;
                    }),
            icon: const Icon(Icons.arrow_back),
            label: const Text('戻る'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          creating ? 'チームを作成' : 'チームに参加',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          creating
              ? 'チーム名を決めると、管理者が更新できる招待コードを発行します。'
              : 'チームメンバーから受け取った招待コードを入力してください。',
        ),
        const SizedBox(height: 24),
        if (creating)
          TextField(
            controller: _teamNameController,
            autofocus: true,
            maxLength: 40,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'チーム名',
              hintText: '例: 桜川ボートクラブ',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          )
        else
          TextField(
            controller: _inviteCodeController,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z\s-]')),
            ],
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '招待コード',
              hintText: 'XXXX-XXXX-XXXX',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '利用規約（$teamTermsVersion）',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '・招待コードはチーム外へ公開しません。\n'
                  '・本アプリの警告は安全確認や操船判断を代替しません。\n'
                  '・不適切な利用や危険情報は、運営へ通報できます。\n'
                  '・管理者は必要に応じて招待コードを更新し、メンバーを外せます。',
                  style: TextStyle(fontSize: 13),
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton(
                      onPressed: () => _openExternalUrl(privacyPolicyUrl),
                      child: const Text('プライバシーポリシー'),
                    ),
                    TextButton(
                      onPressed: () => _openExternalUrl(supportUrl),
                      child: const Text('サポート'),
                    ),
                    TextButton(
                      onPressed: () => _openExternalUrl(supportReportFormUrl),
                      child: const Text('通報・お問い合わせ'),
                    ),
                  ],
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _acceptedTerms,
                  onChanged: _submitting
                      ? null
                      : (value) => setState(() {
                            _acceptedTerms = value ?? false;
                            if (_acceptedTerms) _error = null;
                          }),
                  title: const Text('利用規約とプライバシーポリシーに同意します。'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _submitting || !_acceptedTerms ? null : _submit,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: _submitting
                ? const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(creating ? '作成する' : '参加する'),
          ),
        ),
      ],
    );
  }
}
