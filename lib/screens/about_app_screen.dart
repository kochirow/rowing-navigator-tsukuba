import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/startup_motto_view.dart';

/// 「このアプリについて」。アプリを作った趣旨を載せる。
///
/// 読むだけの画面で、設定も安全経路も何も変えない。
class AboutAppScreen extends StatelessWidget {
  const AboutAppScreen({super.key});

  static const title = 'このアプリについて';

  /// 本文。見出しと段落の組。文言を直すときはここだけを触ればよい。
  static const sections = <(String, List<String>)>[
    (
      '漕艇部の悲願',
      [
        '1985年、霞ヶ浦で東洋大牛久高校の死亡事故が起きました。'
            'それ以来、安全に練習できる環境は、漕艇部の悲願でした。',
        '諸先輩方が力を尽くしてくださったおかげで、'
            'いまの私たちは安全に、健康に、日々の練習に励むことができています。',
      ],
    ),
    (
      '安全は、背中を守ってくれるもの',
      [
        '安全は、競技にも学業にも全力で打ち込めるよう、背中を守ってくれるものです。'
            '安全と健康はすべての土台であり、何よりも先に確保しなければなりません。',
        'けれども、ライバルとの競争の重圧に日々さらされる中では、'
            '軽く見られがちなものでもあります。',
      ],
    ),
    (
      '安全にゴールはない',
      [
        '安全にゴールはありません。より安全で、より安心できる環境を、'
            '不断の努力で、自分たちの手でつかみ取らなければなりません。',
      ],
    ),
    (
      'このアプリを作った理由',
      [
        '嶋田先輩の尽力によって、私たちは桜川で練習できるようになりました。'
            'その環境を自分たちの手でより確かなものにするために、このアプリを作りました。',
        '学生が常に自ら考え、行動し、安全・健康第一で日々の練習に励む。'
            'このアプリがその助けになれば幸いです。',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          dimens.space5,
          dimens.space5,
          dimens.space5,
          dimens.space6,
        ),
        children: [
          const Center(child: ClubMottoCalligraphy(fontSize: 40)),
          SizedBox(height: dimens.space4),
          Text(
            '「安全・健康第一」は、OBで元監督の北之園さんが'
            'よくおっしゃっていた言葉です。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.7,
              color: colors.textSecondary,
            ),
          ),
          SizedBox(height: dimens.space5),
          for (final (heading, paragraphs) in sections) ...[
            SizedBox(height: dimens.space4),
            Text(
              heading,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
            for (final paragraph in paragraphs) ...[
              SizedBox(height: dimens.space2),
              Text(
                paragraph,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.8,
                  color: colors.textPrimary,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
