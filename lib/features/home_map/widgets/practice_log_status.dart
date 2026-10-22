import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// 練習一括ログを保存できないときに、監視画面の上に常設で出す帯。
///
/// 黙って失敗させない(原則6)。監視そのものは続いているので、画面には
/// 絵+短い語だけを出し、理由の全文は読み上げに渡す。
class PracticeLogFailureNotice extends StatelessWidget {
  const PracticeLogFailureNotice({super.key, required this.message});

  /// 読み上げに渡す理由の全文。
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      liveRegion: true,
      label: message,
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('practice-log-failure-notice'),
        width: double.infinity,
        color: colors.cautionSurface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(children: [
          Icon(Icons.sd_card_alert_outlined, color: colors.caution, size: 20),
          const SizedBox(width: 8),
          Text(
            '記録できません',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ]),
      ),
    );
  }
}

/// ボタンの左上に、記録中を示す小さな赤い点を重ねる。
///
/// 「監視終了（記録中）」の括弧書きの代わり。記録はほぼ常に動いているので、
/// 文字を足すよりも点1つで示す。
class RecordingDot extends StatelessWidget {
  const RecordingDot({super.key, required this.recording, required this.child});

  final bool recording;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!recording) return child;
    return Semantics(
      hint: '記録中',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            left: 2,
            top: 2,
            child: Container(
              key: const ValueKey('watch-recording-dot'),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: context.colors.danger,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
