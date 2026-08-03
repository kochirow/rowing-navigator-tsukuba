import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../config/warning_audio_config.dart';
import '../theme/app_theme.dart';
import '../theme/hazard_palette.dart';

/// 画面の読み方を1枚にまとめた説明。
///
/// チーム参加後にいきなり地図が出るため、赤い区域が何を意味するのか、
/// 連続音と断続音がどう違うのかを学ぶ場所がどこにも無かった。ここは
/// 表示の意味を説明するだけで、設定は何も変えない。
class UsageGuideScreen extends StatefulWidget {
  const UsageGuideScreen({super.key});

  @override
  State<UsageGuideScreen> createState() => _UsageGuideScreenState();
}

class _UsageGuideScreenState extends State<UsageGuideScreen> {
  AudioPlayer? _player;
  String? _playingAsset;
  String? _audioError;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  /// 試聴。失敗しても画面に理由を出すだけで、他の機能へ影響させない。
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

    return Scaffold(
      appBar: AppBar(title: const Text('使い方')),
      body: ListView(
        padding: EdgeInsets.all(dimens.space4),
        children: [
          _Section(
            title: '警告の3段階',
            description: '音の鳴り方は「あと何秒で届くか」だけで決まります。'
                '画面の見た目も同じ段階に合わせてあります。',
            child: Column(
              children: [
                _UrgencyRow(
                  color: colors.danger,
                  border: 3,
                  title: '連続音',
                  body: '約7秒以内に届きます。太い枠が明滅します。すぐ確認してください。',
                ),
                SizedBox(height: dimens.space2),
                _UrgencyRow(
                  color: colors.danger,
                  border: 2,
                  title: '断続音（3秒ごと）',
                  body: '約10秒以内に届きます。濃い色で表示します。',
                ),
                SizedBox(height: dimens.space2),
                _UrgencyRow(
                  color: Color.lerp(colors.danger, Colors.white, 0.48)!,
                  border: 1.5,
                  title: '表示のみ',
                  body: '近くにありますが、到達の予測はありません。音は鳴りません。',
                ),
              ],
            ),
          ),
          _Section(
            title: '警告の読み方',
            description: '1行目が対象、2行目が「振り向く側」と「残り秒数」です。'
                '同じ種類が複数あるときは ×件数 でまとめます。',
            child: const Text('例: 「他艇」／「右 5秒」→ 右側から他艇が5秒後に接近'),
          ),
          _Section(
            title: '地図の色',
            description: '塗りは実際にそこにある危険、線だけの図形は'
                '自艇・他艇がこれから通る予測範囲です。',
            child: Column(
              children: [
                for (final entry in const [
                  ('shore', '岸'),
                  ('bridge', '橋'),
                  ('bridgePier', '橋脚'),
                  ('island', '中州'),
                  ('driftwood', '流木'),
                  ('pile', '杭'),
                  ('curve', 'カーブ'),
                  ('reverse', '逆走注意'),
                ])
                  _LegendRow(category: entry.$1, label: entry.$2),
              ],
            ),
          ),
          _Section(
            title: '橋脚の登録',
            description: '橋脚は、橋桁ではなく水中に立つ柱そのものを危険区域として登録します。',
            child: const Text(
              'プロットツールでは、橋脚の実際の外周を3点以上で直接囲みます。橋桁全体・影・周囲の余裕幅は含めません。形状が航空写真だけでは分からない場合は、現地確認まで下書きとして扱います。',
            ),
          ),
          _Section(
            title: '警告音の試聴',
            description: '出艇前に、どの音がどの対象かを確かめられます。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in const [
                  ('audio/shore_warning.mp3', '岸'),
                  ('audio/bridge_warning.mp3', '橋'),
                  ('audio/bridge_pier_warning.mp3', '橋脚'),
                  ('audio/island_warning.mp3', '中州'),
                  ('audio/driftwood_warning.mp3', '流木'),
                  ('audio/pile_warning.mp3', '杭'),
                  ('audio/curve_warning.mp3', 'カーブ'),
                  ('audio/reverse_warning.mp3', '逆走注意'),
                  (otherBoatWarningAudioAsset, '他艇'),
                ])
                  Padding(
                    padding: EdgeInsets.only(bottom: dimens.space2),
                    child: OutlinedButton.icon(
                      onPressed: _playingAsset == null
                          ? () => _preview(entry.$1)
                          : null,
                      icon: const Icon(Icons.volume_up),
                      label: Text('${entry.$2} の警告音'),
                    ),
                  ),
                if (_audioError != null)
                  Text(
                    _audioError!,
                    style: TextStyle(color: colors.danger),
                  ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.all(dimens.space3),
            decoration: BoxDecoration(
              color: colors.cautionSurface,
              borderRadius: dimens.borderMd,
              border: Border.all(color: colors.caution),
            ),
            child: const Text(
              '検出できるのは、このアプリで位置を共有している艇と、'
              '登録済みの危険区域だけです。'
              '本アプリは安全確認の補助であり、衝突回避を保証しません。'
              '周囲の目視確認を必ず行ってください。',
            ),
          ),
          SizedBox(height: dimens.space5),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String description;
  final Widget child;

  const _Section({
    required this.title,
    required this.description,
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
          SizedBox(height: dimens.space1),
          Text(
            description,
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          SizedBox(height: dimens.space3),
          child,
        ],
      ),
    );
  }
}

class _UrgencyRow extends StatelessWidget {
  final Color color;
  final double border;
  final String title;
  final String body;

  const _UrgencyRow({
    required this.color,
    required this.border,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dimens = context.dimens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 62,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: Colors.white, width: border),
          ),
          child: Text(
            '岸',
            style: TextStyle(
              color: color.computeLuminance() > 0.5
                  ? const Color(0xFF241A1A)
                  : Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
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
    );
  }
}

class _LegendRow extends StatelessWidget {
  final String category;
  final String label;

  const _LegendRow({required this.category, required this.label});

  @override
  Widget build(BuildContext context) {
    final dimens = context.dimens;
    return Padding(
      padding: EdgeInsets.only(bottom: dimens.space2),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 22,
            decoration: BoxDecoration(
              color: HazardPalette.fillColorOf(context, category),
              border: Border.all(
                color: HazardPalette.strokeColorOf(context, category),
                width: HazardPalette.strokeWidthOf(category).toDouble(),
              ),
            ),
          ),
          SizedBox(width: dimens.space3),
          Text(label, style: TextStyle(color: context.colors.textPrimary)),
        ],
      ),
    );
  }
}
