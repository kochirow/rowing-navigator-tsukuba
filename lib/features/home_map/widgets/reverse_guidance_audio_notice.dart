import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// 利用者が逆走注意の読み上げだけを止めた間、その状態を常時示す帯。
///
/// 判定・画面表示・記録は続く。設定シートを閉じたあとに静音を忘れて
/// 「アプリが鳴らない」と誤解しないよう、航行画面で明示する。
class ReverseGuidanceAudioNotice extends StatelessWidget {
  const ReverseGuidanceAudioNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      liveRegion: true,
      label: '逆走注意の音声はオフです。表示・判定・記録は続いています。',
      child: Container(
        key: const ValueKey('reverse-guidance-audio-off-notice'),
        width: double.infinity,
        color: colors.cautionSurface,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Icon(Icons.volume_off, color: colors.caution, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '逆走注意の音声オフ',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
