import 'package:flutter/material.dart';

/// 地図で艇の上に出る名前の札(「4+ 後藤」)を、同じ見た目で画面に出す。
///
/// 名前を入れる画面で「この名前は艇種と一緒に、他の艇と監視端末の地図に
/// 出ます」と文章で説明する代わりに、出る札そのものを見せる。
/// 色と枠は地図の札(`getNameLabelBitmapDescriptor`)と同じにする。
class BoatNameTag extends StatelessWidget {
  const BoatNameTag({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '地図での表示: $label',
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('boat-name-tag'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xD9002E4D),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
