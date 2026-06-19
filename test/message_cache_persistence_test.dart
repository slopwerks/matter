import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/providers/message_ordering.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';

void main() {
  ChatMessage message(String id, String timestamp) => ChatMessage(
    id: id,
    senderId: '@alice:example.org',
    senderName: 'Alice',
    content: id,
    timestamp: timestamp,
    isMe: false,
    msgType: MessageType.text,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  );

  test('an empty refresh cannot erase a visible message snapshot', () {
    final current = [message(r'$old', '100')];

    expect(reconcileMessageSnapshot(current, const []), same(current));
  });

  test('a refresh replaces its window and retains older cached history', () {
    final current = [message(r'$old', '100'), message(r'$replaced', '200')];
    final latest = [message(r'$replacement', '200'), message(r'$new', '300')];

    expect(reconcileMessageSnapshot(current, latest).map((item) => item.id), [
      r'$old',
      r'$replacement',
      r'$new',
    ]);
  });

  test('same-timestamp messages have deterministic event-id ordering', () {
    final messages = [message(r'$z', '100'), message(r'$a', '100')]
      ..sort(compareChatMessages);

    expect(messages.map((item) => item.id), [r'$a', r'$z']);
  });

  test('message cache serialization preserves timeline fields', () {
    const message = ChatMessage(
      id: r'$event',
      senderId: '@alice:example.org',
      senderName: 'Alice',
      content: 'hello',
      timestamp: '1781798400000',
      isMe: true,
      msgType: MessageType.text,
      inReplyTo: r'$parent',
      isEdited: true,
      editHistory: ['hi'],
      reactions: [
        Reaction(key: 'ok', senders: ['Alice'], myEventId: r'$reaction'),
      ],
      readers: [
        MessageReader(
          userId: '@bob:example.org',
          displayName: 'Bob',
          avatarUrl: 'mxc://example.org/avatar',
        ),
      ],
      totalMembers: 2,
    );

    final restored = chatMessageFromMap(chatMessageToMap(message));

    expect(restored.id, message.id);
    expect(restored.inReplyTo, message.inReplyTo);
    expect(restored.isEdited, isTrue);
    expect(restored.editHistory, message.editHistory);
    expect(restored.reactions.single.key, 'ok');
    expect(restored.reactions.single.myEventId, r'$reaction');
    expect(restored.readers.single.userId, '@bob:example.org');
    expect(restored.totalMembers, 2);
  });
}
