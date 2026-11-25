import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

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
}
