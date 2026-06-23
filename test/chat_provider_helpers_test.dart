import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

rust.ChatMessage _message({
  required String id,
  required String timestamp,
  String? content,
  rust.MessageType msgType = rust.MessageType.text,
  String? imageUrl,
}) => rust.ChatMessage(
  id: id,
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: content ?? id,
  timestamp: timestamp,
  isMe: false,
  msgType: msgType,
  imageUrl: imageUrl,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

LocalOutgoingMessage _local({
  required String id,
  String timestamp = '100',
  rust.MessageType msgType = rust.MessageType.text,
}) => LocalOutgoingMessage(
  message: _message(id: id, timestamp: timestamp, msgType: msgType),
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
  });

  group('local outgoing message state', () {
    testWidgets('upsert adds a new local message', (tester) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);

      upsertLocalOutgoingMessage(
        ref,
        roomId,
        _local(id: '${localOutgoingPendingPrefix}1'),
      );
      expect(ref.read(localOutgoingMessagesProvider(roomId)).length, 1);

      upsertLocalOutgoingMessage(
        ref,
        roomId,
        _local(id: '${localOutgoingPendingPrefix}2'),
      );
      expect(ref.read(localOutgoingMessagesProvider(roomId)).length, 2);
    });

    testWidgets('upsert replaces an existing local message', (tester) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      const id = '${localOutgoingPendingPrefix}1';

      upsertLocalOutgoingMessage(ref, roomId, _local(id: id, timestamp: '100'));
      upsertLocalOutgoingMessage(ref, roomId, _local(id: id, timestamp: '200'));

      final messages = ref.read(localOutgoingMessagesProvider(roomId));
      expect(messages.length, 1);
      expect(messages.single.message.timestamp, '200');
    });

    testWidgets('remove deletes the local message', (tester) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      const id = '${localOutgoingPendingPrefix}1';

      upsertLocalOutgoingMessage(ref, roomId, _local(id: id));
      removeLocalOutgoingMessage(ref, roomId, id);
      expect(ref.read(localOutgoingMessagesProvider(roomId)), isEmpty);
    });

    testWidgets('mark sent rewrites the pending id', (tester) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      const pendingId = '${localOutgoingPendingPrefix}flight';

      upsertLocalOutgoingMessage(ref, roomId, _local(id: pendingId));
      final sentId = markLocalOutgoingMessageSent(ref, roomId, pendingId);

      expect(sentId, '${localOutgoingSentPrefix}flight');
      final ids = ref
          .read(localOutgoingMessagesProvider(roomId))
          .map((m) => m.message.id);
      expect(ids, [sentId]);
    });

    testWidgets('mark sent is a no-op when the pending message is gone', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      const pendingId = '${localOutgoingPendingPrefix}missing';

      final sentId = markLocalOutgoingMessageSent(ref, roomId, pendingId);
      expect(sentId, '${localOutgoingSentPrefix}missing');
      expect(ref.read(localOutgoingMessagesProvider(roomId)), isEmpty);
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
}
