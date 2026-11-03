import 'dart:typed_data';

Future<bool> openDownloadedFile({
  required String filename,
  required Uint8List bytes,
}) => throw UnsupportedError('Opening downloaded files is not supported.');

const supportsSaveAs = false;

Future<bool> saveDownloadedFile({
  required String filename,
  required Uint8List bytes,
  bool chooseLocation = false,
}) => throw UnsupportedError('Saving downloaded files is not supported.');
