import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../config/warning_audio_config.dart';
import '../../../theme/app_theme.dart';

/// 警告音の音量(アプリ内)。実際の音量は端末の音量との掛け算になる。
///
/// トランシーバーは大きく、このアプリは小さく聞きたいときに使う。
/// 範囲と下限の理由は `warningAudioAppVolumeMin` を参照。
class WarningAudioVolumeControl extends HookWidget {
  const WarningAudioVolumeControl({
    super.key,
    required this.volume,
    required this.onChanged,
  });

  final ValueNotifier<double> volume;
  final Future<void> Function(double volume) onChanged;

  @override
  Widget build(BuildContext context) {
    final current = useValueListenable(volume);
    final percent = (current * 100).round();
    final divisions = ((warningAudioAppVolumeMax - warningAudioAppVolumeMin) /
            warningAudioAppVolumeStep)
        .round();
    return Row(
      children: [
        const Text(
          '警告音',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        Expanded(
          child: Slider(
            value: current,
            min: warningAudioAppVolumeMin,
            max: warningAudioAppVolumeMax,
            divisions: divisions,
            label: '$percent%',
            semanticFormatterCallback: (value) =>
                '警告音の音量 ${(value * 100).round()}%',
            onChanged: (value) {
              volume.value = normalizeWarningAudioAppVolume(value);
              onChanged(volume.value);
            },
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '$percent%',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: context.colors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
