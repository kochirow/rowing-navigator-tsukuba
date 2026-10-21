import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 部の標語。OB・元監督の北之園さんがよく口にしていた言葉。
const clubMotto = '安全・健康第一';

/// 標語の出典。標語の下に小さく添える。
const clubMottoAttribution = 'OB・元監督 北之園さんの言葉';

/// 標語の毛筆フォント(Yuji Boku)。
///
/// 8.5MB ある元のフォントから [clubMotto] の7文字だけを切り出して同梱している
/// (`assets/fonts/YujiBoku-Motto.ttf`、約7KB)。**ほかの文字は入っていない**ので、
/// 標語以外の文言にこのフォントを使うと、その文字だけ端末の標準書体になる。
/// 文字を足すときは元フォントから切り出し直すこと(手順は pubspec.yaml)。
const clubMottoFontFamily = 'YujiBokuMotto';

/// 標語を毛筆で縦書きにする。
///
/// 縦書きは1文字ずつ縦に積んで作る(Flutter に縦組みが無いため)。
/// 「・」は全角の中央にある字形なので、縦に積んでも真ん中に来る。
class ClubMottoCalligraphy extends StatelessWidget {
  final double fontSize;
  final Color? color;

  const ClubMottoCalligraphy({super.key, this.fontSize = 64, this.color});

  @override
  Widget build(BuildContext context) {
    final ink = color ?? context.colors.textPrimary;
    return Semantics(
      label: clubMotto,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final char in clubMotto.characters)
            Text(
              char,
              style: TextStyle(
                fontFamily: clubMottoFontFamily,
                fontSize: fontSize,
                height: 1.08,
                color: ink,
              ),
            ),
        ],
      ),
    );
  }
}

/// 起動中に出す画面。標語を大きく掲げ、下に進み具合を出す。
///
/// Firebase の準備・チーム所属・名前の確認の3段階で同じ画面を使う。
/// 段階ごとに別の画面にすると、起動のたびに標語が出たり消えたりする。
class StartupMottoView extends StatelessWidget {
  final String? message;

  const StartupMottoView({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(dimens.space5),
        child: Column(
          children: [
            Expanded(
              child: Center(
                // 小さい端末でも7文字が収まるよう、余白に合わせて縮める。
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ClubMottoCalligraphy(fontSize: 76),
                      SizedBox(height: dimens.space5),
                      Text(
                        clubMottoAttribution,
                        style: TextStyle(
                          fontSize: 15,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: colors.primary,
              ),
            ),
            if (message != null) ...[
              SizedBox(height: dimens.space3),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: colors.textSecondary),
              ),
            ],
            SizedBox(height: dimens.space4),
          ],
        ),
      ),
    );
  }
}
