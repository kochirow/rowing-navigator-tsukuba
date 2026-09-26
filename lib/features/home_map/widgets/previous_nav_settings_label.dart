import 'package:flutter/material.dart';

import '../../../config/boat_config.dart';
import '../../../services/navigation_defaults_service.dart';
import '../../../types/boat_type.dart';

/// 出艇前の「航行スタート」の上に、前回の設定(名前・艇種・座席)を小さく出す。
///
/// 航行スタートは**必ず航行設定シートを開く**(毎回違う艇に乗ることが多い。
/// 2026-09-26 利用者)。シートには前回の設定が入っている。ここは確認用の表示だけ。
/// 読めなければ何も出さない。
class PreviousNavSettingsLabel extends StatefulWidget {
  const PreviousNavSettingsLabel({super.key});

  @override
  State<PreviousNavSettingsLabel> createState() =>
      _PreviousNavSettingsLabelState();
}

class _PreviousNavSettingsLabelState extends State<PreviousNavSettingsLabel> {
  String? _text;

  @override
  void initState() {
    super.initState();
    NavigationDefaultsService().load().then((d) {
      if (!mounted || d == null) return;
      final seat = boatConfigs
          .byBoatType(d.boatType)
          .seatPosList
          .where((s) => s.position == d.seatPosition)
          .map((s) => s.label)
          .firstOrNull;
      setState(() {
        _text = [
          if (d.displayName.isNotEmpty) d.displayName,
          d.boatType.displayLabel,
          if (seat != null) seat,
        ].join(' ・ ');
      });
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '前回: $text',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
