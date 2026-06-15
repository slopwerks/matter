import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  ref.read(currentUserProvider.notifier).value = CurrentUser(
    id: userId,
    displayName: displayName,
    homeserver: homeserver,
  );
  ref.read(homeserverProvider.notifier).value = homeserver;
  ref.read(activeUserIdProvider.notifier).value = userId;
  if (refreshStoredSessions) {
    ref.read(sessionsProvider.notifier).value = await loadAllSessions();
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

  ref.read(syncStreamProvider);
  invalidateSessionCollections(ref);
}

final currentRoomIdProvider = NotifierProvider<MutableState<String?>, String?>(
  () => MutableState(null),
);

final messagesProvider = FutureProvider.family<List<rust.ChatMessage>, String>((
  ref,
  roomId,
) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final messages = await rust.getMessages(roomId: roomId);
  return messages;
});

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

Future<String?> resolveMxcUrl(WidgetRef ref, String? mxcUrl) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;

  // Check cache first
  final cache = ref.read(mxcUrlCacheProvider);
  if (cache.containsKey(mxcUrl)) return cache[mxcUrl];

  try {
    final httpUrl = await rust.mxcToHttp(mxcUrl: mxcUrl);
    if (httpUrl != null) {
      ref.read(mxcUrlCacheProvider.notifier).value = {
        ...cache,
        mxcUrl: httpUrl,
      };
    }
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
  ref.invalidate(messagesProvider(roomId));
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
  ref.invalidate(messagesProvider(roomId));
  ref.invalidate(chatRoomsProvider);
}

/// The sync event stream subscription. Stays active for the app's lifetime.
/// When sync events arrive, invalidates room/message providers so the UI
/// updates automatically.
///
/// Initialize once after login with: `ref.read(syncStreamProvider);`
final syncStreamProvider = Provider<StreamSubscription<rust.SyncEvent>>((ref) {
  final stream = rust.watchSyncEvents();
  Timer? messageRefreshTimer;
  Timer? roomRefreshTimer;
  final pendingMessageRefreshes = <String>{};

  void refreshRooms() {
    ref.invalidate(chatRoomsProvider);
    ref.invalidate(spacesProvider);
    ref.invalidate(ungroupedRoomsProvider);
  }

  void refreshCurrentRoomMeta() {
    final currentRoomId = ref.read(currentRoomIdProvider);
    if (currentRoomId != null) {
      ref.invalidate(stickerPacksProvider(currentRoomId));
    }
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
      ref.invalidate(messagesProvider(roomId));
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
        refreshCurrentRoomMeta();
        final currentRoomId = ref.read(currentRoomIdProvider);
        if (currentRoomId != null) {
          scheduleMessageRefresh(currentRoomId);
        }
      case rust.SyncEvent_MessageSent(:final roomId):
        scheduleMessageRefresh(roomId);
        scheduleRoomRefresh();
        ref.invalidate(stickerPacksProvider(roomId));
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
    Provider<StreamSubscription<rust.TypingNotification>>((ref) {
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
