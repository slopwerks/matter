import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../../pages/chat/prepared_media_source.dart';
import 'storage_models.dart';
import 'storage_registry.dart';

final _pending = <String, Future<void>>{};

Future<File> managedMediaFile(
  String account,
  String key,
  String filename,
) async {
  final root = await getTemporaryDirectory();
  final scope = sha256.convert(utf8.encode(account)).toString();
  final digest = sha256.convert(utf8.encode(key)).toString();
  final raw = filename.split('.').last.toLowerCase();
  final extension = RegExp(r'^[a-z0-9]{1,8}$').hasMatch(raw) ? raw : 'bin';
  return File(
    '${root.path}/matter_managed_media/$scope/$digest/source.$extension',
  );
}

Future<PreparedMediaSource?> cachedManagedMedia({
  required String account,
  required String key,
  required String filename,
  required StorageKind kind,
  StorageOwner? owner,
}) async {
  final file = await managedMediaFile(account, key, filename);
  final release = storageRegistry.pin(file.parent.path);
  try {
    if (!await file.exists() || await file.length() == 0) {
      release();
      return null;
    }
    await _record(file, kind, owner, filename);
    return PreparedMediaSource(
      media: Media(file.uri.toString()),
      cleanup: () async => release(),
      waveformFile: () async => file.path,
    );
  } catch (_) {
    release();
    rethrow;
  }
}

/// Publish only a completed/verified local file. The cache key is hashed and
/// scoped to the account; saved user downloads live outside this tree.
Future<PreparedMediaSource> prepareManagedMedia({
  required String account,
  required String key,
  required String filename,
  required StorageKind kind,
  StorageOwner? owner,
  required Future<PreparedMediaSource> Function() load,
}) async {
  final file = await managedMediaFile(account, key, filename);
  final release = storageRegistry.pin(file.parent.path);
  try {
    var pending = _pending[file.path];
    if (pending == null && (!await file.exists() || await file.length() == 0)) {
      // Recheck after async filesystem calls: only one writer publishes a key.
      pending = _pending[file.path];
      if (pending == null) {
        pending = _fill(file, load);
        _pending[file.path] = pending;
      }
    }
    if (pending != null) {
      try {
        await pending;
      } finally {
        if (identical(_pending[file.path], pending)) _pending.remove(file.path);
      }
    }
    await _record(file, kind, owner, filename);
    return PreparedMediaSource(
      media: Media(file.uri.toString()),
      cleanup: () async => release(),
      waveformFile: () async => file.path,
    );
  } catch (_) {
    release();
    rethrow;
  }
}

Future<void> clearManagedMediaAccount(String account) async {
  final root = await getTemporaryDirectory();
  final scope = sha256.convert(utf8.encode(account)).toString();
  final directory = Directory('${root.path}/matter_managed_media/$scope');
  final pending = _pending.entries
      .where((entry) => entry.key.startsWith('${directory.path}/'))
      .map(
        (entry) => entry.value.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      )
      .toList();
  await Future.wait(pending);
  if (!await directory.exists()) return;
  final canonical = await directory.resolveSymbolicLinks();
  await directory.delete(recursive: true);
  await storageRegistry.load();
  for (final path in storageRegistry.files.keys.toList()) {
    if (path.startsWith('$canonical${Platform.pathSeparator}')) {
      storageRegistry.forget(path);
    }
  }
  await storageRegistry.flush();
}

Future<void> _record(
  File file,
  StorageKind kind,
  StorageOwner? owner,
  String filename,
) async {
  try {
    await storageRegistry.record(
      file.path,
      kind,
      owners: [?owner],
      displayName: filename,
    );
  } catch (error) {
    debugPrint('Media attribution failed: $error');
  }
}

Future<Uint8List?> readManagedMediaBytes({
  required String account,
  required String key,
  required String filename,
  required StorageKind kind,
  required int maxBytes,
  StorageOwner? owner,
}) async {
  final source = await cachedManagedMedia(
    account: account,
    key: key,
    filename: filename,
    kind: kind,
    owner: owner,
  );
  if (source == null) return null;
  try {
    final uri = Uri.parse(source.media.uri);
    final file = File(
      uri.scheme == 'file' ? uri.toFilePath() : source.media.uri,
    );
    if (await file.length() > maxBytes) throw StateError('文件超过允许的大小');
    return await file.readAsBytes();
  } finally {
    await source.cleanup();
  }
}

Future<void> _fill(
  File file,
  Future<PreparedMediaSource> Function() load,
) async {
  final source = await load();
  try {
    final uri = Uri.parse(source.media.uri);
    final original = File(
      uri.scheme == 'file' ? uri.toFilePath() : source.media.uri,
    );
    if (!await original.exists() || await original.length() == 0) {
      throw StateError('下载文件不完整');
    }
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.part');
    try {
      await original.copy(partial.path);
      await partial.rename(file.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  } finally {
    await source.cleanup();
  }
}
