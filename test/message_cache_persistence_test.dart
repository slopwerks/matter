import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/providers/message_ordering.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ChatMessage message(String id, String timestamp) => ChatMessage(
    id: id,
    senderId: '@alice:example.org',
    senderName: 'Alice',
    content: id,
    mentionedUserIds: const [],
    mentionsRoom: false,
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

  test(
    'local sort overrides preserve rapid send order after remote handoff',
    () {
      final messages =
          [message(r'$remote-b', '100'), message(r'$remote-a', '100')]..sort(
            (a, b) => compareChatMessagesWithOverrides(a, b, {
              r'$remote-b': 100,
              r'$remote-a': 200,
            }),
          );

      expect(messages.map((item) => item.id), [r'$remote-b', r'$remote-a']);
    },
  );

  test('message cache serialization preserves timeline fields', () {
    const message = ChatMessage(
      id: r'$event',
      senderId: '@alice:example.org',
      senderName: 'Alice',
      content: 'hello',
      formattedBody: '<strong>hello</strong>',
      caption: 'image description',
      captionFormattedBody: '<em>image description</em>',
      mentionedUserIds: ['@bob:example.org'],
      mentionsRoom: true,
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
    expect(restored.formattedBody, message.formattedBody);
    expect(restored.caption, message.caption);
    expect(restored.captionFormattedBody, message.captionFormattedBody);
    expect(restored.mentionedUserIds, message.mentionedUserIds);
    expect(restored.mentionsRoom, isTrue);
    expect(restored.inReplyTo, message.inReplyTo);
    expect(restored.isEdited, isTrue);
    expect(restored.editHistory, message.editHistory);
    expect(restored.reactions.single.key, 'ok');
    expect(restored.reactions.single.myEventId, r'$reaction');
    expect(restored.readers.single.userId, '@bob:example.org');
    expect(restored.totalMembers, 2);
  });

  test('message cache preserves the sticker message type', () {
    final sticker = message(r'$sticker', '100');
    final map = chatMessageToMap(
      ChatMessage(
        id: sticker.id,
        senderId: sticker.senderId,
        senderName: sticker.senderName,
        content: sticker.content,
        mentionedUserIds: const [],
        mentionsRoom: false,
        timestamp: sticker.timestamp,
        isMe: sticker.isMe,
        msgType: MessageType.sticker,
        imageUrl: 'mxc://example.org/sticker',
        isEdited: false,
        editHistory: const [],
        reactions: const [],
        readers: const [],
        totalMembers: 2,
      ),
    );

    expect(chatMessageFromMap(map).msgType, MessageType.sticker);
  });

  group('disk cache round-trip', () {
    test('saveCachedMessages persists messages to SharedPreferences', () async {
      const roomId = '!room:example.org';
      final messages = [message(r'$a', '100'), message(r'$b', '200')];

      await saveCachedMessages(
        namespace: '@alice:example.org',
        roomId: roomId,
        messages: messages,
      );

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(
        'msg_cache_v2_@alice:example.org::!room:example.org',
      );
      expect(stored, isNotNull);
      expect(stored, contains(r'$a'));
      expect(stored, contains(r'$b'));
    });

    test('loadCachedMessages restores persisted messages', () async {
      const roomId = '!room:example.org';
      final messages = [message(r'$a', '100'), message(r'$b', '200')];

      await saveCachedMessages(
        namespace: '@alice:example.org',
        roomId: roomId,
        messages: messages,
      );
      final restored = await loadCachedMessages(
        namespace: '@alice:example.org',
        roomId: roomId,
      );

      expect(restored.map((m) => m.id), [r'$a', r'$b']);
    });

    test(
      'loadCachedMessages returns empty list when cache is absent',
      () async {
        final messages = await loadCachedMessages(
          namespace: '@alice:example.org',
          roomId: '!room:example.org',
        );
        expect(messages, isEmpty);
      },
    );

    test(
      'loadCachedMessages returns empty list when payload is invalid',
      () async {
        SharedPreferences.setMockInitialValues({
          'msg_cache_v2_@alice:example.org::!room:example.org': 'not-json',
        });
        final messages = await loadCachedMessages(
          namespace: '@alice:example.org',
          roomId: '!room:example.org',
        );
        expect(messages, isEmpty);
      },
    );

    test('saveCachedMessages trims to the most recent messages', () async {
      final messages = <ChatMessage>[
        for (var i = 0; i < 210; i++) message('\$msg\$i', i.toString()),
      ];

      await saveCachedMessages(
        namespace: '@alice:example.org',
        roomId: '!room:example.org',
        messages: messages,
      );

      final restored = await loadCachedMessages(
        namespace: '@alice:example.org',
        roomId: '!room:example.org',
      );

      expect(restored.length, 200);
      expect(restored.first.timestamp, '10');
      expect(restored.last.timestamp, '209');
    });

    test(
      'saveCachedMessages removes existing disk cache when disabled',
      () async {
        const namespace = '@alice:example.org';
        const roomId = '!room:example.org';
        await saveCachedMessages(
          namespace: namespace,
          roomId: roomId,
          messages: [message(r'$a', '100')],
        );

        await saveCachedMessages(
          namespace: namespace,
          roomId: roomId,
          messages: [message(r'$secret', '200')],
          persistToDisk: false,
        );

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('msg_cache_v2_$namespace::$roomId'), isNull);
        expect(
          await loadCachedMessages(
            namespace: namespace,
            roomId: roomId,
            allowDiskRead: false,
          ),
          isEmpty,
        );
      },
    );

    test(
      'clearCachedMessagesForNamespace removes only matching account keys',
      () async {
        await saveCachedMessages(
          namespace: '@alice:example.org',
          roomId: '!one:example.org',
          messages: [message(r'$a', '100')],
        );
        await saveCachedMessages(
          namespace: '@bob:example.org',
          roomId: '!one:example.org',
          messages: [message(r'$b', '100')],
        );

        await clearCachedMessagesForNamespace('@alice:example.org');

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('msg_cache_v2_@alice:example.org::!one:example.org'),
          isNull,
        );
        expect(
          prefs.getString('msg_cache_v2_@bob:example.org::!one:example.org'),
          isNotNull,
        );
      },
    );
  });
}
