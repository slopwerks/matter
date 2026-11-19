import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

const _roomAccountKey = (
  roomId: '!room:example.org',
  userId: '@alice:example.org',
);

rust.ChatMessage _message({
  required String id,
  required String timestamp,
  String? content,
  rust.MessageType msgType = rust.MessageType.text,
  String? imageUrl,
  List<String> mentionedUserIds = const [],
  List<String> editHistory = const [],
  List<rust.Reaction> reactions = const [],
  List<rust.MessageReader> readers = const [],
  rust.PollInfo? poll,
}) => rust.ChatMessage(
  id: id,
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: content ?? id,
  mentionedUserIds: mentionedUserIds,
  mentionsRoom: false,
  timestamp: timestamp,
  isMe: false,
  msgType: msgType,
  imageUrl: imageUrl,
  poll: poll,
  isEdited: false,
  editHistory: editHistory,
  reactions: reactions,
  readers: readers,
  totalMembers: 2,
);

LocalOutgoingMessage _local({
  required String id,
  String timestamp = '100',
  rust.MessageType msgType = rust.MessageType.text,
  String? replyToUserId,
}) => LocalOutgoingMessage(
  message: _message(id: id, timestamp: timestamp, msgType: msgType),
  replyToUserId: replyToUserId,
);

Future<WidgetRef> _captureRef(WidgetTester tester) async {
  WidgetRef? ref;
  await tester.pumpWidget(
    ProviderScope(
      child: Consumer(
        builder: (context, r, _) {
          ref = r;
          return Container();
        },
      ),
    ),
  );
  return ref!;
}

