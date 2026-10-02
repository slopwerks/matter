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
const _kMsgCachePrefix = 'msg_cache_v2';
const _kMaxCachedMessagesPerRoom = 200;

String _msgStorageKey(String namespace, String roomId) =>
    '${_kMsgCachePrefix}_$namespace::$roomId';

String _redactionsStorageKey(String namespace, String roomId) =>
    '${_msgStorageKey(namespace, roomId)}_redacted';

Future<Set<String>> loadCachedMessageRedactions({
  required String namespace,
  required String roomId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs
          .getStringList(_redactionsStorageKey(namespace, roomId))
          ?.toSet() ??
      const <String>{};
}

/// Keep a tombstone so a late snapshot cannot persist a recalled message again.
Future<void> redactCachedMessage({
  required String namespace,
  required String roomId,
  required String eventId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final key = _redactionsStorageKey(namespace, roomId);
  final ids = {...?prefs.getStringList(key), eventId};
  await prefs.setStringList(key, ids.toList());
  final cacheKey = _msgStorageKey(namespace, roomId);
  final raw = prefs.getString(cacheKey);
  if (raw == null) return;
  final cached = jsonDecode(raw) as List<dynamic>;
  await prefs.setString(
    cacheKey,
    jsonEncode(
      cached
          .where(
            (message) => (message as Map<String, dynamic>)['id'] != eventId,
          )
          .toList(),
    ),
  );
}

/// Serialize a [rust.ChatMessage] to a JSON-encodable map.
Map<String, dynamic> chatMessageToMap(rust.ChatMessage message) {
  return {
    'id': message.id,
    'senderId': message.senderId,
    'senderName': message.senderName,
    'content': message.content,
    'formattedBody': message.formattedBody,
    'caption': message.caption,
    'captionFormattedBody': message.captionFormattedBody,
    'mentionedUserIds': message.mentionedUserIds,
    'mentionsRoom': message.mentionsRoom,
    'timestamp': message.timestamp,
    'isMe': message.isMe,
    'msgType': message.msgType.name,
    'imageUrl': message.imageUrl,
    'mediaSourceJson': message.mediaSourceJson,
    'imageWidth': message.imageWidth,
    'imageHeight': message.imageHeight,
    'filename': message.filename,
    'fileSize': message.fileSize,
    'geoUri': message.geoUri,
    'poll': message.poll == null
        ? null
        : {
            'question': message.poll!.question,
            'answers': message.poll!.answers
                .map((answer) => {'id': answer.id, 'text': answer.text})
                .toList(),
            'disclosed': message.poll!.disclosed,
            'maxSelections': message.poll!.maxSelections,
            'myAnswerIds': message.poll!.myAnswerIds,
            'results': message.poll!.results
                .map(
                  (result) => {
                    'answerId': result.answerId,
                    'count': result.count,
                    'isMine': result.isMine,
                  },
                )
                .toList(),
            'totalVoters': message.poll!.totalVoters,
            'ended': message.poll!.ended,
          },
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
    case 'sticker':
      msgType = rust.MessageType.sticker;
      break;
    case 'video':
      msgType = rust.MessageType.video;
      break;
    case 'file':
      msgType = rust.MessageType.file;
      break;
    case 'location':
      msgType = rust.MessageType.location;
      break;
    case 'poll':
      msgType = rust.MessageType.poll;
      break;
    case 'event':
      msgType = rust.MessageType.event;
      break;
    default:
      msgType = rust.MessageType.text;
  }

  final reactionsRaw = (map['reactions'] as List?) ?? const [];
  final readersRaw = (map['readers'] as List?) ?? const [];
  final pollRaw = map['poll'];
  final rust.PollInfo? poll = pollRaw is Map<String, dynamic>
      ? rust.PollInfo(
          question: (pollRaw['question'] as String?) ?? '',
          answers: ((pollRaw['answers'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(
                (answer) => rust.PollAnswerInfo(
                  id: (answer['id'] as String?) ?? '',
                  text: (answer['text'] as String?) ?? '',
                ),
              )
              .toList(),
          disclosed: (pollRaw['disclosed'] as bool?) ?? false,
          maxSelections: (pollRaw['maxSelections'] as num?)?.toInt() ?? 1,
          myAnswerIds: ((pollRaw['myAnswerIds'] as List?) ?? const [])
              .map((id) => '$id')
              .toList(),
          results: ((pollRaw['results'] as List?) ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(
                (result) => rust.PollAnswerResult(
                  answerId: (result['answerId'] as String?) ?? '',
                  count: (result['count'] as num?)?.toInt() ?? 0,
                  isMine: (result['isMine'] as bool?) ?? false,
                ),
              )
              .toList(),
          totalVoters: (pollRaw['totalVoters'] as num?)?.toInt() ?? 0,
          ended: (pollRaw['ended'] as bool?) ?? false,
        )
      : null;

  return rust.ChatMessage(
    id: (map['id'] as String?) ?? '',
    senderId: (map['senderId'] as String?) ?? '',
    senderName: (map['senderName'] as String?) ?? '',
    content: (map['content'] as String?) ?? '',
    formattedBody: map['formattedBody'] as String?,
    caption: map['caption'] as String?,
    captionFormattedBody: map['captionFormattedBody'] as String?,
    mentionedUserIds: ((map['mentionedUserIds'] as List?) ?? const [])
        .map((item) => '$item')
        .toList(),
    mentionsRoom: (map['mentionsRoom'] as bool?) ?? false,
    timestamp: (map['timestamp'] as String?) ?? '0',
    isMe: (map['isMe'] as bool?) ?? false,
    msgType: msgType,
    imageUrl: map['imageUrl'] as String?,
    mediaSourceJson: map['mediaSourceJson'] as String?,
    imageWidth: (map['imageWidth'] as num?)?.toInt(),
    imageHeight: (map['imageHeight'] as num?)?.toInt(),
    filename: map['filename'] as String?,
    fileSize: (map['fileSize'] as num?)?.toInt(),
    geoUri: map['geoUri'] as String?,
    poll: poll,
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
  bool allowDiskRead = true,
}) async {
  if (!allowDiskRead) return const <rust.ChatMessage>[];
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_msgStorageKey(namespace, roomId));
    if (raw == null || raw.isEmpty) return const <rust.ChatMessage>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <rust.ChatMessage>[];
    final redactedIds =
        prefs
            .getStringList(_redactionsStorageKey(namespace, roomId))
            ?.toSet() ??
        const <String>{};
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(chatMessageFromMap)
        .where((message) => !redactedIds.contains(message.id))
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
  bool persistToDisk = true,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final key = _msgStorageKey(namespace, roomId);
    if (!persistToDisk) {
      await prefs.remove(key);
      return;
    }
    final redactedIds =
        prefs
            .getStringList(_redactionsStorageKey(namespace, roomId))
            ?.toSet() ??
        const <String>{};
    final sorted =
        messages.where((message) => !redactedIds.contains(message.id)).toList()
          ..sort(compareChatMessages);
    final trimmed = sorted.length > _kMaxCachedMessagesPerRoom
        ? sorted.sublist(sorted.length - _kMaxCachedMessagesPerRoom)
        : sorted;
    final encoded = jsonEncode(trimmed.map(chatMessageToMap).toList());
    await prefs.setString(key, encoded);
  } catch (error) {
    debugPrint('saveCachedMessages failed for $roomId: $error');
  }
}

Future<void> clearCachedMessagesForRoom({
  required String namespace,
  required String roomId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_msgStorageKey(namespace, roomId));
}

Future<void> clearCachedMessagesForNamespace(String namespace) async {
  final prefs = await SharedPreferences.getInstance();
  final prefix = '${_kMsgCachePrefix}_$namespace::';
  final keys = prefs.getKeys().where((key) => key.startsWith(prefix)).toList();
  for (final key in keys) {
    await prefs.remove(key);
  }
}
