import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/display_name_config.dart';
import '../services/account_display_name_service.dart';
import '../theme/app_theme.dart';

/// アカウントの名前を登録・変更する画面。
///
/// 初回(チーム参加直後・名前未登録のまま新しい版を起動したとき)は
/// 戻るボタンを出さず、名前を決めてから地図へ進む。登録は端末内への保存
/// だけで通信を待たないので、圏外でも先へ進める。
class DisplayNameRegistrationScreen extends StatefulWidget {
  final AccountDisplayNameService service;

  /// 入力欄に最初から入れておく名前。
  final String? initialName;

  /// 初回登録か(true なら戻れない)。チーム画面からの変更は false。
  final bool firstRegistration;

  /// 端末内へ保存できた名前を受け取る。
  final void Function(String name) onSaved;

  const DisplayNameRegistrationScreen({
    super.key,
    required this.service,
    required this.onSaved,
    this.initialName,
    this.firstRegistration = true,
  });

  @override
  State<DisplayNameRegistrationScreen> createState() =>
      _DisplayNameRegistrationScreenState();
}

class _DisplayNameRegistrationScreenState
    extends State<DisplayNameRegistrationScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName ?? '');
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = normalizeDisplayName(_controller.text);
    final error = displayNameValidationError(name);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _saving = true);
    var saved = name;
    try {
      saved = await widget.service.save(name);
    } catch (error) {
      // 端末内に保存できなくても、この起動中は入力した名前で先へ進む
      // (原則1)。次の起動でもう一度この画面が出る。
      debugPrint('Failed to save account display name: $error');
    }
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onSaved(saved);
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.firstRegistration;
    return PopScope(
      canPop: !first,
      child: Scaffold(
        appBar: AppBar(
          title: Text(first ? '名前の登録' : '名前の変更'),
          automaticallyImplyLeading: !first,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Icon(
                Icons.badge_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                first ? 'あなたの名前を登録してください' : '名前を変更します',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 10),
              const Text(
                '航行中、他の艇と監視端末に「4+ 後藤」のように艇種と一緒に表示され、'
                '誰が漕いでいるかが分かります。チームの管理者のメンバー一覧にも表示されます。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                key: const ValueKey('account-display-name-field'),
                controller: _controller,
                autofocus: (widget.initialName ?? '').isEmpty,
                maxLength: maxDisplayNameLength,
                maxLines: 1,
                textInputAction: TextInputAction.done,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(maxDisplayNameLength),
                ],
                style: const TextStyle(fontSize: 20),
                decoration: InputDecoration(
                  labelText: '名前',
                  hintText: '例: 後藤',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.person),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              Text(
                '同じ名前の人がいても登録できます。航行ごとに別の名前にしたいときは、'
                '航行開始の画面で書き換えられます。',
                style: TextStyle(
                  fontSize: 12,
                  color: context.colors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const ValueKey('account-display-name-submit'),
                onPressed: _saving ? null : _submit,
                icon: const Icon(Icons.check),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    first ? '登録する' : '変更する',
                    style: const TextStyle(fontSize: 17),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
