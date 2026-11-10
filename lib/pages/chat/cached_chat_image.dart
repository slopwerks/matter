import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_registry.dart';
import '../../providers/auth_provider.dart';
import '../../providers/authenticated_media_cache.dart';

/// Read a completed disk image without starting an HTTP refresh when automatic
/// downloads are disabled. A short lease protects the read from cleanup.
Future<Uint8List?> cachedChatImageBytes(
  WidgetRef ref,
  String url,
  String? roomId,
) async {
  final user = ref.read(currentUserProvider);
  if (user == null || kIsWeb) return null;
  try {
    final key = authenticatedMediaCacheKey(
      url: url,
      userId: user.id,
      homeserver: user.homeserver,
    );
    final manager =
        authenticatedMediaCacheManager(
          url: url,
          userId: user.id,
          homeserver: user.homeserver,
        ) ??
        CachedNetworkImageProvider.defaultCacheManager;
    final info = await manager.getFileFromCache(key ?? url);
    if (info == null) return null;
    final release = storageRegistry.pin(info.file.path);
    try {
      if (roomId != null) {
        storageRegistry.rememberSource(
          url,
          StorageOwner(storageAccountKey(user.id, user.homeserver), roomId),
        );
      }
      await storageRegistry.recordSource(
        url,
        info.file.path,
        StorageKind.image,
      );
      return await info.file.readAsBytes();
    } finally {
      release();
    }
  } catch (error) {
    debugPrint('Cached image read failed: $error');
    return null;
  }
}

/// Store original bytes without the image cache's static resize conversion.
Future<void> cacheChatImageBytes(
  WidgetRef ref,
  String url,
  Uint8List bytes,
  String? roomId,
) async {
  final user = ref.read(currentUserProvider);
  if (user == null || kIsWeb) return;
  final owner = roomId == null
      ? null
      : StorageOwner(storageAccountKey(user.id, user.homeserver), roomId);
  try {
    final key = authenticatedMediaCacheKey(
      url: url,
      userId: user.id,
      homeserver: user.homeserver,
    );
    final manager =
        authenticatedMediaCacheManager(
          url: url,
          userId: user.id,
          homeserver: user.homeserver,
        ) ??
        CachedNetworkImageProvider.defaultCacheManager;
    final file = await manager.putFile(url, bytes, key: key ?? url);
    final release = storageRegistry.pin(file.path);
    try {
      if (owner != null) storageRegistry.rememberSource(url, owner);
      await storageRegistry.recordSource(url, file.path, StorageKind.image);
    } finally {
      release();
    }
  } catch (error) {
    debugPrint('Image cache write failed: $error');
  }
}
