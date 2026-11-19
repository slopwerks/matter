import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import 'storage_attribution.dart';
import 'storage_download_policy.dart';
import 'storage_models.dart';
import 'storage_registry.dart';
import 'storage_service.dart';
import 'storage_settings.dart';

final storageSettingsProvider =
    AsyncNotifierProvider<StorageSettingsNotifier, StorageSettings>(
      StorageSettingsNotifier.new,
    );

class StorageSettingsNotifier extends AsyncNotifier<StorageSettings> {
  @override
  Future<StorageSettings> build() => loadStorageSettings();

  Future<void> save(StorageSettings settings) async {
    await saveStorageSettings(settings);
    state = AsyncData(settings);
  }
}

// Only download-rule or network changes restart automatic preparation; visual
// settings and unrelated cache quotas do not interrupt media.
final storageAutoDownloadPolicyProvider = Provider((ref) {
  final rules = ref.watch(
    storageSettingsProvider.select(
      (value) => (
        wifi: value.asData?.value.wifiDownloads,
        mobile: value.asData?.value.mobileDownloads,
      ),
    ),
  );
  final connection =
      ref.watch(storageConnectionProvider).asData?.value ??
      StorageConnection.unknown;
  return (rules: rules, connection: connection);
});

final storageSnapshotProvider = FutureProvider<StorageSnapshot>((ref) async {
  final user = ref.watch(currentUserProvider);
  String? warning;
  if (user != null && !kIsWeb) {
    final rooms = ref.watch(chatRoomsProvider).asData?.value;
    try {
      if (rooms != null) {
        await storageRegistry.updateRooms(
          rooms.map(
            (room) => StorageRoom(
              StorageOwner(
                storageAccountKey(user.id, user.homeserver),
                room.id,
              ),
              room.name,
              StorageChatType.fromRoomType(room.roomType),
            ),
          ),
        );
      }
      await restoreStorageAttribution(
        userId: user.id,
        homeserver: user.homeserver,
      );
    } catch (error) {
      warning = '部分历史媒体未能恢复聊天归属，请稍后刷新。';
      debugPrint('Storage attribution recovery failed: $error');
    }
  }
  final snapshot = await storageService.scan();
  if (warning == null) return snapshot;
  return StorageSnapshot(
    files: snapshot.files,
    rooms: snapshot.rooms,
    measuredAt: snapshot.measuredAt,
    warnings: [...snapshot.warnings, warning],
    systemDataBytes: snapshot.systemDataBytes,
    systemCacheBytes: snapshot.systemCacheBytes,
    appBytes: snapshot.appBytes,
    freeBytes: snapshot.freeBytes,
    volumeBytes: snapshot.volumeBytes,
  );
});
final storageLastCleanupProvider =
    NotifierProvider<_LastCleanup, StorageCleanupResult?>(_LastCleanup.new);

class _LastCleanup extends Notifier<StorageCleanupResult?> {
  @override
  StorageCleanupResult? build() => null;
  void set(StorageCleanupResult result) => state = result;
}

/// Maintenance is scheduled at startup, resume, settings changes and after file
/// leases are released. It never runs a scan for every image frame.
class StorageMaintenanceRoot extends ConsumerStatefulWidget {
  final Widget child;
  const StorageMaintenanceRoot({super.key, required this.child});
  @override
  ConsumerState<StorageMaintenanceRoot> createState() =>
      _StorageMaintenanceRootState();
}

class _StorageMaintenanceRootState extends ConsumerState<StorageMaintenanceRoot>
    with WidgetsBindingObserver {
  Timer? _periodic;
  Timer? _debounce;
  bool _running = false;
  bool _rerun = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;
    WidgetsBinding.instance.addObserver(this);
    _periodic = Timer.periodic(const Duration(minutes: 5), (_) => _schedule());
    storageRegistry.onFileCompleted = _schedule;
    ref.listenManual(storageSettingsProvider, (previous, next) {
      final before = previous?.asData?.value;
      final after = next.asData?.value;
      if (after != null &&
          (before?.maxCacheBytes != after.maxCacheBytes ||
              !mapEquals(before?.policies, after.policies))) {
        _schedule();
      }
    });
    ref.listenManual(chatRoomsProvider, (_, rooms) {
      final user = ref.read(currentUserProvider);
      final values = rooms.asData?.value;
      if (user == null || values == null) return;
      unawaited(
        storageRegistry
            .updateRooms(
              values.map(
                (room) => StorageRoom(
                  StorageOwner(
                    storageAccountKey(user.id, user.homeserver),
                    room.id,
                  ),
                  room.name,
                  StorageChatType.fromRoomType(room.roomType),
                ),
              ),
            )
            .catchError(
              (Object error) => debugPrint('Storage room index failed: $error'),
            ),
      );
    }, fireImmediately: true);
    _schedule();
  }

  void _schedule() {
    _debounce ??= Timer(const Duration(seconds: 3), () {
      _debounce = null;
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    if (_running) {
      _rerun = true;
      return;
    }
    _running = true;
    try {
      final result = await storageService.enforce(await loadStorageSettings());
      if (!mounted) return;
      if (result.removedFiles > 0 || result.errors.isNotEmpty) {
        ref.read(storageLastCleanupProvider.notifier).set(result);
        ref.invalidate(storageSnapshotProvider);
      }
    } catch (error) {
      debugPrint('Storage maintenance failed: $error');
    } finally {
      _running = false;
      if (_rerun && mounted) {
        _rerun = false;
        _schedule();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(storageConnectionProvider);
      _schedule();
    }
  }

  @override
  void dispose() {
    _periodic?.cancel();
    _debounce?.cancel();
    storageRegistry.onFileCompleted = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(storageRegistry.flush().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
