import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'auth_provider.dart';
import 'connection_provider.dart';
import 'mutable_state.dart';

final chatRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final rooms = await rust.getChatRooms();
  return rooms;
});

final spacesProvider = FutureProvider<List<rust.Space>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  return rust.getSpaces();
});

final spaceDetailsProvider = FutureProvider.family<rust.SpaceDetails, String>((
  ref,
  spaceId,
) async {
  if (!ref.watch(sessionReadyProvider)) {
    throw StateError('Session not ready');
  }
  return rust.getSpaceDetails(spaceId: spaceId);
});

final inboxRoomsProvider = Provider<AsyncValue<List<rust.ChatRoom>>>((ref) {
  return ref
      .watch(chatRoomsProvider)
      .whenData(
        (rooms) => rooms.where((room) => room.roomType != 'space').toList(),
      );
});

final ungroupedRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  return rust.getUngroupedRooms();
});

final spaceChildrenProvider =
    FutureProvider.family<List<rust.ChatRoom>, String>((ref, spaceId) async {
      if (!ref.watch(sessionReadyProvider)) return [];
      return rust.getSpaceChildren(spaceId: spaceId);
    });

final contactsProvider = FutureProvider<List<rust.Contact>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final contacts = await rust.getContacts();
  return contacts;
});

void invalidateSessionCollections(WidgetRef ref) {
  ref.invalidate(chatRoomsProvider);
  ref.invalidate(spacesProvider);
  ref.invalidate(ungroupedRoomsProvider);
  ref.invalidate(contactsProvider);
}

void clearActiveSessionState(WidgetRef ref, {bool markSessionReady = false}) {
  ref.read(isLoggedInProvider.notifier).value = false;
  ref.read(currentUserProvider.notifier).value = null;
  ref.read(currentAccessTokenProvider.notifier).value = null;
  ref.read(activeUserIdProvider.notifier).value = null;
  ref.read(connectionProvider.notifier).value = AppConnectionState.disconnected;
  if (markSessionReady) {
    ref.read(sessionReadyProvider.notifier).value = true;
  }
}

Future<void> applyActiveSessionState(
  WidgetRef ref, {
  required String userId,
  required String displayName,
  required String homeserver,
  bool persistActiveUser = false,
  bool refreshStoredSessions = false,
  bool markLoggedIn = true,
}) async {
  if (persistActiveUser) {
    await saveActiveUserId(userId);
  }
  final accessToken = await rust.getAccessToken();
  final sessions = refreshStoredSessions ? await loadAllSessions() : null;
  ref.read(currentUserProvider.notifier).value = CurrentUser(
    id: userId,
    displayName: displayName,
    homeserver: homeserver,
  );
  ref.read(currentAccessTokenProvider.notifier).value = accessToken;
  ref.read(homeserverProvider.notifier).value = homeserver;
  ref.read(activeUserIdProvider.notifier).value = userId;
  if (refreshStoredSessions) {
    ref.read(sessionsProvider.notifier).value = sessions ?? [];
  }
  if (markLoggedIn) {
    ref.read(isLoggedInProvider.notifier).value = true;
  }
  ref.read(connectionProvider.notifier).value = AppConnectionState.connecting;
}

Future<void> bootstrapActiveSessionSync(
  WidgetRef ref, {
  required String attemptLabel,
  required String startSyncLabel,
}) async {
  var initialSyncSucceeded = false;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      await rust.syncOnce();
      initialSyncSucceeded = true;
      ref.read(connectionProvider.notifier).value =
          AppConnectionState.connected;
      invalidateSessionCollections(ref);
      break;
    } catch (e) {
      debugPrint('$attemptLabel ${attempt + 1} failed: $e');
      if (attempt < 2) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
  }

  if (!initialSyncSucceeded) {
    ref.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
  }

  try {
    await rust.startSync();
  } catch (e) {
    debugPrint('$startSyncLabel: $e');
  }
  invalidateSessionCollections(ref);
}

