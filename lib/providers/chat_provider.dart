import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'auth_provider.dart';

final chatRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final rooms = await rust.getChatRooms();
  return rooms;
});

final spacesProvider = FutureProvider<List<rust.Space>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final spaces = await rust.getSpaces();
  return spaces;
});

final selectedSpaceIdProvider = StateProvider<String>((ref) => 'all');

final contactsProvider = FutureProvider<List<rust.Contact>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final contacts = await rust.getContacts();
  return contacts;
});

final currentRoomIdProvider = StateProvider<String?>((ref) => null);

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
final mxcUrlCacheProvider = StateProvider<Map<String, String>>((ref) => {});

Future<String?> resolveMxcUrl(WidgetRef ref, String? mxcUrl) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;

  // Check cache first
  final cache = ref.read(mxcUrlCacheProvider);
  if (cache.containsKey(mxcUrl)) return cache[mxcUrl];

  try {
    final httpUrl = await rust.mxcToHttp(mxcUrl: mxcUrl);
    if (httpUrl != null) {
      ref.read(mxcUrlCacheProvider.notifier).state = {
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
  final subscription = stream.listen((event) {
    switch (event) {
      case rust.SyncEvent_SyncCompleted():
        // A sync round completed — refresh room list always
        ref.invalidate(chatRoomsProvider);
        // Refresh messages for the currently open room, but debounce to avoid flicker
        final currentRoomId = ref.read(currentRoomIdProvider);
        if (currentRoomId != null) {
          final now = DateTime.now();
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
    subscription.cancel();
  });

  return subscription;
});
