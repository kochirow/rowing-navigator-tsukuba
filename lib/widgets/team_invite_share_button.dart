import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/team_invite_share_service.dart';

/// 招待コードをOSの共有シートへ渡すボタン。
///
/// iPadのpopover表示で必要な起点を、実際のボタン領域から必ず指定する。
class TeamInviteShareButton extends StatelessWidget {
  final String teamName;
  final String inviteCode;
  final String label;
  final bool filled;

  const TeamInviteShareButton({
    super.key,
    required this.teamName,
    required this.inviteCode,
    this.label = '共有',
    this.filled = false,
  });

  Future<void> _share(BuildContext context) async {
    final renderObject = context.findRenderObject();
    final origin = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : const Rect.fromLTWH(0, 0, 1, 1);
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: TeamInviteShareService.buildText(
            teamName: teamName,
            inviteCode: inviteCode,
          ),
          subject: 'Rowing Navigator チーム招待',
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('共有シートを開けませんでした。もう一度お試しください。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (filled) {
      return FilledButton.icon(
        onPressed: () => _share(context),
        icon: const Icon(Icons.share),
        label: Text(label),
      );
    }
    return TextButton.icon(
      onPressed: () => _share(context),
      icon: const Icon(Icons.share),
      label: Text(label),
    );
  }
}
