import 'dart:typed_data';

import 'storage_models.dart';

Future<StorageMediaLease> openStorageMedia(StorageFile file) async =>
    throw UnsupportedError('当前平台没有可预览的本地文件');

class StorageMediaLease {
  String get path => '';
  Future<Uint8List?> preview({int edge = 320}) async => null;
  Future<void> close() async {}
}