final currentRoomIdProvider = NotifierProvider<MutableState<String?>, String?>(
  () => MutableState(null),
);

final messagesProvider = FutureProvider.family<List<rust.ChatMessage>, String>((
  ref,
  roomId,
) async {
  if (!ref.watch(sessionReadyProvider)) return const <rust.ChatMessage>[];
  return rust.getMessages(roomId: roomId);
});

Future<void> refreshMessagesRef(Ref ref, String roomId) {
  ref.invalidate(messagesProvider(roomId));
  return ref.read(messagesProvider(roomId).future);
}

Future<void> refreshMessages(WidgetRef ref, String roomId) {
  ref.invalidate(messagesProvider(roomId));
  return ref.read(messagesProvider(roomId).future);
}

final stickerPacksProvider =
    FutureProvider.family<List<rust.StickerPack>, String>((ref, roomId) async {
      if (!ref.watch(sessionReadyProvider)) return [];
      return rust.getStickerPacks(roomId: roomId);
    });

/// Convert mxc:// URI to HTTP URL for display.
/// Returns null if conversion fails or URL is not mxc://.
final mxcUrlCacheProvider =
    NotifierProvider<MutableState<Map<String, String>>, Map<String, String>>(
      () => MutableState({}),
    );

const _kMxcCachePrefix = 'mxc_http_cache_v1';
const _kMaxPersistedMxcEntriesPerUser = 500;
final _loadedMxcCacheUsers = <String>{};

String _mxcStorageNamespace(WidgetRef ref) =>
    ref.read(activeUserIdProvider) ?? 'anonymous';

String _mxcStorageKey(String namespace) => '${_kMxcCachePrefix}_$namespace';

String _scopedMxcCacheKey(String namespace, String cacheKey) =>
    '$namespace::$cacheKey';

Future<void> _ensureMxcCacheLoaded(WidgetRef ref) async {
  final namespace = _mxcStorageNamespace(ref);
  if (_loadedMxcCacheUsers.contains(namespace)) return;

  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_mxcStorageKey(namespace));
  if (raw != null && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final trimmed = _trimPersistedMxcEntries(
        decoded.map((key, value) => MapEntry(key, '$value')),
      );
      final loadedEntries = decoded.map(
        (key, value) => MapEntry(
          _scopedMxcCacheKey(namespace, key),
          trimmed[key] ?? '$value',
        ),
      );
      final cache = ref.read(mxcUrlCacheProvider);
      ref.read(mxcUrlCacheProvider.notifier).value = {
        ...cache,
        ...loadedEntries,
      };
      if (trimmed.length != decoded.length) {
        await prefs.setString(_mxcStorageKey(namespace), jsonEncode(trimmed));
      }
    } catch (error) {
      debugPrint('Failed to load persisted MXC cache for $namespace: $error');
    }
  }

  _loadedMxcCacheUsers.add(namespace);
}

Future<void> _persistMxcCacheEntry(
  WidgetRef ref,
  String namespace,
  String unscopedCacheKey,
  String httpUrl,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final storageKey = _mxcStorageKey(namespace);
    final raw = prefs.getString(storageKey);
    final persisted = raw == null || raw.isEmpty
        ? <String, String>{}
        : (jsonDecode(raw) as Map<String, dynamic>).map(
            (key, value) => MapEntry(key, '$value'),
          );
    persisted.remove(unscopedCacheKey);
    persisted[unscopedCacheKey] = httpUrl;
    final trimmed = _trimPersistedMxcEntries(persisted);
    await prefs.setString(storageKey, jsonEncode(trimmed));
  } catch (error) {
    debugPrint('Failed to persist MXC cache entry: $error');
  }
}

