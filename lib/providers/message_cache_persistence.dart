import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'message_ordering.dart';

/// Two-tier message cache for the chat timeline.
///
/// Messages have no Dart-side persistence today: every refresh round-trips
/// through FFI into Rust. On a flaky connection (or when re-entering a chat)
/// this produces an empty/loading list until the fetch completes. This module
/// adds a disk-backed cache so the previous snapshot can be shown instantly,
/// while an in-memory provider (in chat_provider.dart) holds the live list
/// during the session.
///
/// Storage layout mirrors the persisted MXC URL cache: one SharedPreferences
/// key per room, namespaced by user id, capped per room and pruned to the most
/// recent messages.
const _kMsgCachePrefix = 'msg_cache_v1';
const _kMaxCachedMessagesPerRoom = 200;

String _msgStorageKey(String namespace, String roomId) =>
    '${_kMsgCachePrefix}_$namespace::$roomId';

/// Serialize a [rust.ChatMessage] to a JSON-encodable map.
Map<String, dynamic> chatMessageToMap(rust.ChatMessage message) {
  return {
    'id': message.id,
    'senderId': message.senderId,
    'senderName': message.senderName,
    'content': message.content,
    'timestamp': message.timestamp,
    'isMe': message.isMe,
    'msgType': message.msgType.name,
    'imageUrl': message.imageUrl,
    'mediaSourceJson': message.mediaSourceJson,
    'imageWidth': message.imageWidth,
    'imageHeight': message.imageHeight,
    'inReplyTo': message.inReplyTo,
    'isEdited': message.isEdited,
    'editHistory': message.editHistory,
    'reactions': message.reactions
        .map(
          (r) => {'key': r.key, 'senders': r.senders, 'myEventId': r.myEventId},
        )
        .toList(),
    'readers': message.readers
        .map(
          (r) => {
            'userId': r.userId,
            'displayName': r.displayName,
            'avatarUrl': r.avatarUrl,
          },
        )
        .toList(),
    'totalMembers': message.totalMembers,
  };
}

/// Deserialize a map back into a [rust.ChatMessage].
rust.ChatMessage chatMessageFromMap(Map<String, dynamic> map) {
  final msgTypeName = (map['msgType'] as String?) ?? 'text';
  rust.MessageType msgType;
  switch (msgTypeName) {
    case 'image':
      msgType = rust.MessageType.image;
      break;
    case 'video':
      msgType = rust.MessageType.video;
      break;
    case 'event':
      msgType = rust.MessageType.event;
      break;
    default:
      msgType = rust.MessageType.text;
  }

  final reactionsRaw = (map['reactions'] as List?) ?? const [];
  final readersRaw = (map['readers'] as List?) ?? const [];

  return rust.ChatMessage(
    id: (map['id'] as String?) ?? '',
    senderId: (map['senderId'] as String?) ?? '',
    senderName: (map['senderName'] as String?) ?? '',
    content: (map['content'] as String?) ?? '',
    timestamp: (map['timestamp'] as String?) ?? '0',
    isMe: (map['isMe'] as bool?) ?? false,
    msgType: msgType,
    imageUrl: map['imageUrl'] as String?,
    mediaSourceJson: map['mediaSourceJson'] as String?,
    imageWidth: (map['imageWidth'] as num?)?.toInt(),
    imageHeight: (map['imageHeight'] as num?)?.toInt(),
    inReplyTo: map['inReplyTo'] as String?,
    isEdited: (map['isEdited'] as bool?) ?? false,
    editHistory: ((map['editHistory'] as List?) ?? const [])
        .map((e) => '$e')
        .toList(),
    reactions: reactionsRaw.map((raw) {
      final m = raw as Map<String, dynamic>;
      return rust.Reaction(
        key: (m['key'] as String?) ?? '',
        senders: ((m['senders'] as List?) ?? const [])
            .map((s) => '$s')
            .toList(),
        myEventId: m['myEventId'] as String?,
      );
    }).toList(),
    readers: readersRaw.map((raw) {
      final m = raw as Map<String, dynamic>;
      return rust.MessageReader(
        userId: (m['userId'] as String?) ?? '',
        displayName: (m['displayName'] as String?) ?? '',
        avatarUrl: m['avatarUrl'] as String?,
      );
    }).toList(),
    totalMembers: (map['totalMembers'] as num?)?.toInt() ?? 0,
  );
}

/// Read the persisted snapshot for a room. Returns an empty list when there is
/// no cache yet or the payload fails to decode (treated as a cache miss).
Future<List<rust.ChatMessage>> loadCachedMessages({
  required String namespace,
  required String roomId,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_msgStorageKey(namespace, roomId));
    if (raw == null || raw.isEmpty) return const <rust.ChatMessage>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <rust.ChatMessage>[];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(chatMessageFromMap)
        .toList();
  } catch (error) {
    debugPrint('loadCachedMessages failed for $roomId: $error');
    return const <rust.ChatMessage>[];
  }
}

/// Persist the latest snapshot for a room, keeping at most the most recent
/// [_kMaxCachedMessagesPerRoom] messages (sorted by timestamp ascending so the
/// newest are retained after trimming).
Future<void> saveCachedMessages({
  required String namespace,
  required String roomId,
  required List<rust.ChatMessage> messages,
}) async {
  try {
    final sorted = [...messages]..sort(compareChatMessages);
    final trimmed = sorted.length > _kMaxCachedMessagesPerRoom
        ? sorted.sublist(sorted.length - _kMaxCachedMessagesPerRoom)
        : sorted;
    final encoded = jsonEncode(trimmed.map(chatMessageToMap).toList());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_msgStorageKey(namespace, roomId), encoded);
  } catch (error) {
    debugPrint('saveCachedMessages failed for $roomId: $error');
  }
}
