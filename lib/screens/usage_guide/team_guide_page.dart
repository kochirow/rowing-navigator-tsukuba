import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'guide_widgets.dart';

/// チームと危険区域を管理する人向け。招待コード・臨時危険区域・位置の調整・橋脚の登録。
class TeamGuidePage extends StatelessWidget {
  const TeamGuidePage({super.key});

  static const title = 'チームと危険区域';

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: ListView(
        padding: EdgeInsets.all(dimens.space4),
        children: const [
          GuideSection(
            title: '招待コード',
            child: GuideBullets(
              items: [
                'メニューの「チーム」で確認・共有できます。位置と危険区域を共有するコードなので、'
                    'チームの外へは出さないでください。',
                '管理者は招待コードを更新し、メンバーを外せます。コードが漏れたときは更新してください。',
              ],
            ),
          ),
          GuideSection(
            title: '臨時危険区域の追加',
            description: '流木など、その日だけの危険を地図に描いてチームへ共有します。',
            child: GuideBullets(
              items: [
                'メニューの「危険区域を追加」から登録します。航行中でも登録できます。',
                '登録した区域はチーム全員の地図に出て、警告の対象になります。'
                    'チームメンバーは全員、追加・編集・削除ができます。',
              ],
            ),
          ),
          GuideSection(
            title: '既設危険区域の位置の調整',
            description: '橋・岸・中州の位置が実際とずれているときに、0.5m単位で動かしてチームへ公開します。',
            child: GuideBullets(
              items: [
                '出艇前(待機中)だけメニューに出ます。',
                '公開するとチーム全員の警告の位置が動きます。現地で確かめてから公開してください。',
              ],
            ),
          ),
          GuideSection(
            title: '橋脚の登録',
            description: '橋脚は、橋桁ではなく水中に立つ柱そのものを危険区域として登録します。',
            child: Text(
              'プロットツールでは、橋脚の実際の外周を3点以上で直接囲みます。橋桁全体・影・周囲の余裕幅は含めません。形状が航空写真だけでは分からない場合は、現地確認まで下書きとして扱います。',
            ),
          ),
          GuideSection(
            title: '警告の対象から外す',
            child: GuideBullets(
              items: [
                'メニューの「警告の設定」→「警告対象となる障害物の選択」で、'
                    '危険区域ごとに警告のオン・オフを切り替えられます。オフにしても地図からは消えません。',
              ],
            ),
          ),
        ],
      ),
    );
  }
}
