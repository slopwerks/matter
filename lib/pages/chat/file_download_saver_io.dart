import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _fileSaveChannel = MethodChannel('moe.aks.matter/file_saver');

Future<bool> saveDownloadedFile({
  required String filename,
  required Uint8List bytes,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    final location = await getSaveLocation(suggestedName: filename);
    if (location == null) return false;
    await XFile.fromData(
      bytes,
      name: filename,
      mimeType: 'application/octet-stream',
    ).saveTo(location.path);
    return true;
  }

  final cacheDirectory = await getTemporaryDirectory();
  final downloadDirectory = Directory(
    '${cacheDirectory.path}/matter_downloads',
  );
  await downloadDirectory.create(recursive: true);
  final operationDirectory = Directory(
    '${downloadDirectory.path}/${DateTime.now().microsecondsSinceEpoch}',
  );
  await operationDirectory.create();
  final file = File('${operationDirectory.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  try {
    return await _fileSaveChannel.invokeMethod<bool>('saveFile', {
          'path': file.path,
        }) ??
        false;
  } finally {
    if (await operationDirectory.exists()) {
      await operationDirectory.delete(recursive: true);
    }
  }
}
