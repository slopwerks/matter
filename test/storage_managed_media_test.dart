import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:matter/features/storage/managed_media.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_registry.dart';
import 'package:matter/pages/chat/prepared_media_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('matter-managed-cache-');
    installTempPathProvider(root);
  });
  tearDown(() async {
    await storageRegistry.flush();
    await root.delete(recursive: true);
  });

  test(
    'concurrent room requests share a completed file and independent leases',
    () async {
      var downloads = 0;
      Future<PreparedMediaSource> load() async {
        downloads++;
        final file = File('${root.path}/original.mp4');
        await file.writeAsBytes([1, 2, 3]);
        return PreparedMediaSource(
          media: Media(file.path),
          cleanup: () async => file.delete(),
        );
      }

      final sources = await Future.wait([
        for (final room in ['!a', '!b'])
          prepareManagedMedia(
            account: 'account',
            key: 'source',
            filename: 'video.mp4',
            kind: StorageKind.video,
            owner: StorageOwner('account', room),
            load: load,
          ),
      ]);
      expect(downloads, 1);
      expect(sources.first.media.uri, sources.last.media.uri);
      final file = File(sources.first.media.uri);
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(storageRegistry.files[file.path]!.owners.length, 2);
      expect(storageRegistry.files[file.path]!.displayName, 'video.mp4');
      await sources.first.cleanup();
      expect(storageRegistry.isBusy(file.path), isTrue);
      await sources.last.cleanup();
      expect(storageRegistry.isBusy(file.path), isFalse);
      expect(await file.exists(), isTrue);
      final cached = await cachedManagedMedia(
        account: 'account',
        key: 'source',
        filename: 'video.mp4',
        kind: StorageKind.video,
      );
      expect(cached, isNotNull);
      await cached!.cleanup();
      expect(
        await cachedManagedMedia(
          account: 'different-account',
          key: 'source',
          filename: 'video.mp4',
          kind: StorageKind.video,
        ),
        isNull,
      );
    },
  );

  test('account removal waits for in-flight cache writes and preserves other accounts', () async {
    final original = File('${root.path}/original.bin');
    await original.writeAsBytes([4]);
    Future<PreparedMediaSource> local() async =>
        PreparedMediaSource(media: Media(original.path), cleanup: () async {});
    final other = await prepareManagedMedia(
      account: 'other',
      key: 'source',
      filename: 'file.bin',
      kind: StorageKind.document,
      load: local,
    );
    await other.cleanup();
    final started = Completer<void>();
    final finish = Completer<void>();
    final transfer = prepareManagedMedia(
      account: 'removed',
      key: 'source',
      filename: 'file.bin',
      kind: StorageKind.document,
      load: () async {
        started.complete();
        await finish.future;
        return local();
      },
    );
    await started.future;
    final removal = clearManagedMediaAccount('removed');
    finish.complete();
    final source = await transfer;
    await removal;
    await source.cleanup();
    expect(await File(source.media.uri).exists(), isFalse);
    expect(await File(other.media.uri).exists(), isTrue);
    expect(
      await cachedManagedMedia(
        account: 'removed',
        key: 'source',
        filename: 'file.bin',
        kind: StorageKind.document,
      ),
      isNull,
    );
  });

  test('failed transfers publish no cache hit and can be retried', () async {
    Future<PreparedMediaSource> fail() async =>
        throw StateError('transfer failed');
    await expectLater(
      prepareManagedMedia(
        account: 'account',
        key: 'failed',
        filename: 'file.pdf',
        kind: StorageKind.document,
        load: fail,
      ),
      throwsStateError,
    );
    expect(
      await cachedManagedMedia(
        account: 'account',
        key: 'failed',
        filename: 'file.pdf',
        kind: StorageKind.document,
      ),
      isNull,
    );
    final original = File('${root.path}/complete.pdf');
    await original.writeAsBytes([9]);
    final source = await prepareManagedMedia(
      account: 'account',
      key: 'failed',
      filename: 'file.pdf',
      kind: StorageKind.document,
      load: () async => PreparedMediaSource(
        media: Media(original.path),
        cleanup: () async {},
      ),
    );
    expect(await File(source.media.uri).readAsBytes(), [9]);
    await source.cleanup();
  });
}
