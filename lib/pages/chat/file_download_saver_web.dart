import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

Future<bool> saveDownloadedFile({
  required String filename,
  required Uint8List bytes,
}) async {
  final location = await getSaveLocation(suggestedName: filename);
  if (location == null) return false;
  await XFile.fromData(
    bytes,
    name: filename,
    mimeType: 'application/octet-stream',
  ).saveTo(location.path);
  return true;
}
