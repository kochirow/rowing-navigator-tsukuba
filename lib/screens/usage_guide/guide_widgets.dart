import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/hazard_palette.dart';
import '../../theme/nav_palette.dart';

/// 使い方の各ページで共用する部品。表示だけで、設定は何も変えない。

/// 10.0 → "10"、8.5 → "8.5"。設定は0.5秒刻みなので小数1桁で足りる。
String formatGuideSeconds(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

/// 見出し+短い説明+中身の1節。
class GuideSection extends StatelessWidget {
  final String title;
  final String? description;
  final Widget child;

  const GuideSection({
    super.key,
    required this.title,
    this.description,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Padding(
      padding: EdgeInsets.only(bottom: dimens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          if (description != null) ...[
            SizedBox(height: dimens.space1),
            Text(
              description!,
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
          ],
          SizedBox(height: dimens.space3),
          child,
        ],
      ),
    );
  }
}

/// 番号付きの手順。
class GuideSteps extends StatelessWidget {
  final List<String> steps;

  const GuideSteps({super.key, required this.steps});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: dimens.space2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: colors.onPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                SizedBox(width: dimens.space2),
                Expanded(
                  child: Text(
                    steps[i],
                    style: TextStyle(color: colors.textPrimary, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 中黒の箇条。
class GuideBullets extends StatelessWidget {
  final List<String> items;

  const GuideBullets({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: EdgeInsets.only(bottom: dimens.space2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('・', style: TextStyle(color: colors.textPrimary)),
                Expanded(
                  child: Text(
                    item,
                    style: TextStyle(color: colors.textPrimary, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 「このアプリが検出できるもの・できないもの」。目次と初回案内の両方に出す。
class GuideLimitsNotice extends StatelessWidget {
  const GuideLimitsNotice({super.key});

  static const text = '検出できるのは、このアプリで位置を共有している艇と、'
      '登録済みの危険区域だけです。'
      '本アプリは安全確認の補助であり、衝突回避を保証しません。'
      '周囲の目視確認を必ず行ってください。';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Container(
      padding: EdgeInsets.all(dimens.space3),
      decoration: BoxDecoration(
        color: colors.cautionSurface,
        borderRadius: dimens.borderMd,
        border: Border.all(color: colors.caution),
      ),
      child: Text(text, style: TextStyle(color: colors.textPrimary)),
    );
  }
}

/// 警告の段階の1行(音の名前と、届くまでの時間)。
class GuideUrgencyRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const GuideUrgencyRow({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Padding(
      padding: EdgeInsets.only(bottom: dimens.space3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 28, color: colors.textPrimary),
          SizedBox(width: dimens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  body,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 航行画面の縁が光る様子の小さな図。相手が右後ろにいるときの例。
///
/// 地図は進行方向が画面の下になるよう回るので、画面の右下は漕手の体の右後ろ
/// (`edge_alert_overlay.dart`)。色は航行画面と同じ [NavPalette] を使う。
class GuideEdgeAlertIllustration extends StatelessWidget {
  const GuideEdgeAlertIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '航行画面の例。相手のいる側の画面の縁が赤く光る',
      child: Container(
        width: 72,
        height: 128,
        decoration: BoxDecoration(
          color: NavPalette.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: NavPalette.line, width: 2),
        ),
        child: Stack(
          children: [
            Positioned(
              right: 0,
              bottom: 12,
              child: Container(
                width: 6,
                height: 56,
                decoration: BoxDecoration(
                  color: NavPalette.alert,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(
                      color: NavPalette.alert.withValues(alpha: 0.6),
                      blurRadius: 10,
                    ),
                  ],
                ),
              ),
            ),
            const Align(
              alignment: Alignment(0, -0.1),
              child: Icon(Icons.navigation, color: NavPalette.value, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}

/// 地図の凡例の1行。[night] は航行中の夜の配色。
class GuideLegendRow extends StatelessWidget {
  final String category;
  final String label;
  final bool night;

  const GuideLegendRow({
    super.key,
    required this.category,
    required this.label,
    this.night = false,
  });

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    final fill = night
        ? HazardPalette.nightFillColorOf(category)
        : HazardPalette.fillColorOf(context, category);
    final stroke = night
        ? HazardPalette.nightStrokeColorOf(category)
        : HazardPalette.strokeColorOf(context, category);
    return Padding(
      padding: EdgeInsets.only(bottom: dimens.space2),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 26,
            color: night ? const Color(0xFF17405A) : null,
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                border: Border.all(
                  color: stroke,
                  width: HazardPalette.strokeWidthOf(category).toDouble(),
                ),
              ),
            ),
          ),
          SizedBox(width: dimens.space3),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: context.colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 艇や予測線の凡例の1行(色の見本+説明)。
class GuideSwatchRow extends StatelessWidget {
  final Widget swatch;
  final String label;

  const GuideSwatchRow({super.key, required this.swatch, required this.label});

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    return Padding(
      padding: EdgeInsets.only(bottom: dimens.space2),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 26,
            alignment: Alignment.center,
            color: const Color(0xFF17405A),
            child: swatch,
          ),
          SizedBox(width: dimens.space3),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: context.colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「故障かな？と思ったら」の1項目。見出しは利用者が口にする症状。
class GuideTroubleItem extends StatelessWidget {
  final String symptom;
  final String reason;
  final String action;

  const GuideTroubleItem({
    super.key,
    required this.symptom,
    required this.reason,
    required this.action,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    final labelStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.bold,
      color: colors.textSecondary,
    );
    final bodyStyle = TextStyle(color: colors.textPrimary, height: 1.45);
    return Card(
      margin: EdgeInsets.only(bottom: dimens.space3),
      child: Padding(
        padding: EdgeInsets.all(dimens.space3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              symptom,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
            SizedBox(height: dimens.space2),
            Text('理由', style: labelStyle),
            Text(reason, style: bodyStyle),
            SizedBox(height: dimens.space2),
            Text('すること', style: labelStyle),
            Text(action, style: bodyStyle),
          ],
        ),
      ),
    );
  }
}

/// 警告音の試聴ボタンの並び。失敗しても画面に理由を出すだけで、
/// 他の機能へ影響させない。
class GuideAudioPreviewList extends StatefulWidget {
  /// (アセットのパス, 表示名) の組。
  final List<(String, String)> entries;

  const GuideAudioPreviewList({super.key, required this.entries});

  @override
  State<GuideAudioPreviewList> createState() => _GuideAudioPreviewListState();
}

class _GuideAudioPreviewListState extends State<GuideAudioPreviewList> {
  AudioPlayer? _player;
  String? _playingAsset;
  String? _audioError;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _preview(String asset) async {
    setState(() {
      _audioError = null;
      _playingAsset = asset;
    });
    try {
      final player = _player ??= AudioPlayer();
      await player.stop();
      await player.play(AssetSource(asset));
    } catch (error) {
      if (!mounted) return;
      setState(() => _audioError = '音声を再生できませんでした。端末の音量・消音設定を確認してください。');
    } finally {
      if (mounted) setState(() => _playingAsset = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in widget.entries)
          Padding(
            padding: EdgeInsets.only(bottom: dimens.space2),
            child: OutlinedButton.icon(
              onPressed:
                  _playingAsset == null ? () => _preview(entry.$1) : null,
              icon: const Icon(Icons.volume_up),
              label: Text('${entry.$2} の警告音'),
            ),
          ),
        if (_audioError != null)
          Text(_audioError!, style: TextStyle(color: colors.danger)),
      ],
    );
  }
}
