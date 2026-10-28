import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// 共有シートを出す起点(押したボタンの位置)を画面座標で返す。
///
/// iPad と iOS 26 以降は、起点が無い・大きさ0だと共有シートが出ない(何も起きない)。
/// 記録画面の共有はすべてここを通し、位置の渡し忘れを再発させない。
/// ボタンの大きさが取れないときは画面の中央の1点を使う。
Rect shareOriginOf(BuildContext anchor) {
  final box = anchor.findRenderObject();
  if (box is RenderBox && box.hasSize && box.size.longestSide > 0) {
    final origin = box.localToGlobal(Offset.zero) & box.size;
    if (!origin.isEmpty) return origin;
  }
  final size = MediaQuery.maybeSizeOf(anchor) ?? const Size(1, 1);
  return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);
}

/// 共有の結果を利用者向けの1文にする。
String shareResultMessage(ShareResult r, {required String what}) =>
    switch (r.status) {
      ShareResultStatus.success => '共有先へ$whatを渡しました。',
      ShareResultStatus.dismissed => '共有をキャンセルしました。',
      ShareResultStatus.unavailable => '共有シートを開きました。完了結果はこの端末から取得できません。',
    };