void main() {
  group('local outgoing id helpers', () {
    test('detect local outgoing prefixes', () {
      expect(isLocalOutgoingMessage('${localOutgoingPendingPrefix}a'), isTrue);
      expect(isLocalOutgoingMessage('${localOutgoingSentPrefix}a'), isTrue);
      expect(isLocalOutgoingMessage('${localOutgoingFailedPrefix}a'), isTrue);
      expect(isLocalOutgoingMessage(r'$real-event'), isFalse);
      expect(isLocalOutgoingMessage('local_outgoing_other:a'), isFalse);
    });

    test('detect sent and failed states', () {
      expect(isLocalOutgoingSentMessage('${localOutgoingSentPrefix}a'), isTrue);
      expect(
        isLocalOutgoingSentMessage('${localOutgoingPendingPrefix}a'),
        isFalse,
      );
      expect(
        isLocalOutgoingFailedMessage('${localOutgoingFailedPrefix}a'),
        isTrue,
      );
      expect(
        isLocalOutgoingFailedMessage('${localOutgoingPendingPrefix}a'),
        isFalse,
      );
    });

    test('promote pending id to sent', () {
      expect(
        sentLocalOutgoingId('${localOutgoingPendingPrefix}42'),
        '${localOutgoingSentPrefix}42',
      );
    });

    test('promote pending id to failed', () {
      expect(
        failedLocalOutgoingId('${localOutgoingPendingPrefix}42'),
        '${localOutgoingFailedPrefix}42',
      );
    });

    test('non-pending ids pass through unchanged', () {
      const real = r'$real-event';
      expect(sentLocalOutgoingId(real), real);
      expect(failedLocalOutgoingId(real), real);
    });
  });

  group('message snapshot reconciliation', () {
    test('empty refresh keeps the current snapshot', () {
      final current = [_message(id: r'$old', timestamp: '100')];
      expect(reconcileMessageSnapshot(current, const []), same(current));
    });

    test('empty current adopts the latest window', () {
      final latest = [_message(id: r'$new', timestamp: '100')];
      expect(reconcileMessageSnapshot(const [], latest), same(latest));
    });

    test('latest window replaces overlapping current messages', () {
      final current = [
        _message(id: r'$a', timestamp: '100'),
        _message(id: r'$b', timestamp: '200'),
        _message(id: r'$c', timestamp: '300'),
      ];
      final latest = [
        _message(id: r'$b2', timestamp: '200'),
        _message(id: r'$c', timestamp: '300'),
        _message(id: r'$d', timestamp: '400'),
      ];
      final result = reconcileMessageSnapshot(current, latest);
      expect(result.map((m) => m.id), [r'$a', r'$b2', r'$c', r'$d']);
    });

    test('older history is preserved when latest starts later', () {
      final current = [
        _message(id: r'$old1', timestamp: '50'),
        _message(id: r'$old2', timestamp: '100'),
      ];
      final latest = [_message(id: r'$new', timestamp: '200')];
      final result = reconcileMessageSnapshot(current, latest);
      expect(result.map((m) => m.id), [r'$old1', r'$old2', r'$new']);
    });

    test('result is sorted by timestamp then id', () {
      final current = [_message(id: r'$old', timestamp: '50')];
      final latest = [
        _message(id: r'$z', timestamp: '100'),
        _message(id: r'$a', timestamp: '100'),
      ];
      final result = reconcileMessageSnapshot(current, latest);
      expect(result.map((m) => m.id), [r'$old', r'$a', r'$z']);
    });

    test('latest window can replace an unable-to-decrypt placeholder', () {
      final current = [
        _message(
          id: r'$event',
          timestamp: '100',
          content: unableToDecryptMessageContent,
        ),
      ];
      final latest = [
        _message(id: r'$event', timestamp: '100', content: 'decrypted'),
      ];

      final result = reconcileMessageSnapshot(current, latest);

      expect(result.single.content, 'decrypted');
    });

    test('unable-to-decrypt refresh does not replace decrypted cache', () {
      final current = [
        _message(id: r'$event', timestamp: '100', content: 'decrypted'),
      ];
      final latest = [
        _message(
          id: r'$event',
          timestamp: '100',
          content: unableToDecryptMessageContent,
        ),
      ];

      final result = reconcileMessageSnapshot(current, latest);

      expect(result.single.content, 'decrypted');
    });

    test('historical additions replace cached unable-to-decrypt messages', () {
      final current = [
        _message(
          id: r'$old',
          timestamp: '100',
          content: unableToDecryptMessageContent,
        ),
        _message(id: r'$new', timestamp: '200'),
      ];
      final incoming = [
        _message(id: r'$old', timestamp: '100', content: 'decrypted'),
      ];

      final result = mergeMessageSnapshotAdditions(current, incoming);

      expect(result.map((m) => m.id), [r'$old', r'$new']);
      expect(result.first.content, 'decrypted');
    });

    test('content equality compares generated list fields by value', () {
      rust.ChatMessage build(List<String> senders) => _message(
        id: r'$event',
        timestamp: '100',
        mentionedUserIds: List.of(['@bob:example.org']),
        editHistory: List.of(['old body']),
        reactions: [
          rust.Reaction(key: '+1', senders: senders, myEventId: r'$reaction'),
        ],
        readers: const [
          rust.MessageReader(userId: '@bob:example.org', displayName: 'Bob'),
        ],
      );

      final current = build(List.of(['@bob:example.org']));
      final equivalent = build(List.of(['@bob:example.org']));
      final changed = build(List.of(['@carol:example.org']));

      expect(chatMessageContentEquals(current, equivalent), isTrue);
      expect(chatMessageContentEquals(current, changed), isFalse);
      final cached = [current];
      expect(mergeMessageSnapshotAdditions(cached, [equivalent]), same(cached));
    });
  });

  group('local outgoing message state', () {
    testWidgets('upsert adds a new local message', (tester) async {
      final ref = await _captureRef(tester);

      upsertLocalOutgoingMessage(
        ref,
        _roomAccountKey,
        _local(id: '${localOutgoingPendingPrefix}1'),
      );
      expect(
        ref.read(localOutgoingMessagesProvider(_roomAccountKey)).length,
        1,
      );

      upsertLocalOutgoingMessage(
        ref,
        _roomAccountKey,
        _local(id: '${localOutgoingPendingPrefix}2'),
      );
      expect(
        ref.read(localOutgoingMessagesProvider(_roomAccountKey)).length,
        2,
      );
    });

    testWidgets('upsert replaces an existing local message', (tester) async {
      final ref = await _captureRef(tester);
      const id = '${localOutgoingPendingPrefix}1';

      upsertLocalOutgoingMessage(
        ref,
        _roomAccountKey,
        _local(id: id, timestamp: '100'),
      );
      upsertLocalOutgoingMessage(
        ref,
        _roomAccountKey,
        _local(id: id, timestamp: '200'),
      );

      final messages = ref.read(localOutgoingMessagesProvider(_roomAccountKey));
      expect(messages.length, 1);
      expect(messages.single.message.timestamp, '200');
    });

    testWidgets('remove deletes the local message', (tester) async {
      final ref = await _captureRef(tester);
      const id = '${localOutgoingPendingPrefix}1';

      upsertLocalOutgoingMessage(ref, _roomAccountKey, _local(id: id));
      removeLocalOutgoingMessage(ref, _roomAccountKey, id);
      expect(ref.read(localOutgoingMessagesProvider(_roomAccountKey)), isEmpty);
    });

    testWidgets('mark sent rewrites the pending id', (tester) async {
      final ref = await _captureRef(tester);
      const pendingId = '${localOutgoingPendingPrefix}flight';

      upsertLocalOutgoingMessage(ref, _roomAccountKey, _local(id: pendingId));
      final sentId = markLocalOutgoingMessageSent(
        ref,
        _roomAccountKey,
        pendingId,
      );

      expect(sentId, '${localOutgoingSentPrefix}flight');
      final ids = ref
          .read(localOutgoingMessagesProvider(_roomAccountKey))
          .map((m) => m.message.id);
      expect(ids, [sentId]);
    });

    testWidgets('mark sent preserves reply sender metadata', (tester) async {
      final ref = await _captureRef(tester);
      const pendingId = '${localOutgoingPendingPrefix}reply';

      upsertLocalOutgoingMessage(
        ref,
        _roomAccountKey,
        _local(id: pendingId, replyToUserId: '@original-sender:example.org'),
      );
      markLocalOutgoingMessageSent(ref, _roomAccountKey, pendingId);

      expect(
        ref
            .read(localOutgoingMessagesProvider(_roomAccountKey))
            .single
            .replyToUserId,
        '@original-sender:example.org',
      );
    });

    testWidgets('mark sent is a no-op when the pending message is gone', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      const pendingId = '${localOutgoingPendingPrefix}missing';

      final sentId = markLocalOutgoingMessageSent(
        ref,
        _roomAccountKey,
        pendingId,
      );
      expect(sentId, '${localOutgoingSentPrefix}missing');
      expect(ref.read(localOutgoingMessagesProvider(_roomAccountKey)), isEmpty);
    });

    testWidgets('composer state is isolated by account in the same room', (
      tester,
    ) async {
      const bobKey = (roomId: '!room:example.org', userId: '@bob:example.org');
      final ref = await _captureRef(tester);
      final message = _message(id: r'$local', timestamp: '100');

      upsertLocalOutgoingMessage(
        ref,
        _roomAccountKey,
        LocalOutgoingMessage(message: message),
      );
      ref.read(replyingToProvider(_roomAccountKey).notifier).value = message;
      ref.read(editingMessageProvider(_roomAccountKey).notifier).value =
          message;

      expect(ref.read(localOutgoingMessagesProvider(bobKey)), isEmpty);
      expect(ref.read(replyingToProvider(bobKey)), isNull);
      expect(ref.read(editingMessageProvider(bobKey)), isNull);
    });

    testWidgets('updateMessageCache writes to the provider', (tester) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      final messages = [_message(id: r'$1', timestamp: '100')];

      final result = updateMessageCache(ref, roomId, messages);
      expect(result, messages);
      expect(ref.read(messageCacheProvider(roomId)), messages);
    });

    testWidgets('updateMessageCache returns the existing list when unchanged', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      final messages = [_message(id: r'$1', timestamp: '100')];

      updateMessageCache(ref, roomId, messages);
      final second = updateMessageCache(ref, roomId, messages);

      expect(second, same(ref.read(messageCacheProvider(roomId))));
    });
  });

  testWidgets('latest auto-read suppression intent owns rollback', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final ref = await _captureRef(tester);
    ref.read(sessionReadyProvider.notifier).value = true;

    final readToken = setRoomAutoReadSuppressed(ref, roomId, suppressed: false);
    final unreadToken = setRoomAutoReadSuppressed(
      ref,
      roomId,
      suppressed: true,
    );

    expect(readToken.isCurrent, isFalse);
    expect(unreadToken.isCurrent, isTrue);
    expect(ref.read(roomAutoReadSuppressedProvider(roomId)), isTrue);
  });

  testWidgets('session invalidation makes a suppression token stale', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final ref = await _captureRef(tester);
    ref.read(sessionReadyProvider.notifier).value = true;
    final token = setRoomAutoReadSuppressed(ref, roomId, suppressed: true);

    ref.invalidate(roomAutoReadSuppressionRevisionProvider(roomId));

    expect(token.isCurrent, isFalse);
  });

  testWidgets('account transition makes a suppression token stale', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final ref = await _captureRef(tester);
    ref.read(sessionReadyProvider.notifier).value = true;
    ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final token = setRoomAutoReadSuppressed(ref, roomId, suppressed: true);

    ref.read(sessionReadyProvider.notifier).value = false;
    ref.read(activeUserIdProvider.notifier).value = '@bob:example.org';

    expect(token.isCurrent, isFalse);
  });
}
