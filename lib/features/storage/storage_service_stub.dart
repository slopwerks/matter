import 'storage_models.dart';
import 'storage_settings.dart';

class StorageService {
  Future<StorageSnapshot> scan() async => StorageSnapshot(
    files: const [],
    rooms: const {},
    measuredAt: DateTime.now(),
    warnings: const ['浏览器管理本地文件与缓存，请通过浏览器站点设置查看和清理。'],
  );
  Future<StorageCleanupResult> clean(StorageSelection selection) async =>
      const StorageCleanupResult(0, 0, 0, ['当前平台不支持磁盘清理']);
  Future<StorageCleanupResult> enforce(
    StorageSettings settings, {
    DateTime? now,
  }) async => const StorageCleanupResult(0, 0, 0, []);
}

final storageService = StorageService();
