import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_registry.dart';
import 'package:matter/features/storage/storage_service_io.dart';
import 'package:matter/features/storage/storage_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StorageRegistry registry;
  late StorageService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('matter-storage-test-');
    registry = StorageRegistry();
    service = StorageService(
      registry: registry,
      roots: () async => [
        StorageRoot(root.path),
        StorageRoot('${root.path}/cache', temporary: true),
        StorageRoot('${root.path}/cache', temporary: true),
      ],
    );
  });
  tearDown(() async {
    await registry.flush();
    await root.delete(recursive: true);
  });

  Future<File> file(String path, int bytes) async {
    final value = File('${root.path}/$path');
    await value.parent.create(recursive: true);
    await value.writeAsBytes(List.filled(bytes, 1));
    await value.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    return value;
  }

  test('metadata keeps safe names without source URLs and detects historical media', () async {
    final photo = await file(
      'cache/matter_managed_media/account/image/source.bin',
      8,
    );
    await photo.writeAsBytes([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0]);
    final snapshot = await service.scan();
    expect(snapshot.files.single.kind, StorageKind.image);
    expect(snapshot.files.single.usageEstimated, isTrue);
    await registry.record(
      photo.path,
      StorageKind.image,
      displayName: '../../旅行\u0000照片.jpg',
    );
    await registry.flush();
    final restored = StorageRegistry();
    await restored.load();
    expect(restored.files[photo.path]!.displayName, '旅行照片.jpg');
    expect(
      storageDisplayName('https://host/private?access_token=secret'),
      isNull,
    );
    final updated = (await service.scan()).files.single;
    expect(updated.name, '旅行照片.jpg');
    expect(updated.usageEstimated, isFalse);
    await restored.flush();
  });

  test('overlapping roots count physical files once and keep persistent data protected', () async {
    await file('cache/libCachedImageData/image.jpg', 10);
    await file('cache/matter_managed_media/account/video/source.mp4', 20);
    await file('accounts/alice/matrix.db', 30);
    await file('accounts/alice/matrix.db-wal', 4);
    await file('accounts/alice/search_index/index.bin', 5);
    await file('shared_prefs/settings.xml', 6);
    await file('matter_push_avatars/avatar.png', 7);
    await file('Downloads/saved.pdf', 8);
    final snapshot = await service.scan();
    expect(snapshot.totalBytes, 90);
    expect(snapshot.files.length, 8);
    expect(snapshot.bytesFor(StorageKind.database), 34);
    expect(snapshot.bytesFor(StorageKind.video), 20);
    expect(snapshot.bytesFor(StorageKind.search), 5);
    expect(snapshot.cleanableBytes, 37);
    final result = await service.clean(const StorageSelection());
    expect(result.releasedBytes, 37);
    expect(result.removedFiles, 3);
    expect(result.errors, isEmpty);
    expect(
      await File('${root.path}/accounts/alice/matrix.db').exists(),
      isTrue,
    );
    expect(await File('${root.path}/Downloads/saved.pdf').exists(), isTrue);
  });

  test(
    'room cleanup protects shared files until every owner is selected',
    () async {
      const a = StorageOwner('account', '!a');
      const b = StorageOwner('account', '!b');
      final shared = await file('cache/libCachedImageData/shared.jpg', 10);
      final local = await file('cache/libCachedImageData/local.jpg', 4);
      await registry.record(shared.path, StorageKind.image, owners: [a, b]);
      await registry.record(local.path, StorageKind.image, owners: [a]);
      await registry.updateRooms([
        const StorageRoom(a, 'Alice', StorageChatType.direct),
        const StorageRoom(b, 'Team', StorageChatType.group),
      ]);
      final result = await service.clean(StorageSelection(rooms: {a.key}));
      expect(result.releasedBytes, 4);
      expect(await shared.exists(), isTrue);
      expect(await local.exists(), isFalse);
      expect(
        (await service.clean(StorageSelection(rooms: {a.key, b.key})))
            .releasedBytes,
        10,
      );
    },
  );

  test('playback leases and unknown plugin files survive cleanup', () async {
    final audio = await file('cache/matter_audio_cache/account/source.bin', 20);
    final unknown = await file('cache/picker/upload.bin', 30);
    final release = registry.pin(audio.parent.path);
    expect((await service.clean(const StorageSelection())).skippedFiles, 1);
    expect(await audio.exists(), isTrue);
    expect(await unknown.exists(), isTrue);
    release();
    expect((await service.clean(const StorageSelection())).releasedBytes, 20);
    expect(await unknown.exists(), isTrue);
  });

  test('symbolic links are never traversed or deleted', () async {
    final saved = await file('Downloads/important.txt', 11);
    final cache = Directory('${root.path}/cache/libCachedImageData');
    await cache.create(recursive: true);
    final link = Link('${cache.path}/outside.jpg');
    await link.create(saved.path);
    final snapshot = await service.scan();
    expect(snapshot.totalBytes, 11);
    expect(snapshot.cleanableBytes, 0);
    await service.clean(const StorageSelection());
    expect(await saved.readAsBytes(), hasLength(11));
    expect(await link.exists(), isTrue);
  });

  test('canonical and alias paths share ownership and active leases', () async {
    const owner = StorageOwner('account', '!room');
    final image = await file('cache/libCachedImageData/aliased.jpg', 10);
    final alias = Link('${root.path}/cache-alias');
    await alias.create('${root.path}/cache');
    final aliasPath = '${alias.path}/libCachedImageData/aliased.jpg';
    await registry.record(aliasPath, StorageKind.image, owners: [owner]);
    final release = registry.pin(aliasPath);
    final snapshot = await service.scan();
    expect(snapshot.files.single.owners.single.key, owner.key);
    expect(snapshot.files.single.busy, isTrue);
    expect((await service.clean(const StorageSelection())).removedFiles, 0);
    release();
    expect((await service.clean(const StorageSelection())).releasedBytes, 10);
    expect(await image.exists(), isFalse);
  });

  test(
    'global cap evicts least recently used files and preserves a leased file',
    () async {
      final first = await file('cache/libCachedImageData/first.jpg', 10);
      final second = await file('cache/libCachedImageData/second.jpg', 10);
      final busy = await file('cache/libCachedImageData/busy.jpg', 10);
      final now = DateTime.now();
      await registry.load();
      registry.files[first.path] = StorageFileMetadata(
        StorageKind.image,
        now.subtract(const Duration(days: 3)),
        [],
      );
      registry.files[second.path] = StorageFileMetadata(
        StorageKind.image,
        now.subtract(const Duration(days: 1)),
        [],
      );
      final release = registry.pin(busy.path);
      final result = await service.enforce(
        const StorageSettings(maxCacheBytes: 20),
      );
      expect(result.releasedBytes, 10);
      expect(await first.exists(), isFalse);
      expect(await second.exists(), isTrue);
      expect(await busy.exists(), isTrue);
      release();
    },
  );

  test(
    'registry persists room ownership and last use without source URLs',
    () async {
      const owner = StorageOwner('hash', '!r');
      final image = await file('cache/libCachedImageData/test.jpg', 10);
      registry.rememberSource(
        'https://server/private?access_token=secret',
        owner,
      );
      await registry.recordSource(
        'https://server/private?access_token=secret',
        image.path,
        StorageKind.image,
      );
      await registry.updateRooms([
        const StorageRoom(owner, 'Room', StorageChatType.group),
      ]);
      await registry.flush();
      final restored = StorageRegistry();
      await restored.load();
      expect(restored.files[image.path]!.owners.keys, [owner.key]);
      expect(restored.rooms[owner.key]!.name, 'Room');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('storage_file_index_v1'),
        isNot(contains('secret')),
      );
    },
  );
}
