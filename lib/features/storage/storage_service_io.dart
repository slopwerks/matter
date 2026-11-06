import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'storage_models.dart';
import 'storage_policy.dart';
import 'storage_registry.dart';
import 'storage_settings.dart';

const storagePlatformChannel = MethodChannel('moe.aks.matter/storage');

class StorageRoot {
  final String path;
  final bool temporary;
  const StorageRoot(this.path, {this.temporary = false});
}

class StorageService {
  final StorageRegistry registry;
  final Future<List<StorageRoot>> Function()? roots;
  Future<void> _operation = Future.value();
  StorageService({StorageRegistry? registry, this.roots})
    : registry = registry ?? storageRegistry;

  Future<T> _serial<T>(Future<T> Function() run) {
    final result = _operation.catchError((Object _) {}).then((_) => run());
    _operation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<StorageSnapshot> scan() => _serial(_scan);

  Future<StorageSnapshot> _scan() async {
    await registry.load();
    final warnings = <String>[];
    final native = <String, dynamic>{};
    if (roots == null && Platform.isAndroid) {
      try {
        native.addAll(
          await storagePlatformChannel.invokeMapMethod<String, dynamic>(
                'usage',
              ) ??
              {},
        );
      } on PlatformException catch (error) {
        warnings.add('系统用量读取失败：${error.message}');
      } on MissingPluginException {
        warnings.add('当前版本未提供系统用量接口');
      }
    }
    final directories = roots != null
        ? await roots!()
        : await _defaultRoots(native);
    final canonicalRoots = <StorageRoot>[];
    for (final root in directories) {
      try {
        final directory = Directory(root.path);
        if (await directory.exists()) {
          final path = await directory.resolveSymbolicLinks();
          if (!canonicalRoots.any((r) => r.path == path)) {
            canonicalRoots.add(StorageRoot(path, temporary: root.temporary));
          }
        }
      } on FileSystemException catch (error) {
        warnings.add(
          '目录不可读：${root.path} (${error.osError?.message ?? error.message})',
        );
      }
    }
    // Most specific roots win, so temp inside an application container keeps
    // its cache classification. Physical paths are counted only once.
    canonicalRoots.sort((a, b) => b.path.length.compareTo(a.path.length));
    final seen = <String>{};
    final files = <StorageFile>[];
    for (final root in canonicalRoots) {
      try {
        await for (final entity in Directory(
          root.path,
        ).list(recursive: true, followLinks: false)) {
          if (entity is! File || !seen.add(entity.path)) continue;
          try {
            final stat = await entity.stat();
            if (stat.type != FileSystemEntityType.file) continue;
            final relative = entity.path
                .substring(root.path.length + 1)
                .replaceAll('\\', '/');
            final metadata = registry.files[entity.path];
            final classification = classifyStorageFile(
              relative,
              temporary: root.temporary,
            );
            var kind = metadata?.kind ?? classification.$1;
            if (metadata == null &&
                classification.$2 &&
                kind == StorageKind.document &&
                (relative.endsWith('.bin') ||
                    !relative.split('/').last.contains('.'))) {
              kind = await _identifyMedia(entity) ?? kind;
            }
            final grace =
                relative.startsWith('matter_open_files/') ||
                relative.startsWith('updates/') ||
                relative.startsWith('matter_downloads/');
            final recent =
                DateTime.now().difference(stat.modified) <
                const Duration(hours: 24);
            files.add(
              StorageFile(
                path: entity.path,
                bytes: stat.size,
                modified: stat.modified,
                lastUsed: metadata?.used ?? stat.modified,
                kind: kind,
                cleanable: classification.$2,
                busy: registry.isBusy(entity.path) || (grace && recent),
                owners: metadata?.owners.values.toList() ?? const [],
                displayName: metadata?.displayName,
                usageEstimated: metadata?.usageEstimated ?? true,
              ),
            );
          } on FileSystemException catch (error) {
            if (await entity.exists()) {
              warnings.add('文件读取失败：${entity.path} (${error.message})');
            }
          }
        }
      } on FileSystemException catch (error) {
        warnings.add('目录扫描未完成：${root.path} (${error.message})');
      }
    }
    // Remove obsolete metadata only for paths actually covered by this scan.
    // A failed/partial scan must not destroy attribution for unreadable roots.
    if (warnings.isEmpty) {
      for (final path in registry.files.keys.toList()) {
        if (canonicalRoots.any((root) => _inside(path, root.path)) &&
            !seen.contains(path)) {
          registry.forget(path);
        }
      }
    }
    return StorageSnapshot(
      files: files,
      rooms: Map.of(registry.rooms),
      warnings: warnings,
      measuredAt: DateTime.now(),
      systemDataBytes: (native['dataBytes'] as num?)?.toInt(),
      systemCacheBytes: (native['cacheBytes'] as num?)?.toInt(),
      appBytes: (native['appBytes'] as num?)?.toInt(),
      freeBytes: (native['freeBytes'] as num?)?.toInt(),
      volumeBytes: (native['volumeBytes'] as num?)?.toInt(),
    );
  }

  Future<StorageCleanupResult> clean(StorageSelection selection) =>
      _serial(() async {
        final snapshot = await _scan();
        return _delete(
          snapshot.files.where(
            (f) => selection.matches(f, snapshot.rooms, includeBusy: true),
          ),
        );
      });

  Future<StorageCleanupResult> _delete(Iterable<StorageFile> files) async {
    var released = 0;
    var removed = 0;
    var skipped = 0;
    final errors = <String>[];
    for (final entry in files) {
      if (!entry.cleanable || entry.busy || registry.isBusy(entry.path)) {
        skipped++;
        continue;
      }
      final file = File(entry.path);
      try {
        // Re-check links and identity immediately before deletion. Do not
        // follow symlinks or remove a replacement downloaded since the scan.
        if (await FileSystemEntity.type(entry.path, followLinks: false) !=
            FileSystemEntityType.file) {
          skipped++;
          continue;
        }
        final resolved = await file.resolveSymbolicLinks();
        final stat = await file.stat();
        if (resolved != file.absolute.path ||
            stat.size != entry.bytes ||
            stat.modified != entry.modified ||
            registry.isBusy(entry.path)) {
          skipped++;
          continue;
        }
        await file.delete();
        registry.forget(entry.path);
        released += stat.size;
        removed++;
      } on FileSystemException catch (error) {
        errors.add('${entry.path}: ${error.message}');
      }
    }
    await registry.flush();
    return StorageCleanupResult(released, removed, skipped, errors);
  }

  Future<StorageCleanupResult> enforce(
    StorageSettings settings, {
    DateTime? now,
  }) => _serial(() async {
    final snapshot = await _scan();
    final candidates =
        snapshot.files.where((f) => f.cleanable && !f.busy).toList()
          ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    final selected = selectPolicyEvictions(snapshot, settings, now: now);
    return _delete(candidates.where((f) => selected.contains(f.path)));
  });
}

Future<List<StorageRoot>> _defaultRoots(Map<String, dynamic> native) async {
  final temporary = await getTemporaryDirectory();
  final support = await getApplicationSupportDirectory();
  final documents = Platform.isAndroid || Platform.isIOS
      ? await getApplicationDocumentsDirectory()
      : null;
  final cache = await getApplicationCacheDirectory();
  return [
    StorageRoot(temporary.path, temporary: true),
    StorageRoot(cache.path, temporary: true),
    StorageRoot(support.path),
    if (documents != null) StorageRoot(documents.path),
    for (final path in (native['cacheRoots'] as List? ?? const []))
      StorageRoot(path as String, temporary: true),
    for (final path in (native['dataRoots'] as List? ?? const []))
      StorageRoot(path as String),
  ];
}

bool _inside(String path, String root) =>
    path.startsWith('$root${Platform.pathSeparator}');

(StorageKind, bool) classifyStorageFile(
  String relative, {
  required bool temporary,
}) {
  final path = relative.toLowerCase();
  final name = path.split('/').last;
  if (path.contains('search_index/')) return (StorageKind.search, false);
  if (name.endsWith('.db') ||
      name.endsWith('.sqlite') ||
      name.endsWith('.sqlite3') ||
      name.endsWith('-wal') ||
      name.endsWith('-shm') ||
      name.endsWith('-journal')) {
    return (StorageKind.database, false);
  }
  if (!temporary) {
    if (path.startsWith('matter_push_avatars/')) {
      return (StorageKind.image, true);
    }
    if (name.endsWith('.json') ||
        name.endsWith('.xml') ||
        name.endsWith('.plist') ||
        path.contains('preferences/')) {
      return (StorageKind.settings, false);
    }
    return (StorageKind.other, false);
  }
  if (path.startsWith('updates/')) return (StorageKind.update, true);
  if (path.startsWith('matter_managed_media/')) {
    return (_kindForExtension(name), true);
  }
  if (path.startsWith('matter_audio_cache/')) return (StorageKind.audio, true);
  if (path.startsWith('libcachedimagedata/') ||
      path.startsWith('matter-auth-media-')) {
    return (StorageKind.image, true);
  }
  if (path.startsWith('matter_decrypted_media/') ||
      path.startsWith('matter_open_files/') ||
      path.startsWith('matter_downloads/')) {
    return (_kindForExtension(name), true);
  }
  // Unknown temporary files may belong to an active picker/upload or native
  // plugin. Count them, but never guess that they can be removed safely.
  return (StorageKind.temporary, false);
}

StorageKind _kindForExtension(String name) {
  final ext = name.split('.').last;
  if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'heic'].contains(ext)) {
    return StorageKind.image;
  }
  if (['mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp'].contains(ext)) {
    return StorageKind.video;
  }
  if (['mp3', 'm4a', 'ogg', 'opus', 'wav', 'aac', 'flac'].contains(ext)) {
    return StorageKind.audio;
  }
  return StorageKind.document;
}

