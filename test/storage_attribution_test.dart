import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/managed_media_io.dart'
    show managedMediaFile;
import 'package:matter/features/storage/storage_attribution.dart';
import 'package:matter/features/storage/storage_breakdown.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_providers.dart';
import 'package:matter/features/storage/storage_registry.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' show ChatRoom;
import 'package:matter/providers/authenticated_media_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('matter-storage-attribution-');
    installTempPathProvider(root);
  });
  tearDown(() async {
    await resetAuthenticatedMediaCacheManagers();
    await root.delete(recursive: true);
  });

  test(
    'chat attribution separates public application data from unknown media',
    () {
      final now = DateTime(2026, 11, 4);
      const owner = StorageOwner('account', '!room');
      StorageFile file(
        String path,
        StorageKind kind,
        int bytes, {
        bool owned = false,
      }) => StorageFile(
        path: path,
        bytes: bytes,
        modified: now,
        lastUsed: now,
        kind: kind,
        cleanable: kind != StorageKind.database,
        owners: owned ? const [owner] : const [],
      );
      final snapshot = StorageSnapshot(
        files: [
          file('/cache/photo.jpg', StorageKind.image, 10, owned: true),
          file('/cache/old.mp4', StorageKind.video, 20),
          file('/data/matrix.db', StorageKind.database, 300),
        ],
        rooms: {
          owner.key: const StorageRoom(owner, 'Room', StorageChatType.group),
        },
        measuredAt: now,
      );
      final buckets = storageBreakdown(snapshot, byChat: true);
      expect(
        buckets.singleWhere((b) => b.chatType == StorageChatType.unknown).bytes,
        20,
      );
      expect(buckets.singleWhere((b) => b.applicationData).bytes, 300);
      expect(
        buckets.fold<int>(0, (sum, b) => sum + b.bytes),
        snapshot.totalBytes,
      );
    },
  );

  test('local message recovery merges shared encrypted media without downloads or LRU refresh', () async {
    const user = '@alice:example.org', server = 'https://example.org';
    final account = storageAccountKey(user, server);
    final source = jsonEncode({
      'file': {
        'url': 'mxc://example.org/encrypted',
        'key': {'k': 'private-test-key'},
      },
    });
    final prefs = await SharedPreferences.getInstance();
    final message = {
      'id': 'media',
      'msgType': 'file',
      'mediaSourceJson': source,
      'mimeType': 'audio/ogg',
      'filename': '语音.ogg',
    };
    await prefs.setString('msg_cache_v2_$user::!a', jsonEncode([message]));
    await prefs.setString(
      'msg_cache_v2_$user::!b',
      jsonEncode([
        message,
        {
          'id': 'missing',
          'msgType': 'video',
          'imageUrl': 'mxc://example.org/missing',
        },
      ]),
    );
    await prefs.setString(
      'msg_cache_v2_@other:example.org::!other',
      jsonEncode([message]),
    );
    final file = await managedMediaFile(account, source, '语音.ogg');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    final used = DateTime(2020, 1, 1);
    await file.setLastModified(used);
    final other = await managedMediaFile(
      storageAccountKey('@other:example.org', server),
      source,
      '语音.ogg',
    );
    await other.parent.create(recursive: true);
    await other.writeAsBytes([9]);
    final orphan = await managedMediaFile(
      account,
      'orphan-with-no-message',
      'old.mp4',
    );
    await orphan.parent.create(recursive: true);
    await orphan.writeAsBytes([7]);
    final registry = StorageRegistry();
    var downloads = 0;
    await HttpOverrides.runZoned(
      () => restoreStorageAttribution(
        userId: user,
        homeserver: server,
        registry: registry,
      ),
      createHttpClient: (_) {
        downloads++;
        throw StateError('Recovery must not download');
      },
    );
    expect(downloads, 0);
    expect(registry.files.keys, [file.path]);
    final metadata = registry.files[file.path]!;
    expect(metadata.owners.keys.toSet(), {
      StorageOwner(account, '!a').key,
      StorageOwner(account, '!b').key,
    });
    expect(metadata.kind, StorageKind.audio);
    expect(metadata.displayName, '语音.ogg');
    expect(metadata.used, used);
    expect(metadata.usageEstimated, isTrue);
    expect(
      StorageSelection(rooms: {StorageOwner(account, '!a').key}).matches(
        StorageFile(
          path: file.path,
          bytes: 3,
          modified: used,
          lastUsed: used,
          kind: metadata.kind,
          cleanable: true,
          owners: metadata.owners.values.toList(),
        ),
        {},
      ),
      isFalse,
    );
    final before = prefs.getString('storage_file_index_v1');
    await restoreStorageAttribution(
      userId: user,
      homeserver: server,
      registry: registry,
    );
    expect(prefs.getString('storage_file_index_v1'), before);
    expect(before, isNot(contains('private-test-key')));
    expect(before, isNot(contains('mxc://')));
    final restored = StorageRegistry();
    await restored.load();
    expect(restored.files[file.path]!.used, used);
    expect(restored.files[file.path]!.owners.length, 2);
    expect(await other.readAsBytes(), [9]);
  });

  test('image recovery uses real account and resized cache keys and leaves public images alone', () async {
    const user = '@alice:example.org', server = 'https://example.org';
    const mxc = 'mxc://example.org/photo';
    const url = '$server/_matrix/client/v1/media/download/example.org/photo';
    const thumb =
        '$server/_matrix/client/v1/media/thumbnail/example.org/photo?width=320&height=320';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'msg_cache_v2_$user::!a',
      jsonEncode([
        {
          'id': 'image',
          'msgType': 'image',
          'imageUrl': mxc,
          'filename': '照片.jpg',
        },
      ]),
    );
    await prefs.setString(
      'mxc_http_cache_v1_$user',
      jsonEncode({mxc: url, '$mxc|320x320': thumb}),
    );
    final manager =
        authenticatedMediaCacheManager(
              url: url,
              userId: user,
              homeserver: server,
            )!
            as CacheManager;
    final key = authenticatedMediaCacheKey(
      url: url,
      userId: user,
      homeserver: server,
    )!;
    final thumbKey = authenticatedMediaCacheKey(
      url: thumb,
      userId: user,
      homeserver: server,
    )!;
    final original = await manager.putFile(
      url,
      Uint8List.fromList([1, 2]),
      key: key,
    );
    final resized = await manager.putFile(
      url,
      Uint8List.fromList([3]),
      key: 'resized_${'w160'}_${'h160'}_$key',
    );
    final thumbnail = await manager.putFile(
      thumb,
      Uint8List.fromList([4]),
      key: thumbKey,
    );
    final avatar = await manager.putFile(
      '$server/avatar',
      Uint8List.fromList([5]),
      key: 'public-avatar',
    );
    final other =
        authenticatedMediaCacheManager(
              url: url,
              userId: '@bob:example.org',
              homeserver: server,
            )!
            as CacheManager;
    final otherFile = await other.putFile(
      url,
      Uint8List.fromList([6]),
      key: authenticatedMediaCacheKey(
        url: url,
        userId: '@bob:example.org',
        homeserver: server,
      ),
    );
    final publicManager = CacheManager(Config('recovery-public-images'));
    final previous = CachedNetworkImageProvider.defaultCacheManager;
    CachedNetworkImageProvider.defaultCacheManager = publicManager;
    addTearDown(() async {
      CachedNetworkImageProvider.defaultCacheManager = previous;
      await publicManager.dispose();
    });
    final connections = (manager.config.repo as dynamic).openConnections;
    final touched = {
      for (final object in await manager.config.repo.getAllObjects())
        object.key: object.touched,
    };
    final registry = StorageRegistry();
    await restoreStorageAttribution(
      userId: user,
      homeserver: server,
      registry: registry,
    );
    expect(registry.files.keys.toSet(), {
      original.path,
      resized.path,
      thumbnail.path,
    });
    expect(registry.files.containsKey(avatar.path), isFalse);
    expect(registry.files.containsKey(otherFile.path), isFalse);
    expect({
      for (final object in await manager.config.repo.getAllObjects())
        object.key: object.touched,
    }, touched);
    for (final metadata in registry.files.values) {
      expect(metadata.owners.keys, [
        StorageOwner(storageAccountKey(user, server), '!a').key,
      ]);
    }
    expect(prefs.getString('storage_file_index_v1'), isNot(contains(url)));
    await restoreStorageAttribution(
      userId: user,
      homeserver: server,
      registry: registry,
    );
    expect(
      (manager.config.repo as dynamic).openConnections,
      connections,
      reason: 'Repeated recovery must release its repository connection',
    );
  });

  testWidgets(
    'room attribution consumes rooms already loaded before mounting',
    (tester) async {
      const user = CurrentUser(
        id: '@loaded:example.org',
        displayName: 'Loaded',
        homeserver: 'https://example.org',
      );
      final container = ProviderContainer(
        overrides: [
          chatRoomsProvider.overrideWith(
            (ref) async => [
              ChatRoom(
                id: '!loaded',
                name: 'Already loaded',
                lastMessage: '',
                lastMessageTime: '0',
                lastEventId: '',
                unreadCount: 0,
                isMarkedUnread: false,
                roomType: 'group',
                isEncrypted: false,
                isMuted: false,
                roomState: 'joined',
              ),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(currentUserProvider.notifier).value = user;
      await container.read(chatRoomsProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const StorageMaintenanceRoot(child: SizedBox()),
        ),
      );
      await tester.pumpAndSettle();
      final key = StorageOwner(
        storageAccountKey(user.id, user.homeserver),
        '!loaded',
      ).key;
      expect(storageRegistry.rooms[key]?.name, 'Already loaded');
      expect(storageRegistry.rooms[key]?.type, StorageChatType.group);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(storageRegistry.flush);
    },
  );

  test(
    'adding recovered owners preserves an existing measured last-use time',
    () async {
      final registry = StorageRegistry();
      final used = DateTime(2020);
      registry.files['${root.path}/image'] = StorageFileMetadata(
        StorageKind.image,
        used,
        const [StorageOwner('account', '!a')],
      );
      await registry.attribute(
        '${root.path}/image',
        StorageKind.image,
        DateTime.now(),
        const [StorageOwner('account', '!b')],
      );
      expect(registry.files['${root.path}/image']!.used, used);
      expect(registry.files['${root.path}/image']!.usageEstimated, isFalse);
      expect(registry.files['${root.path}/image']!.owners.length, 2);
      await registry.flush();
    },
  );
}
