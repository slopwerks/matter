import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

const _storage = MethodChannel('moe.aks.matter/storage');
bool get supportsPersistentDownloadDirectory => !Platform.isIOS;

Future<({String path, String label})?> chooseDownloadDirectory() async {
  if (Platform.isAndroid) {
    final result = await _storage.invokeMapMethod<String, dynamic>(
      'chooseDirectory',
    );
    if (result == null) return null;
    return (path: result['path'] as String, label: result['label'] as String);
  }
  if (Platform.isIOS) return null;
  final path = await getDirectoryPath(confirmButtonText: '保存到此目录');
  return path == null ? null : (path: path, label: path);
}
