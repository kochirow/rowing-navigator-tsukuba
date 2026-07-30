import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 画面の非同期状態を同じ見た目・文言階層で示す共通ビュー。
///
/// 非同期処理や再試行ロジックは持たず、各画面から受け取った状態を表示する
/// だけに留める。起動直後などテーマ拡張が未登録でも、[AppThemeContext] の
/// フォールバックにより安全に描画できる。
class AppLoadingView extends StatelessWidget {
  final IconData icon;
  final String? message;

  const AppLoadingView({
    super.key,
    this.icon = Icons.rowing,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(dimens.space5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: colors.primary),
            SizedBox(height: dimens.space5),
            CircularProgressIndicator(color: colors.primary),
            if (message != null) ...[
              SizedBox(height: dimens.space4),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: colors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AppEmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const AppEmptyView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(dimens.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: colors.textDisabled),
            SizedBox(height: dimens.space3),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: colors.textSecondary),
            ),
            if (message != null) ...[
              SizedBox(height: dimens.space1),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: colors.textDisabled),
              ),
            ],
            if (action != null) ...[
              SizedBox(height: dimens.space4),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class AppErrorView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  const AppErrorView({
    super.key,
    this.icon = Icons.error_outline,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  }) : assert(
          (secondaryLabel == null) == (onSecondary == null),
          '副操作のラベルとコールバックは両方指定してください。',
        );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(dimens.space5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: colors.danger),
            SizedBox(height: dimens.space4),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
            SizedBox(height: dimens.space2),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary),
            ),
            SizedBox(height: dimens.space5),
            FilledButton.icon(
              onPressed: onPrimary,
              icon: const Icon(Icons.refresh),
              label: Text(primaryLabel),
            ),
            if (onSecondary != null) ...[
              SizedBox(height: dimens.space2),
              TextButton.icon(
                onPressed: onSecondary,
                icon: const Icon(Icons.settings),
                label: Text(secondaryLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
