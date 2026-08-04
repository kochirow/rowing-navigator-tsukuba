import 'package:flutter/material.dart';

import '../../../config/map_style_config.dart';
import '../../../services/channel_cross_section.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/boat_palette.dart';

/// 航行中に「中央線のどちら側を走っているか」だけを伝える断面インジケータ。
///
/// **地図の補助であって、警告ではない。** レーンを外れても音は鳴らさない。
/// 岸から数mを走る・橋の下で休む・桟橋へ寄せるはいずれも正常な運用であり、
/// そこで鳴る警告は不具合である(DESIGN_PRINCIPLES 原則4)。ここは状態を
/// 映すだけで、判断は漕手がする(原則2)。
///
/// ## なぜ画面の下ではなく計器カードの直下なのか
///
/// 地図は `rowingMapBearing`(進行方位 + 180度)で回しているので、
/// **画面の下半分が進行方向**になる。自艇を上から45%の位置へ置いているのも
/// 進む先を広く見せるためで(`navigationSelfBoatScreenRatio`)、画面下部は
/// いちばん覆ってはいけない領域である。逆に上部はすでに計器カードが
/// 覆っていて、そこは漕手が肉眼で見ている後方にあたる。
///
/// 帯をここへ置くと、
///   - 進行方向の水面を1pxも減らさない
///   - ペース・レートと同じ一等地にまとまり、視線の移動が1回で済む
///   - 位置が変わらないので「どこを見るか」を毎回探さずに済む
///
/// カード本体の内側ではなく**外側の直下**に置くのは、カードが
/// `SingleChildScrollView` の中にあり、小型端末では下端が隠れうるため。
///
/// ## 左右の向き
///
/// [RowerSide] は漕手の体の左右で、地図の回転と一致する(詳細は [RowerSide])。
/// **画面の左に描いた側は、画面の地図でも左**である。翻訳を挟まないために、
/// 「右側通行」「左岸」といった語はここでは一切使わない。使うと、進行方向の
/// 右舷が漕手の左手側にある事実と衝突して、一瞥では読めなくなる。
class LaneCrossSectionStrip extends StatelessWidget {
  final ChannelCrossSection crossSection;

  /// 縦向きは画面幅の9割を中央へ、横向きは左上へ寄せて幅を絞る。
  /// 計器カード([NavStatusCard])と同じ規則にして、縁を揃える。
  final bool portrait;

  const LaneCrossSectionStrip({
    super.key,
    required this.crossSection,
    required this.portrait,
  });

  /// 横向きカードの最大幅。[NavStatusCard] と揃える。
  static const double _landscapeMaxWidth = 360;

  /// 縦向きカードが使う画面幅の割合。[NavStatusCard] と揃える。
  static const double _portraitWidthFactor = 0.9;

  static const double _trackHeight = 22;

