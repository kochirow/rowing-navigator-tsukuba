import 'package:flutter/material.dart';

import '../../../hooks/use_coach_watch.dart';
import '../../../theme/app_theme.dart';

/// 監視(コーチ)モードで、異常の件数を地図上に**小さく**示すチップ。
///
/// 以前は異常のたびに赤い danger SnackBar(6〜8秒)を出していたが、
/// 実機テストで「細かいエラーを大きく伝えすぎ。基本は各艇の位置が
/// 画面で見られればいい」という指摘を受けた。
/// 変えるのは**大きさと音だけ**で、情報は減らさない
/// (DESIGN_PRINCIPLES 原則1「機能を止めない」・原則6「データ欠損は安全の根拠に
/// ならない」)。詳細は艇一覧(`BoatListPanel`)に従来どおり全て出ており、
/// このチップはそこへの入口を兼ねる。
///
/// 配色は danger の塗りつぶしを避け、地図上チップの標準面([AppColors.chipScrim])に
/// 枠線でアクセントを付ける。枠線の色だけは異常の重さで変える。
/// - 長時間停止・水域外(沈・迷子の疑い) → [AppColors.danger]
/// - 更新途絶だけ / 水域外検知の停止だけ → [AppColors.caution]
class CoachAnomalyChip extends StatelessWidget {
  /// 現在検知されている異常。空なら件数行は出さない。
  final List<BoatAnomaly> anomalies;

  /// 練習水域を読めず、「水域外」の自動検知だけが働いていない状態。
  ///
  /// 能力が欠けていることは必ず画面に出す(原則1)。ただし赤バナーではなく
  /// このチップへ小さく併記する。
  final bool practiceAreaUnavailable;

  /// タップ時の動作。艇一覧を開くために使う。
  final VoidCallback? onTap;

  const CoachAnomalyChip({
    super.key,
    required this.anomalies,
    this.practiceAreaUnavailable = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 伝えることが何もないときは場所を取らない。
    if (anomalies.isEmpty && !practiceAreaUnavailable) {
      return const SizedBox.shrink();
    }

    final colors = context.colors;
    // 同じ艇に複数の異常が立つことはない実装だが、件数は「隻」で数える。
    final boatCount = anomalies.map((anomaly) => anomaly.boatId).toSet().length;
    final hasSerious = anomalies.any((anomaly) => !anomaly.isRoutine);
    final accent = hasSerious ? colors.danger : colors.caution;

    final lines = <String>[
      if (boatCount > 0) '異常 $boatCount隻',
      if (practiceAreaUnavailable) '水域外の自動検知が停止中',
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Semantics(
            // 内側の Text を個別に読み上げず、1つのまとまりとして伝える。
            // タップ操作の意味づけは外側の InkWell が持つ。
            label: [...lines, if (onTap != null) 'タップで艇一覧を開く'].join('。'),
            excludeSemantics: true,
            child: Container(
              // 濡れた手・グローブでも押せる大きさを確保する。
              constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: colors.chipScrim,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: accent, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasSerious
                        ? Icons.warning_amber_rounded
                        : Icons.info_outline,
                    size: 18,
                    color: accent,
                  ),
                  const SizedBox(width: 6),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < lines.length; i++)
                        Text(
                          lines[i],
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: i == 0 ? 14 : 12,
                            height: 1.2,
                            fontWeight:
                                i == 0 ? FontWeight.bold : FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
