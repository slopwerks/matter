import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/timeline/timeline_plus_one.dart';
import 'package:matter/src/rust/api/matrix.dart';

ChatMessage _text(
  String id,
  String content, {
  MessageType msgType = MessageType.text,
  String timestamp = '0',
  bool isMe = false,
}) {
  return ChatMessage(
    id: id,
    senderId: '@bob:example.org',
    senderName: 'Bob',
    content: content,
    formattedBody: null,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: timestamp,
    isMe: isMe,
    msgType: msgType,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  );
}

void main() {
  test('my own newest copy carries the +1 too', () {
    final messages = [
      _text(r'$a', 'ok', timestamp: '1'),
      _text(r'$b', 'ok', timestamp: '2', isMe: true),
    ];

    // The newest copy bumps, mine included.
    expect(plusOneEligibleIds(messages), {r'$b'});
  });

  test('the same event listed twice is not a duplicate', () {
    final repeated = _text(r'$a', 'ok', timestamp: '1');
    final messages = [repeated, repeated];

    expect(plusOneEligibleIds(messages), isEmpty);
  });
  test('no inline +1 without a duplicate', () {
    final messages = [
      _text(r'$a', 'hello', timestamp: '1'),
      _text(r'$b', 'world', timestamp: '2'),
    ];

    expect(plusOneEligibleIds(messages), isEmpty);
  });

  test('a repeat further up the timeline does not count', () {
    final messages = [
      _text(r'$a', 'hello', timestamp: '1'),
      _text(r'$b', 'other', timestamp: '2'),
      _text(r'$c', 'hello', timestamp: '3'),
    ];

    expect(plusOneEligibleIds(messages), isEmpty);
  });

  test('an image between two identical texts breaks the repeat', () {
    final messages = [
      _text(r'$a', 'hello', timestamp: '1'),
      _text(r'$c', 'u.png', msgType: MessageType.image, timestamp: '2'),
      _text(r'$b', 'hello', timestamp: '3'),
    ];

    expect(plusOneEligibleIds(messages), isEmpty);
  });

  test('a newer message retires the +1 of an older pair', () {
    final messages = [
      _text(r'$a', 'hello', timestamp: '1'),
      _text(r'$b', 'hello', timestamp: '2'),
      _text(r'$c', 'other', timestamp: '3'),
    ];

    expect(plusOneEligibleIds(messages), isEmpty);
  });

  test('repeated text is matched after trimming, across senders', () {
    final messages = [
      _text(r'$a', 'hello', timestamp: '1'),
      _text(r'$b', '  hello  ', timestamp: '2'),
    ];

    expect(plusOneEligibleIds(messages), {r'$b'});
  });

  test('three copies keep a single +1 on the newest one', () {
    final messages = [
      _text(r'$a', 'hello', timestamp: '1'),
      _text(r'$b', 'hello', timestamp: '2'),
      _text(r'$c', 'hello', timestamp: '3'),
    ];

    expect(plusOneEligibleIds(messages), {r'$c'});
  });

  test('non-text and blank messages never offer +1', () {
    final messages = [
      _text(r'$a', 'u.png', msgType: MessageType.image, timestamp: '1'),
      _text(r'$b', 'u.png', msgType: MessageType.image, timestamp: '2'),
      _text(r'$c', '   ', timestamp: '3'),
      _text(r'$d', '   ', timestamp: '4'),
    ];

    expect(plusOneEligibleIds(messages), isEmpty);
  });

  test('a newest non-text message retires a duplicate pair', () {
    final messages = [
      _text(r'$a', 'hello', timestamp: '1'),
      _text(r'$b', 'hello', timestamp: '2'),
      _text(r'$c', 'u.png', msgType: MessageType.image, timestamp: '3'),
    ];

    expect(plusOneEligibleIds(messages), isEmpty);
  });
}
