import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

import '../config/store_config.dart';
import '../services/account_data_deletion_service.dart';
import 'app_entry_gate.dart';

class PrivacyDataScreen extends StatefulWidget {
  const PrivacyDataScreen({super.key});

  @override
  State<PrivacyDataScreen> createState() => _PrivacyDataScreenState();
}

class _PrivacyDataScreenState extends State<PrivacyDataScreen> {
  bool _deleting = false;

  Future<void> _openUrl(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URLを開けませんでした。')),
      );
    }
  }

  Future<void> _deleteAccountAndData() async {
    final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('アカウントとデータの削除'),
            content: const Text(
              '端末内の練習記録・設定、航行中の共有位置、このアカウントが作成した臨時危険区域、チーム所属、Firebase匿名アカウントを削除します。同じチームの他のメンバーとチーム自体は削除されません。この操作は取り消せません。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('削除する'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || _deleting) return;

    setState(() => _deleting = true);
    try {
      await AccountDataDeletionService().deleteCurrentAccountAndData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('アカウントと端末内データを削除しました。')),
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppEntryGate()),
        (_) => false,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('削除を完了できませんでした: $error')),
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('プライバシーとデータ')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '航行中は、入力した名前、正確な位置、進行方向、速度、艇種、電池残量等を、接近警告と監視のためFirebaseへ送信します。航行終了時にリアルタイム位置を削除します。監視中は、受信したチーム艇の位置と警告状態、監視者の位置をこの端末だけに一括ログとして保存します。自動アップロードはしませんが、他の監視端末に保存された記録はこの画面から削除できません。広告や追跡には使用しません。',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('プライバシーポリシー'),
            subtitle: Text(
              privacyPolicyUrl.isEmpty
                  ? '公開URLが未設定です（公開ビルド前に必須）'
                  : privacyPolicyUrl,
            ),
            onTap: privacyPolicyUrl.isEmpty
                ? null
                : () => _openUrl(privacyPolicyUrl),
          ),
          ListTile(
            leading: const Icon(Icons.support_agent),
            title: const Text('サポート'),
            subtitle: Text(
              supportUrl.isEmpty ? 'サポートURLが未設定です（公開ビルド前に必須）' : supportUrl,
            ),
            onTap: supportUrl.isEmpty ? null : () => _openUrl(supportUrl),
          ),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('通報・お問い合わせ'),
            subtitle: const Text('不適切な利用、危険情報、招待コードの漏洩を運営へ連絡する'),
            onTap: () => _openUrl(supportReportFormUrl),
          ),
          const Divider(height: 32),
          Text(
            user == null
                ? '現在、Firebase匿名アカウントは作成されていません。端末内データは削除できます。'
                : '現在、航行共有用のFirebase匿名アカウントがあります。',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _deleting ? null : _deleteAccountAndData,
            icon: _deleting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_forever, color: Colors.red),
            label: Text(
              user == null ? '端末内データをすべて削除' : 'アカウントとデータを削除',
              style: const TextStyle(color: Colors.red),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '安全データとして共有された固定流木の現行状態は残し、更新者IDだけを匿名化します。他の利用者が作成した臨時危険区域の存続中データも、自分の更新者IDだけを匿名化します。削除後に利用を再開するときは、招待コードで改めて参加してください。',
            style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
