import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../../widgets/map_control_button.dart';
import 'warning_audio_volume_control.dart';

/// 警告音の音量(アプリ内)を合わせるシート。
///
/// 航行開始画面の小さなリンク、メニューの「警告音の音量」、監視中の地図の
/// 「音量」ボタンから開く。
/// どこから開いても同じ中身にする(覚える場所を1つにする)。
///
/// [onTest] は航行開始前だけ渡す。航行中・監視中に試し鳴らしをすると、
/// 鳴っている本物の警告を止めてしまう(`UseAlert.test` は最後に stop する)。
Future<void> showWarningAudioVolumeSheet(
  BuildContext context, {
  required ValueNotifier<double> volume,
  required Future<void> Function(double volume) onChanged,
  Future<void> Function()? onTest,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '警告音の音量',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            // 利用者の依頼で明記する(2026-10-24): 本体の音量とは別であること、
            // どんなときに下げるのか。
            Text(
              'スマホ本体の音量とは別の、このアプリだけの音量です。'
              '実際の音量は「本体の音量 × この設定」になります。\n'
              'このアプリの音が大きくてトランシーバーの声が聞き取りにくいときに下げてください。'
              'トランシーバーの音量は変わりません。',
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: context.colors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            WarningAudioVolumeControl(volume: volume, onChanged: onChanged),
            if (onTest != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.volume_up),
                  label: const Text('この音量で鳴らす'),
                  onPressed: onTest,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// 監視中の地図に置く「音量」ボタン。1回押すとスライダーが出る。
/// 航行中は置かない(ボタンが多く見づらくなるため、メニューから開く)。
class WarningAudioVolumeMapButton extends StatelessWidget {
  const WarningAudioVolumeMapButton({
    super.key,
    required this.volume,
    required this.onChanged,
  });

  final ValueNotifier<double> volume;
  final Future<void> Function(double volume) onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      child: MapControlButton(
        icon: Icons.volume_up,
        label: '音量',
        onPressed: () => showWarningAudioVolumeSheet(
          context,
          volume: volume,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// 航行開始画面の控えめな入口。いまの音量だけを小さく見せ、押すとシートを開く。
class WarningAudioVolumeLink extends StatelessWidget {
  const WarningAudioVolumeLink({
    super.key,
    required this.volume,
    required this.onChanged,
    this.onTest,
  });

  final ValueNotifier<double> volume;
  final Future<void> Function(double volume) onChanged;
  final Future<void> Function()? onTest;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: volume,
      builder: (context, value, _) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: context.colors.textSecondary,
            minimumSize: const Size(48, 48),
          ),
          icon: const Icon(Icons.volume_down, size: 20),
          label: Text(
            '警告音の音量 ${(value * 100).round()}%',
            style: const TextStyle(fontSize: 14),
          ),
          onPressed: () => showWarningAudioVolumeSheet(
            context,
            volume: volume,
            onChanged: onChanged,
            onTest: onTest,
          ),
        ),
      ),
    );
  }
}