  @override
  Widget build(BuildContext context) {
    if (!portrait) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _landscapeMaxWidth),
          child: _card(context),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final cardWidth = available * _portraitWidthFactor;
        final side = ((available - cardWidth) / 2).clamp(0.0, available);
        return Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 8),
          child: SizedBox(width: cardWidth, child: _card(context)),
        );
      },
    );
  }

  Widget _card(BuildContext context) {
    final colors = context.colors;
    return Container(
      key: const ValueKey('lane-cross-section-strip'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.mapPanelScrim.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _trackHeight,
            child: CustomPaint(
              painter: _CrossSectionPainter(
                crossSection: crossSection,
                expectedSideColor: colors.ok,
              ),
            ),
          ),
          const SizedBox(height: 6),
          _caption(context),
        ],
      ),
    );
  }

  Widget _caption(BuildContext context) {
    final colors = context.colors;
    final onDark = colors.onDark;
    final distance = crossSection.distanceFromCenterMeters;
    final distanceText =
        distance == null ? null : '中央線から ${distance.round()}m';

    final (String label, Color labelColor) = switch (crossSection.status) {
      ChannelCrossSectionStatus.unavailable => ('航路の外', onDark.withValues(alpha: 0.6)),
      ChannelCrossSectionStatus.distanceOnly => (
          '左右は方位が定まってから',
          onDark.withValues(alpha: 0.6),
        ),
      ChannelCrossSectionStatus.available =>
        crossSection.isInExpectedLane == true
            // 「正しい」ではなく事実だけを言う。レーン外が違反ではない以上、
            // レーン内を合格として演出しない。
            ? ('自分のレーン側', onDark)
            : ('対向レーン側にいます', colors.warning),
    };

    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.1,
              fontWeight: FontWeight.bold,
              color: labelColor,
            ),
          ),
        ),
        if (distanceText != null)
          Text(
            distanceText,
            style: TextStyle(
              fontSize: 13,
              height: 1.1,
              color: onDark.withValues(alpha: 0.75),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}

/// 断面の帯を描く。
///
/// 帯が表すのは**中央線からの距離だけ**で、岸は描かない
/// ([laneCrossSectionHalfWidthMeters] の説明を参照)。
class _CrossSectionPainter extends CustomPainter {
  final ChannelCrossSection crossSection;
  final Color expectedSideColor;

  const _CrossSectionPainter({
    required this.crossSection,
    required this.expectedSideColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(
      track,
      Paint()..color = Colors.white.withValues(alpha: 0.08),
    );

    final center = size.width / 2;

    // 入るべき側を淡く塗る。塗りの有無という二値にして、明度差を
    // 読み比べさせない(帯を廃止した理由と同じ: map_layer_spec.dart)。
    final expectedSide = crossSection.expectedSide;
    if (expectedSide != null) {
      final rect = expectedSide == RowerSide.left
          ? Rect.fromLTWH(0, 0, center, size.height)
          : Rect.fromLTWH(center, 0, center, size.height);
      canvas.save();
      canvas.clipRRect(track);
      canvas.drawRect(
        rect,
        Paint()..color = expectedSideColor.withValues(alpha: 0.28),
      );
      canvas.restore();
    }

    // 中央線。地図の白い破線と同じ見え方にして、両者を結びつける。
    canvas.drawLine(
      Offset(center, 2),
      Offset(center, size.height - 2),
      Paint()
        ..color = const Color(0xA6263238)
        ..strokeWidth = 5,
    );
    canvas.drawLine(
      Offset(center, 2),
      Offset(center, size.height - 2),
      Paint()
        ..color = const Color(0xF2FFFFFF)
        ..strokeWidth = 3,
    );

    final boatSide = crossSection.boatSide;
    final distance = crossSection.distanceFromCenterMeters;
    if (boatSide == null || distance == null) return;

    final halfWidth = size.width / 2;
    final ratio = distance / laneCrossSectionHalfWidthMeters;
    final beyondScale = ratio > 1;
    final offset = halfWidth * (ratio > 1 ? 1 : ratio);
    final dotX = boatSide == RowerSide.left ? center - offset : center + offset;
    final dotY = size.height / 2;

    if (beyondScale) {
      // 目盛りを振り切っていることを形で示す。端の丸印のままだと
      // 「岸に着いている」と読めてしまう。実距離は数値が持つ。
      final direction = boatSide == RowerSide.left ? -1.0 : 1.0;
      final tipX = (center + direction * halfWidth).clamp(0.0, size.width);
      final path = Path()
        ..moveTo(tipX, dotY)
        ..lineTo(tipX - direction * 10, dotY - 6)
        ..lineTo(tipX - direction * 10, dotY + 6)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(path, Paint()..color = BoatPalette.myBoat);
      return;
    }

    // 自艇は地図と同じ赤。ここだけで色を作らない(BoatPalette 参照)。
    final clampedX = dotX.clamp(6.0, size.width - 6);
    canvas.drawCircle(
      Offset(clampedX, dotY),
      7,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(clampedX, dotY),
      5,
      Paint()..color = BoatPalette.myBoat,
    );
  }

  @override
  bool shouldRepaint(_CrossSectionPainter oldDelegate) =>
      oldDelegate.crossSection.status != crossSection.status ||
      oldDelegate.crossSection.boatSide != crossSection.boatSide ||
      oldDelegate.crossSection.expectedSide != crossSection.expectedSide ||
      oldDelegate.crossSection.distanceFromCenterMeters !=
          crossSection.distanceFromCenterMeters ||
      oldDelegate.expectedSideColor != expectedSideColor;
}
