import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

Future<bool> openDownloadedFile({
  required String filename,
  required Uint8List bytes,
}) => saveDownloadedFile(filename: filename, bytes: bytes);

const supportsSaveAs = false;

Future<bool> saveDownloadedFile({
  required String filename,
  required Uint8List bytes,
  bool chooseLocation = false,
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