Map<String, String> _trimPersistedMxcEntries(Map<String, String> entries) {
  if (entries.length <= _kMaxPersistedMxcEntriesPerUser) return entries;
  final trimmed = Map<String, String>.from(entries);
  while (trimmed.length > _kMaxPersistedMxcEntriesPerUser) {
    trimmed.remove(trimmed.keys.first);
  }
  return trimmed;
}

String _mxcCacheKey(String mxcUrl, {int? width, int? height}) {
  if (width == null && height == null) return mxcUrl;
  return '$mxcUrl|${width ?? 0}x${height ?? 0}';
}

Future<String?> resolveMxcUrlAvatar(WidgetRef ref, String? mxcUrl) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  await _ensureMxcCacheLoaded(ref);
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: 96, height: 96);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);

  final cache = ref.read(mxcUrlCacheProvider);
  if (cache.containsKey(cacheKey)) return cache[cacheKey];

  try {
    final httpUrl = await rust.mxcToHttpAvatar(mxcUrl: mxcUrl);
    if (httpUrl == null || httpUrl.isEmpty) return null;
    ref.read(mxcUrlCacheProvider.notifier).value = {
      ...cache,
      cacheKey: httpUrl,
    };
    unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
    return httpUrl;
  } catch (_) {
    return null;
  }
}

Future<String?> resolveMxcUrl(
  WidgetRef ref,
  String? mxcUrl, {
  int? width,
  int? height,
}) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  await _ensureMxcCacheLoaded(ref);
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);

  // Check cache first
  final cache = ref.read(mxcUrlCacheProvider);
  if (cache.containsKey(cacheKey)) return cache[cacheKey];

  try {
    final httpUrl = width != null && height != null
        ? await rust.mxcToHttpThumbnail(
            mxcUrl: mxcUrl,
            width: width,
            height: height,
          )
        : await rust.mxcToHttp(mxcUrl: mxcUrl);
    if (httpUrl == null || httpUrl.isEmpty) return null;
    ref.read(mxcUrlCacheProvider.notifier).value = {
      ...cache,
      cacheKey: httpUrl,
    };
    unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
    return httpUrl;
  } catch (_) {
    return null;
  }
}

/// Convert mxc:// URI to full-quality download HTTP URL.
/// Used for "原图" (original quality) in image preview.
Future<String?> resolveMxcUrlFull(WidgetRef ref, String? mxcUrl) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  try {
    return await rust.mxcToHttpFull(mxcUrl: mxcUrl);
  } catch (_) {
    return null;
  }
}

/// Room members provider
final roomMembersProvider = FutureProvider.family<List<rust.Contact>, String>((
  ref,
  roomId,
) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final members = await rust.getRoomMembers(roomId: roomId);
  return members;
});

/// Search rooms provider
final searchRoomsProvider = FutureProvider.family<List<rust.ChatRoom>, String>((
  ref,
  query,
) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  if (query.trim().isEmpty) return [];
  return rust.searchRooms(query: query);
});

/// Send a reply to a message
Future<void> sendReply(
  Ref ref,
  String roomId,
  String message,
  String replyToEventId,
) async {
  await rust.sendReply(
    roomId: roomId,
    message: message,
    replyToEventId: replyToEventId,
  );
  await refreshMessagesRef(ref, roomId);
  ref.invalidate(chatRoomsProvider);
}

/// Redact (delete) a message
Future<void> redactMessage(
  WidgetRef ref,
  String roomId,
  String eventId, {
  String? reason,
}) async {
  await rust.redactMessage(roomId: roomId, eventId: eventId, reason: reason);
  await refreshMessages(ref, roomId);
  ref.invalidate(chatRoomsProvider);
}

