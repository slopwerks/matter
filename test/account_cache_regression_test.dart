import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

const _room = '!shared:example.org';
const _alice = '@alice:example.org';
const _bob = '@bob:example.org';

rust.ChatMessage _msg(String id, int timestamp) => rust.ChatMessage(
  id: id,
  senderId: _alice,
  senderName: 'Alice',
  content: id,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '$timestamp',
  isMe: true,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a stale snapshot cannot restore a recalled message on disk', () async {
    final snapshot = [_msg(r'$old', 100), _msg(r'$keep', 200)];
    await saveCachedMessages(
      namespace: _alice,
      roomId: _room,
      messages: snapshot,
    );
    await redactCachedMessage(
      namespace: _alice,
      roomId: _room,
      eventId: r'$old',
    );
    await saveCachedMessages(
      namespace: _alice,
      roomId: _room,
      messages: snapshot,
    );
    expect(
      (await loadCachedMessages(
        namespace: _alice,
        roomId: _room,
      )).map((m) => m.id),
      [r'$keep'],
    );
    expect(await loadCachedMessages(namespace: _bob, roomId: _room), isEmpty);
    await clearCachedMessagesForNamespace(_alice);
    expect(
      await loadCachedMessageRedactions(namespace: _alice, roomId: _room),
      isEmpty,
    );
  });
}
