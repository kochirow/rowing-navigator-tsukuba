import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'guide_widgets.dart';

/// 艇に乗って漕ぐ人の使い方(出艇前・航行中・航行後)。
///
/// 航行中は端末を触れず文章も読めないので、ここに書くことは
/// すべて出艇前に陸で読む前提にする(DESIGN_PRINCIPLES 1.3)。
class NavigationGuidePage extends StatelessWidget {
  const NavigationGuidePage({super.key});

  static const title = '航行';

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: ListView(
        padding: EdgeInsets.all(dimens.space4),
        children: const [
          GuideSection(
            title: '出艇前',
            child: GuideSteps(
              steps: [
                '端末を艇に固定します。航行中は画面に触れなくても使えるように作ってあり、'
                    '画面は航行中ずっと点いたままです。',
                '音量を上げ、消音モードを切ります。警告は音声で伝えます。',
                '「航行スタート」を押し、設定シートで名前・艇種・端末を置くシートを選びます。'
                    '前回の設定が入っているので、同じなら「この設定で航行スタート」を押します。',
                '初めての航行では、位置情報を「常に許可」にするよう求められます。'
                    '画面が消えたり別のアプリを開いたりしても、接近の警告と位置の共有を続けるためです。',
              ],
            ),
          ),
          GuideSection(
            title: '航行中',
            child: GuideBullets(
              items: [
                '他の艇や危険区域に近づくと、対象を読み上げます。'
                    '鳴り方と画面の縁の光り方は「地図と警告音」で確かめられます。',
                '計器の上段は /500m と spm、下段は既定で距離(m)と chrono です。'
                    '下段は縦に回すと DPS・count に切り替わります。',
                '画面上部に琥珀色で「GPS」「受信」「共有」などが出たら、測位か通信が不調です。'
                    '音は鳴りません。',
                '流木などを見つけたら、メニューの「危険区域を追加」で航行中でも登録できます。',
              ],
            ),
          ),
          GuideSection(
            title: '航行後',
            child: GuideBullets(
              items: [
                '「航行終了」を押すと、位置の共有と衝突の警告が止まり、練習記録が端末に保存されます。',
                'メニューの「練習記録」で距離・スプリット・ピースを見られます。'
                    'GPX(Strava用)と CSV で書き出せます。',
              ],
            ),
          ),
        ],
      ),
    );
  }
}
