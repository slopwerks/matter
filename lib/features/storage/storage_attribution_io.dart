import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import '../../pages/chat/attachment_media_utils.dart'
    show resolveAttachmentMime;
import '../../providers/authenticated_media_cache.dart';
import '../../providers/chat_provider.dart' show loadCachedMxcUrls;
import '../../providers/message_cache_persistence.dart';
import '../../src/rust/api/matrix.dart' show ChatMessage, MessageType;
import '../../src/rust/api/matrix/storage.dart' as history;
import '../../src/rust/frb_generated.dart' show RustLib;
import 'managed_media_io.dart' show managedMediaFile;
import 'storage_models.dart';
import 'storage_path_io.dart';
import 'storage_registry.dart';

class _Reference {
  final StorageKind kind;
  String? filename;
  final owners = <String, StorageOwner>{};
  _Reference(this.kind, this.filename);
  void add(_Reference other) {
    owners.addAll(other.owners);
    filename ??= other.filename;
  }
}

/// Reconcile existing files against SDK history, saved messages and cache
/// metadata. Never resolve, download, play, decrypt, or refresh last-use here.
Future<void> restoreStorageAttribution({
  required String userId,
  required String homeserver,
  StorageRegistry? registry,
}) async {
  registry ??= storageRegistry;
  await registry.load();
  final account = storageAccountKey(userId, homeserver);
  final resolutions = await loadCachedMxcUrls(userId);
  final rooms = <String, List<ChatMessage>>{};
  Object? historyError;
  StackTrace? historyStack;
  if (RustLib.instance.initialized) {
    try {
      rooms.addAll(
        await history.getCachedMediaMessages(expectedUserId: userId),
      );
    } catch (error, stack) {
      historyError = error;
      historyStack = stack;
    }
  }
  for (final roomId in await cachedMessageRoomIds(userId)) {
    rooms[roomId] = [
      ...?rooms[roomId],
      ...await loadCachedMessages(namespace: userId, roomId: roomId),
    ];
  }
  final managed = <String, _Reference>{};
  final audio = <String, _Reference>{};
  final imageSources = <String, _Reference>{};
  final images = <CacheManager, Map<String, _Reference>>{};
  for (final room in rooms.entries) {
    for (final message in room.value) {
      final kind = switch (message.msgType) {
        MessageType.image || MessageType.sticker => StorageKind.image,
        MessageType.video => StorageKind.video,
        MessageType.file =>
          resolveAttachmentMime(
                    message.filename ?? message.content,
                    message.mimeType,
                  )?.startsWith('audio/') ==
                  true
              ? StorageKind.audio
              : StorageKind.document,
        _ => null,
      };
      if (kind == null) continue;
      final key = message.mediaSourceJson ?? message.imageUrl;
      if (key == null || key.isEmpty) continue;
      final reference = _Reference(kind, message.filename);
      final owner = StorageOwner(account, room.key);
      reference.owners[owner.key] = owner;
      (managed[key] ??= _Reference(kind, message.filename)).add(reference);
      var source = message.imageUrl;
      dynamic decoded;
      if (message.mediaSourceJson != null) {
        try {
          decoded = jsonDecode(message.mediaSourceJson!);
          if (decoded is String) source = decoded;
          if (decoded is Map && decoded['url'] is String) {
            source = decoded['url'] as String;
          }
        } on FormatException {
          continue;
        }
      }
      final encrypted = decoded is Map && decoded.containsKey('file');
      // Plain MXC keys also existed before media-source JSON was available.
      if (!encrypted && source != null) {
        (managed[source] ??= _Reference(kind, message.filename)).add(reference);
      }
      if (kind == StorageKind.audio && (encrypted || source != null)) {
        final audioKey = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  encrypted ? 'encrypted' : 'plain',
                  encrypted ? decoded : source,
                ]),
              ),
            )
            .toString();
        (audio[audioKey] ??= _Reference(kind, message.filename)).add(reference);
      }
      if (kind != StorageKind.image || encrypted || source == null) continue;
      (imageSources[source] ??= _Reference(
        kind,
        message.filename,
      )).add(reference);
      final urls = <String>{
        if (source.startsWith('https://') || source.startsWith('http://'))
          source,
        for (final entry in resolutions.entries)
          if (entry.key == source ||
              (entry.key.startsWith('$source|') &&
                  RegExp(r'^\|(?:original|\d+x\d+)$')
                      .hasMatch(entry.key.substring(source.length))))
            entry.value,
      };
      for (final url in urls) {
        final cacheKey = authenticatedMediaCacheKey(
          url: url,
          userId: userId,
          homeserver: homeserver,
        );
        final manager =
            authenticatedMediaCacheManager(
              url: url,
              userId: userId,
              homeserver: homeserver,
            ) ??
            CachedNetworkImageProvider.defaultCacheManager;
        if (manager is! CacheManager) continue;
        final keys = images.putIfAbsent(manager, () => {});
        (keys[cacheKey ?? url] ??= _Reference(
          kind,
          message.filename,
        )).add(reference);
      }
    }
  }
  if (imageSources.isNotEmpty) {
    // Cache records retain the requested Matrix URL even when the bounded
    // MXC -> HTTP preference map has evicted that image or thumbnail.
    for (final manager in [
      CachedNetworkImageProvider.defaultCacheManager,
      authenticatedMediaCacheManager(
        url:
            '${homeserver.replaceFirst(RegExp(r'/+$'), '')}/_matrix/client/v1/media/download',
        userId: userId,
        homeserver: homeserver,
      ),
    ]) {
      if (manager is CacheManager) images.putIfAbsent(manager, () => {});
    }
  }
  Future<void> attribute(File file, _Reference reference) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return;
    }
    try {
      final stat = await file.stat();
      if (stat.size == 0) return;
      await registry!.attribute(
        file.path,
        reference.kind,
        stat.modified,
        reference.owners.values,
        displayName: reference.filename,
      );
    } on FileSystemException {
      // Cleanup or an OS cache eviction may remove a file during recovery.
    }
  }

  for (final entry in managed.entries) {
    final directory = (await managedMediaFile(
      account,
      entry.key,
      'source.bin',
    )).parent;
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      continue;
    }
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          entity.uri.pathSegments.last.startsWith('source.') &&
          !entity.path.endsWith('.part')) {
        await attribute(entity, entry.value);
      }
    }
  }
  if (audio.isNotEmpty) {
    final temporary = await getTemporaryDirectory();
    final directory = Directory(
      '${temporary.path}/matter_audio_cache/$account',
    );
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await for (final child in directory.list(followLinks: false)) {
        if (child is! Directory) continue;
        try {
          final marker = File('${child.path}/ready.json');
          final file = File('${child.path}/data.bin');
          if (await FileSystemEntity.type(marker.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              await FileSystemEntity.type(file.path, followLinks: false) !=
                  FileSystemEntityType.file) {
            continue;
          }
          final metadata =
              jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
          final reference = audio[metadata['key']];
          if (reference == null) continue;
          final length = await file.length();
          if (length == 0 || length != metadata['bytes']) continue;
          final old = registry.files[storagePathKey(file.path)];
          final needsOwners =
              old == null ||
              reference.owners.keys.any(
                (owner) => !old.owners.containsKey(owner),
              );
          if (needsOwners &&
              (await sha256.bind(file.openRead()).first).toString() !=
                  metadata['sha256']) {
            continue;
          }
          await attribute(file, reference);
          await attribute(marker, reference);
        } on FileSystemException {
          // A cache eviction may remove a completed entry during recovery.
        } on FormatException {
          // Incomplete/corrupt markers do not establish media identity.
        } on TypeError {
          // Older or invalid metadata is left unassigned.
        }
      }
    }
  }
  for (final entry in images.entries) {
    final manager = entry.key;
    await manager.config.repo.open();
    try {
      for (final object in await manager.config.repo.getAllObjects()) {
        final key = object.key.replaceFirst(
          RegExp(r'^resized(?:_w\d+)?(?:_h\d+)?_'),
          '',
        );
        final reference =
            entry.value[key] ??
            imageSources[object.url] ??
            imageSources[_mxcFromCacheUrl(object.url)];
        if (reference == null) continue;
        final file = await manager.config.fileSystem.createFile(
          object.relativePath,
        );
        await attribute(File(file.path), reference);
      }
    } finally {
      await manager.config.repo.close();
    }
  }
  await registry.flush();
  if (historyError != null) {
    Error.throwWithStackTrace(historyError, historyStack!);
  }
}

String? _mxcFromCacheUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final parts = uri.pathSegments;
  final operation =
      parts.length >= 7 &&
          parts[0] == '_matrix' &&
          parts[1] == 'client' &&
          parts[3] == 'media'
      ? 4
      : parts.length >= 6 && parts[0] == '_matrix' && parts[1] == 'media'
      ? 3
      : -1;
  if (operation < 0 ||
      (parts[operation] != 'download' && parts[operation] != 'thumbnail')) {
    return null;
  }
  return 'mxc://${parts[operation + 1]}/${parts[operation + 2]}';
}
