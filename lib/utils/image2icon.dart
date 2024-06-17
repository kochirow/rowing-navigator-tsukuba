import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Future<BitmapDescriptor> getBitmapDescriptorFromAssetBytes(
    String path, int width) async {
  final ByteData data = await rootBundle.load(path);
  ui.Codec codec = await ui.instantiateImageCodec(data.buffer.asUint8List(),
      targetWidth: width);
  ui.FrameInfo fi = await codec.getNextFrame();
  final bytes = (await fi.image.toByteData(format: ui.ImageByteFormat.png))!
      .buffer
      .asUint8List();
  return BitmapDescriptor.fromBytes(bytes);
}
