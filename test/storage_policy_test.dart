import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_policy.dart';
import 'package:matter/features/storage/storage_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final now = DateTime(2026, 11, 4);
  const direct = StorageOwner('a', '!direct');
  const group = StorageOwner('a', '!group');
  StorageFile file(
    String name,
    int days, {
    List<StorageOwner> owners = const [],
    bool busy = false,
    bool cleanable = true,
  }) => StorageFile(
    path: name,
    bytes: 10,
    modified: now.subtract(Duration(days: days)),
    lastUsed: now.subtract(Duration(days: days)),
    kind: StorageKind.image,
    cleanable: cleanable,
    busy: busy,
    owners: owners,
  );
  StorageSnapshot snapshot(List<StorageFile> files) => StorageSnapshot(
    files: files,
    rooms: {
      direct.key: const StorageRoom(direct, 'Direct', StorageChatType.direct),
      group.key: const StorageRoom(group, 'Group', StorageChatType.group),
    },
    measuredAt: now,
  );

  test(
    'retention respects every owner of a shared file and permanent policies',
    () {
      final value = snapshot([
        file('direct-old', 10, owners: [direct]),
        file('group-permanent', 10, owners: [group]),
        file('shared-permanent', 10, owners: [direct, group]),
        file('recent', 1, owners: [direct]),
        file('busy', 20, owners: [direct], busy: true),
      ]);
      final settings = StorageSettings(
        maxCacheBytes: 0,
        policies: {
          StorageChatType.direct: const ChatStoragePolicy(keepDays: 7),
        },
      );
      expect(selectPolicyEvictions(value, settings, now: now), {'direct-old'});
      expect(
        selectPolicyEvictions(
          value,
          settings.copyWith(
            policies: {
              StorageChatType.direct: const ChatStoragePolicy(keepDays: 7),
              StorageChatType.group: const ChatStoragePolicy(keepDays: 14),
            },
          ),
          now: now,
        ),
        {'direct-old'},
      );
    },
  );

  test('type quotas avoid cross-type shared data while global quota counts it once', () {
    final value = snapshot([
      file('dm-old', 10, owners: [direct]),
      file('dm-new', 1, owners: [direct]),
      file('shared', 20, owners: [direct, group]),
      file('database', 90, cleanable: false),
    ]);
    final settings = StorageSettings(
      maxCacheBytes: 0,
      policies: {StorageChatType.direct: const ChatStoragePolicy(maxBytes: 10)},
    );
    expect(selectPolicyEvictions(value, settings, now: now), {'dm-old'});
    expect(
      selectPolicyEvictions(
        value,
        settings.copyWith(maxCacheBytes: 10),
        now: now,
      ),
      {'dm-old', 'shared'},
    );
  });

  test(
    'busy bytes count against quotas but are deferred instead of deleted',
    () {
      final value = snapshot([file('busy', 10, busy: true), file('free', 1)]);
      expect(
        selectPolicyEvictions(value, const StorageSettings(maxCacheBytes: 10)),
        {'free'},
      );
      expect(
        selectPolicyEvictions(value, const StorageSettings(maxCacheBytes: 0)),
        isEmpty,
      );
    },
  );

  test(
    'chat policies exclude public cache but global quota still covers it',
    () {
      final public = StorageFile(
        path: 'public-cache',
        bytes: 10,
        modified: now.subtract(const Duration(days: 30)),
        lastUsed: now.subtract(const Duration(days: 30)),
        kind: StorageKind.temporary,
        cleanable: true,
      );
      final value = snapshot([public, file('orphan-media', 30)]);
      final settings = StorageSettings(
        maxCacheBytes: 0,
        policies: {
          StorageChatType.unknown: const ChatStoragePolicy(
            keepDays: 7,
            maxBytes: 1,
          ),
        },
      );
      expect(selectPolicyEvictions(value, settings, now: now), {
        'orphan-media',
      });
      expect(
        selectPolicyEvictions(
          value,
          settings.copyWith(maxCacheBytes: 5),
          now: now,
        ),
        {'orphan-media', 'public-cache'},
      );
      expect(
        StorageSelection(chatTypes: {StorageChatType.unknown})
            .matches(public, {}),
        isFalse,
      );
    },
  );

  test(
    'automatic rules require known size, enabled type and the selected network',
    () {
      const settings = StorageSettings(
        mobileDownloads: DownloadRules(enabled: false),
      );
      expect(
        settings.permits(StorageKind.image, storageMiB, unmetered: true),
        isTrue,
      );
      expect(
        settings.permits(StorageKind.image, storageMiB, unmetered: false),
        isFalse,
      );
      expect(
        settings.permits(StorageKind.image, null, unmetered: true),
        isFalse,
      );
      expect(
        settings.permits(StorageKind.image, 9 * storageMiB, unmetered: true),
        isFalse,
      );
      expect(settings.permits(StorageKind.audio, 1, unmetered: true), isFalse);
      expect(
        settings
            .copyWith(wifiDownloads: const DownloadRules(enabled: false))
            .permits(StorageKind.image, 1, unmetered: true),
        isFalse,
      );
    },
  );

  test(
    'download directory, network, type limits and retention survive reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = const StorageSettings().copyWith(
        maxCacheBytes: 500,
        mobileDownloads: const DownloadRules(enabled: false),
        downloadDirectory: '/chosen',
        downloadDirectoryLabel: 'Chosen',
        askSaveLocation: true,
        wifiDownloads: const DownloadRules(
          limits: {StorageKind.document: 5 * storageMiB},
        ),
        policies: {
          StorageChatType.group: const ChatStoragePolicy(
            keepDays: 7,
            maxBytes: 100,
          ),
        },
      );
      await saveStorageSettings(settings);
      final loaded = await loadStorageSettings();
      expect(loaded.toJson(), settings.toJson());
      expect(loaded.copyWith(resetDirectory: true).downloadDirectory, isNull);
    },
  );
}
