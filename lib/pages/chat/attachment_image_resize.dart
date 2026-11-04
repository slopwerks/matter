import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

/// Desktop has no flutter_image_compress implementation. Decode at the bounded
/// size with Flutter, then keep JPEG encoding off the UI isolate.
Future<Uint8List> resizeAttachmentJpeg(
  Uint8List bytes, {
  required int width,
  required int height,
  required int quality,
}) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: width,
    targetHeight: height,
  );
  ui.Image? frame;
  try {
    frame = (await codec.getNextFrame()).image;
    final pixels = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (pixels == null) throw StateError('无法读取图片像素');
    return await compute(_encodeJpeg, (
      pixels.buffer.asUint8List(),
      frame.width,
      frame.height,
      quality,
    ));
  } finally {
    frame?.dispose();
    codec.dispose();
  }
}

Uint8List _encodeJpeg((Uint8List, int, int, int) input) => image.encodeJpg(
  image.Image.fromBytes(
    width: input.$2,
    height: input.$3,
    bytes: input.$1.buffer,
    numChannels: 4,
  ),
  quality: input.$4,
);
