import 'dart:async';
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
  DateTime? lastMessageRefresh;
  DateTime? lastRoomRefresh;
  final statusTimer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => pollConnectionStatus(ref),
  );
  Future.microtask(() => pollConnectionStatus(ref));
  final subscription = stream.listen((event) {
    pollConnectionStatus(ref);
    switch (event) {
      case rust.SyncEvent_SyncCompleted():
        // Debounce room-list refreshes to avoid flooding during rapid syncs
        final now = DateTime.now();
        if (lastRoomRefresh == null ||
            now.difference(lastRoomRefresh!).inMilliseconds >= 2000) {
          lastRoomRefresh = now;
          ref.invalidate(chatRoomsProvider);
          ref.invalidate(spacesProvider);
          ref.invalidate(ungroupedRoomsProvider);
        }
        // Refresh messages for the currently open room, but debounce to avoid flicker
        final currentRoomId = ref.read(currentRoomIdProvider);
        if (currentRoomId != null) {
          if (lastMessageRefresh == null ||
              now.difference(lastMessageRefresh!).inMilliseconds >= 500) {
            lastMessageRefresh = now;
            ref.invalidate(messagesProvider(currentRoomId));
          }
        }
      case rust.SyncEvent_MessageSent(:final roomId):
        // A message was sent — refresh that room's messages
        ref.invalidate(messagesProvider(roomId));
        // Also refresh room list (last message may have changed)
        ref.invalidate(chatRoomsProvider);
    }
  });

  ref.onDispose(() {
    statusTimer.cancel();
    subscription.cancel();
  });

  return subscription;
});
