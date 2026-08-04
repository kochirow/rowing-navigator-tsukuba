import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../../types/home_phase.dart';

/// いまが出艇前・航行中・監視中のどれかを、地図の上に1つだけ出すピル。
///
/// **3状態そろえる理由。** 以前は監視中だけ「監視モード」と出していた。
/// 残る2つ(出艇前・航行中)は同じ地図で、見分けるには画面下のボタンの
/// 文言を読むしかなかった。姿勢が変われば触れる操作も変わるので、
/// いまどの姿勢にいるのかは地図を一目見て分かる必要がある。
///
/// 待機中に「監視モード」と出すと画面下の「監視スタート」と矛盾して
/// 見えたため、以前は待機中を空欄にしていた。「出艇前」であれば
/// スタートボタンと矛盾しない。
class NavPhaseChip extends StatelessWidget {
  final HomePhase phase;

  const NavPhaseChip({super.key, required this.phase});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (IconData icon, String label, Color dot) = switch (phase) {
      HomePhase.ashore => (Icons.anchor, '出艇前', colors.textDisabled),
      HomePhase.navigating => (Icons.rowing, '航行中', colors.ok),
      HomePhase.watching => (Icons.visibility, '監視中', colors.info),
    };

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: colors.chipScrim,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 稼働している状態だけ色の付いた点を添える。文字を読まなくても
          // 「いま動いているか」が周辺視野で分かる。
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          Icon(icon, size: 18, color: colors.onDark),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: colors.onDark,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