Future<StorageKind?> _identifyMedia(File file) async {
  RandomAccessFile? input;
  try {
    input = await file.open();
    final h = await input.read(32);
    bool starts(List<int> signature) =>
        h.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => h[i] == signature[i],
        ).every((v) => v);
    if (starts([0xff, 0xd8, 0xff]) ||
        starts([0x89, 0x50, 0x4e, 0x47]) ||
        starts([0x47, 0x49, 0x46, 0x38]) ||
        (h.length >= 12 && String.fromCharCodes(h.sublist(8, 12)) == 'WEBP')) {
      return StorageKind.image;
    }
    if (h.length >= 12 && String.fromCharCodes(h.sublist(4, 8)) == 'ftyp') {
      final brand = String.fromCharCodes(h.sublist(8, 12));
      return ['avif', 'avis', 'heic', 'heix', 'mif1'].contains(brand)
          ? StorageKind.image
          : StorageKind.video;
    }
    if (starts([0x1a, 0x45, 0xdf, 0xa3])) return StorageKind.video;
    if (starts([0x49, 0x44, 0x33]) || starts([0x66, 0x4c, 0x61, 0x43])) {
      return StorageKind.audio;
    }
  } on FileSystemException {
    // An unreadable or incomplete historical file keeps its extension category.
  } finally {
    await input?.close();
  }
  return null;
}

final storageService = StorageService();