/// The sync event stream subscription. Stays active for the app's lifetime.
/// When sync events arrive, invalidates room/message providers so the UI
/// updates automatically.
///
/// Initialize once after login with: `ref.watch(syncStreamProvider);`
final syncStreamProvider =
    Provider.autoDispose<StreamSubscription<rust.SyncEvent>?>((ref) {
      final sessionReady = ref.watch(sessionReadyProvider);
      final activeUserId = ref.watch(activeUserIdProvider);
      if (!sessionReady || activeUserId == null) {
        return null;
      }

      final stream = rust.watchSyncEvents();
      Timer? messageRefreshTimer;
      Timer? roomRefreshTimer;
      final pendingMessageRefreshes = <String>{};

      void refreshRooms() {
        ref.invalidate(chatRoomsProvider);
        ref.invalidate(spacesProvider);
        ref.invalidate(ungroupedRoomsProvider);
      }

      void scheduleRoomRefresh() {
        roomRefreshTimer?.cancel();
        roomRefreshTimer = Timer(const Duration(milliseconds: 500), () {
          roomRefreshTimer = null;
          refreshRooms();
        });
      }

      void flushMessageRefreshes() {
        final roomIds = pendingMessageRefreshes.toList();
        pendingMessageRefreshes.clear();
        for (final roomId in roomIds) {
          unawaited(refreshMessagesRef(ref, roomId));
        }
      }

      void scheduleMessageRefresh(String roomId) {
        pendingMessageRefreshes.add(roomId);
        messageRefreshTimer?.cancel();
        messageRefreshTimer = Timer(const Duration(milliseconds: 200), () {
          messageRefreshTimer = null;
          flushMessageRefreshes();
        });
      }

      final statusTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => pollConnectionStatus(ref),
      );
      Future.microtask(() => pollConnectionStatus(ref));
      final subscription = stream.listen((event) {
        pollConnectionStatus(ref);
        switch (event) {
          case rust.SyncEvent_SyncCompleted():
            scheduleRoomRefresh();
            final currentRoomId = ref.read(currentRoomIdProvider);
            if (currentRoomId != null) {
              scheduleMessageRefresh(currentRoomId);
            }
          case rust.SyncEvent_MessageSent(:final roomId):
            scheduleMessageRefresh(roomId);
            scheduleRoomRefresh();
        }
      });

      ref.onDispose(() {
        statusTimer.cancel();
        messageRefreshTimer?.cancel();
        roomRefreshTimer?.cancel();
        subscription.cancel();
      });

      return subscription;
    });

// ── Typing notifications ─────────────────────────────────────────────
//
// `typingUsersProvider(roomId)` exposes the set of user ids currently typing
// in that room. A single subscription to `watchTypingNotifications` fans out
// updates by room id; each room auto-clears after 5s of silence (Matrix typing
// events are ephemeral and may not always send an explicit "stopped" event).

final typingUsersProvider =
    NotifierProvider.family<MutableState<Set<String>>, Set<String>, String>(
      (_) => MutableState({}),
    );

/// Per-room timeout timers so typing status clears after inactivity.
final _typingTimers = <String, Timer>{};

/// Start the global typing-notification listener. Initialize once after login
/// (alongside `syncStreamProvider`). Returns the subscription.
final typingStreamProvider =
    Provider.autoDispose<StreamSubscription<rust.TypingNotification>?>((ref) {
      final sessionReady = ref.watch(sessionReadyProvider);
      final activeUserId = ref.watch(activeUserIdProvider);
      if (!sessionReady || activeUserId == null) {
        return null;
      }

      final stream = rust.watchTypingNotifications();
      final subscription = stream.listen((event) {
        final roomId = event.roomId;
        ref.read(typingUsersProvider(roomId).notifier).value = event.userIds
            .toSet();
        // (Re)arm the auto-clear timer for this room.
        _typingTimers[roomId]?.cancel();
        _typingTimers[roomId] = Timer(const Duration(seconds: 5), () {
          ref.read(typingUsersProvider(roomId).notifier).value = {};
          _typingTimers.remove(roomId);
        });
      });

      ref.onDispose(() {
        subscription.cancel();
        for (final t in _typingTimers.values) {
          t.cancel();
        }
        _typingTimers.clear();
      });

      return subscription;
    });
