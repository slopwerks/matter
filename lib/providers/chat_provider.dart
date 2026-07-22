import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'auth_provider.dart';
import 'connection_provider.dart';
import 'message_cache_persistence.dart';
import 'message_ordering.dart';
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
  await syncStoredSessionTokens(userId);
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
  try {
    await rust.syncOnce();
    initialSyncSucceeded = true;
    ref.read(connectionProvider.notifier).value = AppConnectionState.connected;
    invalidateSessionCollections(ref);
  } catch (e) {
    debugPrint('$attemptLabel failed: $e');
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

Future<bool> _canPersistMessagesForRoom(dynamic read, String roomId) async {
  final knownRooms =
      (read(chatRoomsProvider) as AsyncValue<List<rust.ChatRoom>>)
          .asData
          ?.value;
  if (knownRooms != null) {
    for (final room in knownRooms) {
      if (room.id == roomId) {
        return !room.isEncrypted;
      }
    }
  }
  try {
    return !await rust.isRoomEncrypted(roomId: roomId);
  } catch (_) {
    return false;
  }
}

/// In-memory snapshot of the latest fetched messages per room.
///
/// The UI watches this instead of [messagesProvider] directly so that
/// re-entering a chat or receiving a sync event doesn't blank the list while
/// a fresh fetch is in flight. On first entry the disk cache is loaded into
/// here instantly (see [primeMessageCache]); later fetches update it via
/// [updateMessageCache]. See `message_cache_persistence.dart` for the disk
/// tier.
final messageCacheProvider =
    NotifierProvider.family<
      MutableState<List<rust.ChatMessage>>,
      List<rust.ChatMessage>,
      String
    >((_) => MutableState(const <rust.ChatMessage>[]));

final messageCachePrimedProvider =
    NotifierProvider.family<MutableState<bool>, bool, String>(
      (_) => MutableState(false),
    );

final messageCacheOwnerProvider =
    NotifierProvider.family<MutableState<String?>, String?, String>(
      (_) => MutableState(null),
    );

const unableToDecryptMessageContent = '无法解密此消息（缺少会话密钥）';

bool isUnableToDecryptPlaceholder(rust.ChatMessage message) {
  return message.msgType == rust.MessageType.text &&
      message.content == unableToDecryptMessageContent &&
      message.imageUrl == null &&
      message.mediaSourceJson == null;
}

rust.ChatMessage chooseMessageForSameEvent(
  rust.ChatMessage existing,
  rust.ChatMessage incoming,
) {
  final existingUnableToDecrypt = isUnableToDecryptPlaceholder(existing);
  final incomingUnableToDecrypt = isUnableToDecryptPlaceholder(incoming);
  if (existingUnableToDecrypt && !incomingUnableToDecrypt) return incoming;
  if (!existingUnableToDecrypt && incomingUnableToDecrypt) return existing;
  return incoming;
}

List<rust.ChatMessage> mergeMessageSnapshotAdditions(
  List<rust.ChatMessage> current,
  List<rust.ChatMessage> incoming,
) {
  if (incoming.isEmpty) return current;
  final byId = <String, rust.ChatMessage>{
    for (final message in current) message.id: message,
  };
  var changed = false;
  for (final message in incoming) {
    final existing = byId[message.id];
    if (existing == null) {
      byId[message.id] = message;
      changed = true;
      continue;
    }
    final selected = chooseMessageForSameEvent(existing, message);
    if (selected != existing) {
      byId[message.id] = selected;
      changed = true;
    }
  }
  if (!changed) return current;
  return byId.values.toList()..sort(compareChatMessages);
}

List<rust.ChatMessage> updateMessageCache(
  WidgetRef ref,
  String roomId,
  List<rust.ChatMessage> messages,
) {
  final current = ref.read(messageCacheProvider(roomId));
  final reconciled = reconcileMessageSnapshot(current, messages);
  if (current.length == reconciled.length) {
    var same = true;
    for (var i = 0; i < reconciled.length; i++) {
      if (reconciled[i] != current[i]) {
        same = false;
        break;
      }
    }
    if (same) return current;
  }
  ref.read(messageCacheProvider(roomId).notifier).value = reconciled;
  return reconciled;
}

/// Replaces the server's current window while retaining older cached history.
/// An empty refresh is treated as transient when a snapshot is already visible.
List<rust.ChatMessage> reconcileMessageSnapshot(
  List<rust.ChatMessage> current,
  List<rust.ChatMessage> latest,
) {
  if (latest.isEmpty) return current;
  if (current.isEmpty) return latest;

  final oldestLatestTimestamp = latest
      .map((message) => int.tryParse(message.timestamp) ?? 0)
      .reduce(math.min);
  final currentById = <String, rust.ChatMessage>{
    for (final message in current) message.id: message,
  };
  final byId = <String, rust.ChatMessage>{};
  for (final message in current) {
    if ((int.tryParse(message.timestamp) ?? 0) < oldestLatestTimestamp) {
      byId[message.id] = message;
    }
  }
  for (final message in latest) {
    final existing = currentById[message.id] ?? byId[message.id];
    byId[message.id] = existing == null
        ? message
        : chooseMessageForSameEvent(existing, message);
  }
  return byId.values.toList()..sort(compareChatMessages);
}

/// Populate the in-memory cache from disk for a room. Called once when a chat
/// is opened so the previous snapshot renders instantly while a network fetch
/// runs in the background. Safe to call repeatedly; no-ops after the first
/// successful priming for a given room.
Future<void> primeMessageCache(WidgetRef ref, String roomId) async {
  final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
  final allowDiskCache = await _canPersistMessagesForRoom(ref.read, roomId);
  final owner = ref.read(messageCacheOwnerProvider(roomId));
  if (owner != namespace) {
    ref.read(messageCacheProvider(roomId).notifier).value = const [];
    ref.read(messageCachePrimedProvider(roomId).notifier).value = false;
    ref.read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
  }
  if (ref.read(messageCachePrimedProvider(roomId))) return;
  if (!allowDiskCache) {
    await clearCachedMessagesForRoom(namespace: namespace, roomId: roomId);
  }
  final cached = await loadCachedMessages(
    namespace: namespace,
    roomId: roomId,
    allowDiskRead: allowDiskCache,
  );
  final current = ref.read(messageCacheProvider(roomId));
  if (current.isEmpty && cached.isNotEmpty) {
    ref.read(messageCacheProvider(roomId).notifier).value = cached;
  }
  ref.read(messageCachePrimedProvider(roomId).notifier).value = true;
}

/// Background refresh of a room's messages that also reconciles the result into
/// the in-memory cache and the disk snapshot. Used by the UI in place of a
/// bare [messagesProvider] watch so the list never goes blank mid-fetch.
Future<void> refreshMessagesFromNetwork(WidgetRef ref, String roomId) async {
  final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
  ref.invalidate(messagesProvider(roomId));
  try {
    final latest = await ref.read(messagesProvider(roomId).future);
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    final allowDiskCache = await _canPersistMessagesForRoom(ref.read, roomId);
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    ref.read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
    final reconciled = updateMessageCache(ref, roomId, latest);
    // Persist off the widget tree so a slow disk write never blocks the UI.
    Future.microtask(
      () => saveCachedMessages(
        namespace: namespace,
        roomId: roomId,
        messages: reconciled,
        persistToDisk: allowDiskCache,
      ),
    );
  } catch (_) {
    // Keep the existing cached snapshot on failure; the caller decides whether
    // to surface an error.
  }
}

const localOutgoingPendingPrefix = 'local_outgoing_pending:';
const localOutgoingSentPrefix = 'local_outgoing_sent:';
const localOutgoingFailedPrefix = 'local_outgoing_failed:';

bool isLocalOutgoingMessage(String id) =>
    id.startsWith(localOutgoingPendingPrefix) ||
    id.startsWith(localOutgoingSentPrefix) ||
    id.startsWith(localOutgoingFailedPrefix);

bool isLocalOutgoingSentMessage(String id) =>
    id.startsWith(localOutgoingSentPrefix);

bool isLocalOutgoingFailedMessage(String id) =>
    id.startsWith(localOutgoingFailedPrefix);

String failedLocalOutgoingId(String pendingId) {
  if (!pendingId.startsWith(localOutgoingPendingPrefix)) return pendingId;
  return '$localOutgoingFailedPrefix${pendingId.substring(localOutgoingPendingPrefix.length)}';
}

String sentLocalOutgoingId(String pendingId) {
  if (!pendingId.startsWith(localOutgoingPendingPrefix)) return pendingId;
  return '$localOutgoingSentPrefix${pendingId.substring(localOutgoingPendingPrefix.length)}';
}

class LocalOutgoingMessage {
  final rust.ChatMessage message;
  final String? sourceImageUrl;

  const LocalOutgoingMessage({required this.message, this.sourceImageUrl});
}

final localOutgoingMessagesProvider =
    NotifierProvider.family<
      MutableState<List<LocalOutgoingMessage>>,
      List<LocalOutgoingMessage>,
      String
    >((_) => MutableState(const <LocalOutgoingMessage>[]));

void upsertLocalOutgoingMessage(
  WidgetRef ref,
  String roomId,
  LocalOutgoingMessage message,
) {
  final messages = ref.read(localOutgoingMessagesProvider(roomId));
  final index = messages.indexWhere(
    (existing) => existing.message.id == message.message.id,
  );
  if (index == -1) {
    ref.read(localOutgoingMessagesProvider(roomId).notifier).value = [
      ...messages,
      message,
    ];
    return;
  }

  final next = [...messages];
  next[index] = message;
  ref.read(localOutgoingMessagesProvider(roomId).notifier).value = next;
}

void removeLocalOutgoingMessage(
  WidgetRef ref,
  String roomId,
  String messageId,
) {
  final messages = ref.read(localOutgoingMessagesProvider(roomId));
  ref.read(localOutgoingMessagesProvider(roomId).notifier).value = messages
      .where((message) => message.message.id != messageId)
      .toList();
}

String markLocalOutgoingMessageSent(
  WidgetRef ref,
  String roomId,
  String pendingId,
) {
  final sentId = sentLocalOutgoingId(pendingId);
  final messages = ref.read(localOutgoingMessagesProvider(roomId));
  final index = messages.indexWhere(
    (message) => message.message.id == pendingId,
  );
  if (index == -1) return sentId;

  final local = messages[index];
  final message = local.message;
  final next = [...messages];
  next[index] = LocalOutgoingMessage(
    message: rust.ChatMessage(
      id: sentId,
      senderId: message.senderId,
      senderName: message.senderName,
      content: message.content,
      formattedBody: message.formattedBody,
      caption: message.caption,
      captionFormattedBody: message.captionFormattedBody,
      mentionedUserIds: message.mentionedUserIds,
      mentionsRoom: message.mentionsRoom,
      timestamp: message.timestamp,
      isMe: message.isMe,
      msgType: message.msgType,
      imageUrl: message.imageUrl,
      mediaSourceJson: message.mediaSourceJson,
      imageWidth: message.imageWidth,
      imageHeight: message.imageHeight,
      inReplyTo: message.inReplyTo,
      isEdited: message.isEdited,
      editHistory: message.editHistory,
      reactions: message.reactions,
      readers: message.readers,
      totalMembers: message.totalMembers,
    ),
    sourceImageUrl: local.sourceImageUrl,
  );
  ref.read(localOutgoingMessagesProvider(roomId).notifier).value = next;
  return sentId;
}

Future<void> refreshMessagesRef(Ref ref, String roomId) async {
  final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
  ref.invalidate(messagesProvider(roomId));
  // Reconcile the fresh fetch into the in-memory cache + disk snapshot so the
  // UI (which watches messageCacheProvider) never has to flip through a
  // loading state. This is the path used by syncStreamProvider.
  try {
    final latest = await ref.read(messagesProvider(roomId).future);
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    final allowDiskCache = await _canPersistMessagesForRoom(ref.read, roomId);
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    ref.read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
    final current = ref.read(messageCacheProvider(roomId));
    final reconciled = reconcileMessageSnapshot(current, latest);
    if (!identical(reconciled, current)) {
      ref.read(messageCacheProvider(roomId).notifier).value = reconciled;
    }
    unawaited(
      saveCachedMessages(
        namespace: namespace,
        roomId: roomId,
        messages: reconciled,
        persistToDisk: allowDiskCache,
      ),
    );
  } catch (_) {
    // Keep the existing snapshot on failure.
  }
}

Future<void> refreshMessages(WidgetRef ref, String roomId) {
  // Route through the cache-aware refresh so every caller (send, reaction,
  // etc.) keeps both the in-memory snapshot and the disk cache in sync.
  return refreshMessagesFromNetwork(ref, roomId);
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

String? cachedResolvedMxcUrl(
  WidgetRef ref,
  String? mxcUrl, {
  int? width,
  int? height,
}) {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);
  return ref.read(mxcUrlCacheProvider)[cacheKey];
}

void rememberResolvedMxcUrl(
  WidgetRef ref,
  String? mxcUrl,
  String? httpUrl, {
  int? width,
  int? height,
}) {
  if (mxcUrl == null ||
      httpUrl == null ||
      !mxcUrl.startsWith('mxc://') ||
      httpUrl.isEmpty) {
    return;
  }
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);
  final cache = ref.read(mxcUrlCacheProvider);
  if (cache[cacheKey] == httpUrl) return;
  ref.read(mxcUrlCacheProvider.notifier).value = {...cache, cacheKey: httpUrl};
  unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
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
    message: rust.FormattedMessageInput(
      body: message,
      mentionedUserIds: const [],
      mentionsRoom: false,
    ),
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
      var messageRefreshInFlight = false;
      var messageRefreshTrailing = false;
      var disposed = false;

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

      late void Function(String roomId) scheduleMessageRefresh;

      Future<void> flushMessageRefreshes() async {
        if (disposed) return;
        if (messageRefreshInFlight) {
          messageRefreshTrailing = true;
          return;
        }
        final roomIds = pendingMessageRefreshes.toList();
        pendingMessageRefreshes.clear();
        if (roomIds.isEmpty) return;

        messageRefreshInFlight = true;
        try {
          await Future.wait(
            roomIds.map((roomId) => refreshMessagesRef(ref, roomId)),
          );
        } finally {
          messageRefreshInFlight = false;
          if (!disposed &&
              (messageRefreshTrailing || pendingMessageRefreshes.isNotEmpty)) {
            messageRefreshTrailing = false;
            for (final roomId in pendingMessageRefreshes.toList()) {
              scheduleMessageRefresh(roomId);
            }
          }
        }
      }

      scheduleMessageRefresh = (String roomId) {
        pendingMessageRefreshes.add(roomId);
        if (messageRefreshInFlight) {
          messageRefreshTrailing = true;
          return;
        }
        if (messageRefreshTimer != null) return;
        messageRefreshTimer = Timer(const Duration(milliseconds: 100), () {
          messageRefreshTimer = null;
          unawaited(flushMessageRefreshes());
        });
      };

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
            if (ref.read(currentRoomIdProvider) == roomId) {
              scheduleMessageRefresh(roomId);
            }
            scheduleRoomRefresh();
        }
      });

      ref.onDispose(() {
        disposed = true;
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
    Provider<StreamSubscription<rust.TypingNotification>?>((ref) {
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
