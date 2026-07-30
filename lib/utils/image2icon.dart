import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/map_style_config.dart';

/// 艇首を上にした矢羽を、地図上の実寸に対応するBitmapDescriptorへ描画する。
/// [pixelsPerMeter] と [minPixels] は物理px単位で渡す。
Future<BitmapDescriptor> getBoatArrowBitmapDescriptor({
  required double lengthMeters,
  required double widthMeters,
  required Color color,
  required double pixelsPerMeter,
  required int minPixels,
}) async {
  final safeLength =
      lengthMeters.isFinite && lengthMeters > 0 ? lengthMeters : 1.0;
  final safeWidth = widthMeters.isFinite && widthMeters > 0 ? widthMeters : 1.0;
  final safePixelsPerMeter =
      pixelsPerMeter.isFinite && pixelsPerMeter > 0 ? pixelsPerMeter : 1.0;
  final targetLength = (safeLength * safePixelsPerMeter)
      .clamp(
        minPixels.toDouble(),
        double.infinity,
      )
      .toDouble();
  final scale = targetLength / (safeLength * safePixelsPerMeter);
  final targetWidth = safeWidth * safePixelsPerMeter * scale;
  final views = ui.PlatformDispatcher.instance.views;
  final devicePixelRatio = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
  final outline = boatArrowOutlineWidthLogicalPixels * devicePixelRatio;
  final width = (targetWidth + outline * 2).ceil().clamp(1, 2048).toInt();
  final height = (targetLength + outline * 2).ceil().clamp(1, 2048).toInt();
  final centerX = width / 2.0;
  final top = outline;
  final bottom = height - outline;
  final halfWidth = targetWidth / 2.0;
  final notchY = bottom - targetLength * boatArrowTailNotchRatio;
  final path = Path()
    ..moveTo(centerX, top)
    ..lineTo(centerX + halfWidth, top + targetLength * 0.58)
    ..lineTo(centerX + halfWidth, bottom)
    ..lineTo(centerX, notchY)
    ..lineTo(centerX - halfWidth, bottom)
    ..lineTo(centerX - halfWidth, top + targetLength * 0.58)
    ..close();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawPath(path, Paint()..color = color);
  canvas.drawPath(
    path,
    Paint()
      ..color = color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = outline,
  );
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width, height);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      return BitmapDescriptor.bytes(bytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

Future<BitmapDescriptor> getBitmapDescriptorFromAssetBytes(
    String path, int width) async {
  final ByteData data = await rootBundle.load(path);
  final codec = await ui.instantiateImageCodec(
    data.buffer.asUint8List(),
    targetWidth: width,
  );
  try {
    final frame = await codec.getNextFrame();
    try {
      final bytes =
          (await frame.image.toByteData(format: ui.ImageByteFormat.png))!
              .buffer
              .asUint8List();
      return BitmapDescriptor.bytes(bytes);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// 地図上へ常時表示する名前ラベルを生成する。
/// 下側を透明に空け、同じ座標に置いた艇アイコンの上へ表示する。
Future<BitmapDescriptor> getNameLabelBitmapDescriptor(String label) async {
  final textPainter = TextPainter(
    text: TextSpan(
      text: label,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 28,
        fontWeight: FontWeight.bold,
      ),
    ),
    maxLines: 1,
    ellipsis: '…',
    textDirection: ui.TextDirection.ltr,
  )..layout(maxWidth: 280);

  const horizontalPadding = 18.0;
  const verticalPadding = 10.0;
  const bottomPadding = 58.0;
  final width = (textPainter.width + horizontalPadding * 2).ceil();
  final labelHeight = textPainter.height + verticalPadding * 2;
  final height = (labelHeight + bottomPadding).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final labelRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, width.toDouble(), labelHeight),
    const Radius.circular(14),
  );
  canvas.drawRRect(labelRect, Paint()..color = const Color(0xD9002E4D));
  canvas.drawRRect(
    labelRect.deflate(1),
    Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );
  textPainter.paint(canvas, const Offset(horizontalPadding, verticalPadding));

  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width, height);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      return BitmapDescriptor.bytes(bytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
