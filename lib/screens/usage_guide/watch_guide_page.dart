import 'package:flutter/material.dart';

import '../../config/coach_config.dart';
import '../../theme/app_theme.dart';
import 'guide_widgets.dart';

/// 陸から全艇を見る人(監視端末)の使い方。
///
/// 異常を知らせる秒数は `coach_config.dart` から出す。
class WatchGuidePage extends StatelessWidget {
  const WatchGuidePage({super.key});

  static const title = '監視';

  /// 180秒 → "3分"、90秒 → "90秒"。
  static String _duration(int seconds) =>
      seconds >= 120 && seconds % 60 == 0 ? '${seconds ~/ 60}分' : '$seconds秒';

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: ListView(
        padding: EdgeInsets.all(dimens.space4),
        children: [
          const GuideSection(
            title: '始め方',
            child: GuideSteps(
              steps: [
                '陸から全艇を見る端末で「監視スタート」を押します。',
                '航行中の艇の位置と、直近の航跡が地図に出ます。'
                    '艇ごとに色が付き、艇一覧でも同じ色を使います。',
                '終わるときは「監視終了」を押します。',
              ],
            ),
          ),
          GuideSection(
            title: '異常の知らせ',
            child: GuideBullets(
              items: [
                '${_duration(stoppedAlertSec)}以上動いていない艇(沈の疑い)と、'
                    '${_duration(lostAlertSec)}以上更新がない艇(電池切れ・アプリ終了・圏外の疑い)を、'
                    '地図上に件数で出します。',
                '件数の表示を押すと艇一覧が開きます。一覧の艇を押すと、地図がその艇へ寄ります。',
                '異常は音では知らせません。トランシーバーの音声と重なるためです。',
              ],
            ),
          ),
          const GuideSection(
            title: '記録',
            child: GuideBullets(
              items: [
                '監視中は、全艇と監視端末の位置・警告の状態を端末内に記録します。'
                    '記録はオフにできません。サーバーへは送りません。',
                'メニューの「監視ログ」から ZIP で共有できます。',
                '艇一覧のグラフのボタンから、その艇の1ストロークの艇速変化を見られます'
                    '(艇側でレートの計測がオンのときだけ)。'
                    '縦軸が艇速、横軸が時間で、細い縦線がキャッチ(入水)です。直近2ストロークぶんを出します。',
              ],
            ),
          ),
          const GuideSection(
            title: '画面',
            child: GuideBullets(
              items: [
                '監視中は画面を点けたままにしません。陸では手で点け直せるので、電池を優先しています。'
                    '画面が消えても記録は続きます。',
              ],
            ),
          ),
        ],
      ),
    );
  }
}
