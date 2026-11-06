import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/storage/storage_settings.dart';
import '../../features/storage/storage_locations.dart';

import 'package:url_launcher/url_launcher.dart';

const _fileSaveChannel = MethodChannel('moe.aks.matter/file_saver');

Future<bool> openDownloadedFile({
  required String filename,
  required Uint8List bytes,
}) async {
  final cache = await getTemporaryDirectory();
  final root = Directory('${cache.path}/matter_open_files');
  await root.create(recursive: true);
  final directory = await root.createTemp('open-');
  try {
    final file = File('${directory.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    final bool opened;
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      opened =
          await _fileSaveChannel.invokeMethod<bool>('openFile', {
            'path': file.path,
          }) ??
          false;
    } else {
      opened = await launchUrl(
        Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      );
    }
    if (!opened) await directory.delete(recursive: true);
    return opened;
  } catch (_) {
    if (await directory.exists()) await directory.delete(recursive: true);
    rethrow;
  }
}

bool get supportsSaveAs => switch (defaultTargetPlatform) {
  TargetPlatform.linux ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => true,
  _ => false,
};

Future<bool> saveDownloadedFile({
  required String filename,
  required Uint8List bytes,
  bool chooseLocation = false,
}) async {
  final settings = await loadStorageSettings();
  chooseLocation = chooseLocation || settings.askSaveLocation;
  if (!Platform.isAndroid && !Platform.isIOS) {
    if (chooseLocation) {
      final location = await getSaveLocation(suggestedName: filename);
      if (location == null) return false;
      await File(location.path).writeAsBytes(bytes, flush: true);
      return true;
    }
    final directory = settings.downloadDirectory == null
        ? await getDownloadsDirectory()
        : Directory(settings.downloadDirectory!);
    if (directory == null) throw const FileSystemException('无法获取下载目录');
    await directory.create(recursive: true);
    final dot = filename.lastIndexOf('.');
    final stem = dot > 0 ? filename.substring(0, dot) : filename;
    final extension = dot > 0 ? filename.substring(dot) : '';
    for (var copy = 0; ; copy++) {
      final name = copy == 0 ? filename : '$stem ($copy)$extension';
      final file = File('${directory.path}/$name');
      try {
        await file.create(exclusive: true);
      } on FileSystemException {
        if (await FileSystemEntity.type(file.path) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        rethrow;
      }
      try {
        await file.writeAsBytes(bytes, flush: true);
      } catch (_) {
        await file.delete();
        rethrow;
      }
      return true;
    }
  }

  final cacheDirectory = await getTemporaryDirectory();
  final downloadDirectory = Directory(
    '${cacheDirectory.path}/matter_downloads',
  );
  await downloadDirectory.create(recursive: true);
  final operationDirectory = await downloadDirectory.createTemp('download-');
  final file = File('${operationDirectory.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  try {
    var directory = settings.downloadDirectory;
    if (Platform.isAndroid && chooseLocation) {
      final selected = await chooseDownloadDirectory();
      if (selected == null) return false;
      directory = selected.path;
    }
    return await _fileSaveChannel.invokeMethod<bool>('saveFile', {
          'path': file.path,
          'directory': ?directory,
        }) ??
        false;
  } finally {
    if (await operationDirectory.exists()) {
      await operationDirectory.delete(recursive: true);
    }
  }
}
