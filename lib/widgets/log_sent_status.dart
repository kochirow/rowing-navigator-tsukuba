import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

// # ログの「送信済み／未送信」の札
//
// 練習記録と監視ログの一覧で使う。送ったときは自動で送信済みになるが、
// 昔ほかの方法で送った分や、送り直したい分を、一覧から手で切り替えられるようにする。
//
// 札は押せる見た目にする(スワイプや長押しは画面を見ても気づけないため、
// 見える操作を主役にし、スワイプ・長押しは補助にする)。
// 切り替えは元に戻せるので、確認のダイアログは出さず、スナックバーの
// 「元に戻す」で取り消せるようにする。

/// 札に出す文言。送信済みなら日付を添える(いつ送ったかで思い出せる)。
String logSentStatusLabel(DateTime? sharedAt) {
  if (sharedAt == null) return 'ログ未送信';
  final d = sharedAt.toLocal();
  return 'ログ送信済み ${d.month}/${d.day}';
}

/// 一覧の各行に付ける、押すと切り替わる札。
class LogSentStatusChip extends StatelessWidget {
  final DateTime? sharedAt;

  /// null なら押せない(選択モード中など)。
  final VoidCallback? onToggle;

  const LogSentStatusChip({
    super.key,
    required this.sharedAt,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final sent = sharedAt != null;
    final color = sent ? colors.textSecondary : colors.primary;
    final label = logSentStatusLabel(sharedAt);
    return Semantics(
      button: onToggle != null,
      label: '$label。'
          '${onToggle == null ? '' : sent ? '押すと未送信に戻します' : '押すと送信済みにします'}',
      excludeSemantics: true,
      // Tooltip は付けない。スマホでは長押しで出るため、行の長押し(選択モード)を奪う。
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(999),
        // 札そのものは小さいが、押せる範囲は縦に広げて指で押しやすくする。
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.6)),
              color: sent ? null : colors.primary.withValues(alpha: 0.08),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(sent ? Icons.mark_email_read_outlined : Icons.outgoing_mail,
                  size: 14, color: color),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: sent ? FontWeight.w500 : FontWeight.bold,
                      color: color)),
              if (onToggle != null) ...[
                const SizedBox(width: 2),
                Icon(Icons.swap_horiz, size: 14, color: color),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// スワイプしたときに行の下から見える帯。
class LogSentSwipeBackground extends StatelessWidget {
  final bool currentlySent;
  const LogSentSwipeBackground({super.key, required this.currentlySent});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = currentlySent ? colors.textSecondary : colors.primary;
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: context.dimens.borderLg,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
            currentlySent
                ? Icons.outgoing_mail
                : Icons.mark_email_read_outlined,
            color: color),
        const SizedBox(width: 8),
        Text(currentlySent ? '未送信に戻す' : '送信済みにする',
            style: TextStyle(fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }
}

/// 切り替えた結果を伝える文。保存できなかった分は未送信/送信済みのまま残るので伝える。
String logSentToggleMessage(
    {required int changed, required int failed, required bool toShared}) {
  final done = toShared ? '送信済みにしました' : '未送信に戻しました';
  final base = '$changed件を$done';
  if (failed == 0) return '$base。';
  return '$base。$failed件は保存できず、元のままです。';
}
