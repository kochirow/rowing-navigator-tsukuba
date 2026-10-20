import 'package:flutter/material.dart';

import '../../config/alert_presentation_config.dart';
import '../../config/warning_audio_config.dart';
import '../../theme/app_theme.dart';
import '../../theme/boat_palette.dart';
import '../../theme/nav_palette.dart';
import 'guide_widgets.dart';

/// 警告の段階・画面の縁の点滅・地図の色・警告音の試聴。
///
/// 2026-09 の画面刷新で航行中の警告バナーを外し、相手のいる側の画面の縁を
/// 光らせる表示に変えた。以前のこのページは「太い枠が明滅」「右 5秒」と
/// 刷新前の画面を説明したままだったので、航行画面どおりに書き直した。
///
/// 秒数は呼び出し側から「いま効いている値」を受け取る。本警告・予告の時間は
/// 設定画面とチーム共有で変わるため、文言へ直書きすると実際の鳴り方と
/// 違う説明になる(過去に「約7秒」と書かれたまま、実際は10秒になっていた)。
class MapAndAlertsGuidePage extends StatelessWidget {
  const MapAndAlertsGuidePage({
    super.key,
    required this.primaryWarningLeadSeconds,
    required this.advanceWarningLeadSeconds,
  });

  final double primaryWarningLeadSeconds;
  final double advanceWarningLeadSeconds;

  static const title = '地図と警告音';

  static const audioEntries = <(String, String)>[
    (otherBoatWarningAudioAsset, '他艇'),
    ('audio/shore_warning.mp3', '岸'),
    ('audio/bridge_warning.mp3', '橋'),
    ('audio/bridge_pier_warning.mp3', '橋脚'),
    ('audio/island_warning.mp3', '中州'),
    ('audio/driftwood_warning.mp3', '流木'),
    ('audio/pile_warning.mp3', '杭'),
    ('audio/curve_warning.mp3', 'カーブ'),
    ('audio/reverse_warning.mp3', '逆走注意'),
  ];

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    final colors = context.colors;
    final primary = formatGuideSeconds(primaryWarningLeadSeconds);
    final advance = formatGuideSeconds(advanceWarningLeadSeconds);
    final guidanceSeconds = formatGuideSeconds(
      const AlertPresentationConfig().guidanceRepeatInterval.inMilliseconds /
          1000,
    );

    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      body: ListView(
        padding: EdgeInsets.all(dimens.space4),
        children: [
          GuideSection(
            title: '警告の3段階',
            description: '音の鳴り方は「あと何秒で届くか」だけで決まります。'
                '何に近づいているかは、音声で読み上げます(「他艇に注意」「橋に注意」など)。',
            child: Column(
              children: [
                GuideUrgencyRow(
                  icon: Icons.graphic_eq,
                  title: '連続音',
                  body: 'あと$primary秒以内に届きます。すぐ周りを確認してください。',
                ),
                GuideUrgencyRow(
                  icon: Icons.more_horiz,
                  title:
                      '断続音（${formatGuideSeconds(guideIntermittentIntervalSeconds)}秒ごと）',
                  body: 'あと$primary〜$advance秒で届きます。',
                ),
                const GuideUrgencyRow(
                  icon: Icons.visibility_outlined,
                  title: '表示のみ',
                  body: '近くにありますが、届く見込みはありません。音は鳴りません。',
                ),
                Text(
                  'GPSの誤差を含めたときだけ当たる見込みがある場合は、1段下げて鳴らします。',
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          GuideSection(
            title: '航行画面の縁が光る',
            description: '衝突の警告音が鳴っている間、相手のいる側の画面の縁が赤く点滅します。'
                '連続音と断続音で見た目は変わりません。',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const GuideEdgeAlertIllustration(),
                SizedBox(width: dimens.space3),
                Expanded(
                  child: GuideBullets(
                    items: [
                      '地図は進行方向が画面の下になるよう回ります。'
                          '画面の右下が光ったら、体の右後ろに相手がいます。',
                      '艇の向きが確かでないとき(回頭中や低速時)は、向きを出さず縁の全体が光ります。',
                      'カーブと逆走は案内なので縁は光りません。'
                          '区域にいる間、$guidanceSeconds秒ごとに読み上げます。'
                          '衝突の警告音が鳴っている間は、そちらを優先します。',
                    ],
                  ),
                ),
              ],
            ),
          ),
          const GuideSection(
            title: '地図の色（航行中）',
            description: '航行中は電池を抑えるため、暗い配色に固定しています。'
                '赤は他艇と警告の点滅だけに使います。',
            child: Column(
              children: [
                GuideSwatchRow(
                  swatch: Icon(Icons.navigation, color: BoatPalette.myBoat),
                  label: '自艇(白)',
                ),
                GuideSwatchRow(
                  swatch: Icon(Icons.navigation, color: BoatPalette.otherBoat),
                  label: '他艇(赤)',
                ),
                GuideLegendRow(
                  category: 'bridgePier',
                  label: '固定の危険区域(橋・橋脚・中州・流木・杭・カーブ・逆走はすべて琥珀)',
                  night: true,
                ),
                GuideLegendRow(
                    category: 'shore', label: '岸(白い細線)', night: true),
                GuideSwatchRow(
                  swatch: SizedBox(
                    width: 30,
                    child: Divider(
                      color: NavPalette.selfPrediction,
                      thickness: 2,
                    ),
                  ),
                  label: '自艇がこれから通る範囲(実線＝止まれる距離、破線＝警告する距離)',
                ),
              ],
            ),
          ),
          GuideSection(
            title: '地図の色（待機中・監視中）',
            description: '塗りは実際にそこにある危険、線だけの図形は'
                '艇がこれから通る予測範囲です。',
            child: const Column(
              children: [
                GuideLegendRow(category: 'shore', label: '岸'),
                GuideLegendRow(category: 'bridge', label: '橋'),
                GuideLegendRow(category: 'bridgePier', label: '橋脚'),
                GuideLegendRow(category: 'island', label: '中州'),
                GuideLegendRow(category: 'driftwood', label: '流木'),
                GuideLegendRow(category: 'pile', label: '杭'),
                GuideLegendRow(category: 'curve', label: 'カーブ'),
                GuideLegendRow(category: 'reverse', label: '逆走注意'),
              ],
            ),
          ),
          const GuideSection(
            title: '警告音の試聴',
            description: '出艇前に、どの音がどの対象かを確かめられます。',
            child: GuideAudioPreviewList(entries: audioEntries),
          ),
        ],
      ),
    );
  }
}
