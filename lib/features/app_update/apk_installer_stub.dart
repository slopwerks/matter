import 'update_exception.dart';

Future<String> downloadAndroidApk({
  required Uri uri,
  required String fileName,
  required int expectedSize,
  required String? digest,
  required void Function(int received, int total) onProgress,
  Future<void>? cancel,
}) => throw const AppUpdateException('当前平台暂不支持应用内更新');

Future<void> installAndroidApk(String path) =>
    throw const AppUpdateException('当前平台暂不支持应用内更新');
