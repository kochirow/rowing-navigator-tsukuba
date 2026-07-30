import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';

/// 陸上と判定して警告音を止めている間、その事実を常時示す帯。
///
/// 艇庫での準備や艇の運搬中は岸の危険区域の内側にいるため、
/// 実機テスト(2026-07-26)では陸上で連続音が鳴っていた。
/// 判定が成立した間は音だけを止めるが、**黙って止めてはいけない**。
/// 黙って止めると「鳴らないアプリ」と区別が付かず、水上で本当に
/// 音が出ないときに気付けない(DESIGN_PRINCIPLES 原則1)。
///
/// 止まっているのは音だけで、衝突判定・画面表示・航行記録・位置共有は
/// 従来どおり動いている。水面側の測位を1点でも観測すれば自動で戻るが、
/// 判定を誤っていると感じたら[onRestoreAudio]ですぐ音へ戻せる(原則2)。
class AshoreNotice extends StatelessWidget {
  /// 「音を戻す」を押したときの動作。
  final VoidCallback onRestoreAudio;

  const AshoreNotice({super.key, required this.onRestoreAudio});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      color: colors.cautionSurface,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.volume_off, color: colors.caution, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '陸上と判定して警告音を止めています',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '衝突判定・画面表示・記録は続いています。川へ戻れば自動で鳴ります。',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // 濡れた手でも押せるよう、最小タップ領域を確保する。
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            child: TextButton(
              onPressed: onRestoreAudio,
              child: const Text('音を戻す'),
            ),
          ),
        ],
      ),
    );
  }
}
