import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_state_views.dart';

/// 部の標語。OB・元監督の北之園さんがよく口にしていた言葉。
const clubMotto = '安全・健康第一';

/// 標語の毛筆フォント(Yuji Boku)。
///
/// 8.5MB ある元のフォントから [clubMotto] の7文字だけを切り出して同梱している
/// (`assets/fonts/YujiBoku-Motto.ttf`、約7KB)。**ほかの文字は入っていない**ので、
/// 標語以外の文言にこのフォントを使うと、その文字だけ端末の標準書体になる。
/// 文字を足すときは元フォントから切り出し直すこと(手順は pubspec.yaml)。
const clubMottoFontFamily = 'YujiBokuMotto';

/// 標語を毛筆で1行に書く。
class ClubMottoCalligraphy extends StatelessWidget {
  final double fontSize;
  final Color? color;

  const ClubMottoCalligraphy({super.key, this.fontSize = 32, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      clubMotto,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        fontFamily: clubMottoFontFamily,
        fontSize: fontSize,
        color: color ?? context.colors.textPrimary,
      ),
    );
  }
}

/// 起動中に出す画面。従来の読み込み表示はそのままに、上の空いた所へ標語を添える。
///
/// Firebase の準備・チーム所属・名前の確認の3段階で同じ画面を使う
/// (段階ごとに標語が出たり消えたりしないように)。表示時間は延ばさない。
class StartupMottoView extends StatelessWidget {
  final String? message;

  const StartupMottoView({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AppLoadingView(message: message),
        // 中央の読み込み表示と重ならない高さ(画面の上から約2割)に置く。
        const Align(
          alignment: Alignment(0, -0.6),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: ClubMottoCalligraphy(fontSize: 34),
            ),
          ),
        ),
      ],
    );
  }
}
