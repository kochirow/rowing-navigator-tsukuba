import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_state_views.dart';

/// 部の標語。OB・元監督の北之園さんがよく口にしていた言葉。
const clubMotto = '安全・健康第一';

/// 標語の毛筆フォント(Yuji Syuku)。
///
/// 同じ毛筆の Yuji Boku は線が太く、アプリの本文(ゴシック)の隣で浮いたため、
/// 線の細い Syuku にした(2026-10-23)。
///
/// 元のフォントから [clubMotto] の7文字だけを切り出して同梱している
/// (`assets/fonts/YujiSyuku-Motto.ttf`、約7KB)。**ほかの文字は入っていない**ので、
/// 標語以外の文言にこのフォントを使うと、その文字だけ端末の標準書体になる。
/// 文字を足すときは元フォントから切り出し直すこと(手順は pubspec.yaml)。
const clubMottoFontFamily = 'YujiSyukuMotto';

/// 標語を毛筆で1行に書く。字間を少し空けて、見出しのような詰まった印象を避ける。
class ClubMottoCalligraphy extends StatelessWidget {
  final double fontSize;
  final Color? color;

  const ClubMottoCalligraphy({super.key, this.fontSize = 26, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      clubMotto,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        fontFamily: clubMottoFontFamily,
        fontSize: fontSize,
        letterSpacing: fontSize * 0.15,
        color: color ?? context.colors.textPrimary,
      ),
    );
  }
}

/// 起動中に出す画面。従来の読み込み表示のアイコンの上に標語を添える。
///
/// 標語を画面の上の方へ離して置くと、読み込み表示と別物に見えて浮いたため、
/// 同じまとまりの中に入れた(2026-10-23)。
/// Firebase の準備・チーム所属・名前の確認の3段階で同じ画面を使う
/// (段階ごとに標語が出たり消えたりしないように)。表示時間は延ばさない。
class StartupMottoView extends StatelessWidget {
  final String? message;

  const StartupMottoView({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return AppLoadingView(
      message: message,
      header: const FittedBox(
        fit: BoxFit.scaleDown,
        child: ClubMottoCalligraphy(),
      ),
    );
  }
}
