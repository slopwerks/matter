import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/local_outgoing_matcher.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

rust.ChatMessage _remote({
  required String id,
  required String timestamp,
  required String content,
  rust.MessageType msgType = rust.MessageType.text,
  String? imageUrl,
  String? filename,
  String? mimeType,
  int? imageWidth,
  int? imageHeight,
  String? inReplyTo,
}) => rust.ChatMessage(
  id: id,
  senderId: '@me:example.org',
  senderName: 'Me',
  content: content,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: timestamp,
  isMe: true,
  msgType: msgType,
  imageUrl: imageUrl,
  filename: filename,
  mimeType: mimeType,
  imageWidth: imageWidth,
  imageHeight: imageHeight,
  inReplyTo: inReplyTo,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

LocalOutgoingMessage _local({
  required String id,
  required String timestamp,
  required String content,
  rust.MessageType msgType = rust.MessageType.text,
  String? sourceImageUrl,
  String? imageUrl,
  String? filename,
  String? mimeType,
  int? imageWidth,
  int? imageHeight,
  String? inReplyTo,
}) => LocalOutgoingMessage(
  message: rust.ChatMessage(
    id: id,
    senderId: '@me:example.org',
    senderName: 'Me',
    content: content,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: timestamp,
    isMe: true,
    msgType: msgType,
    imageUrl: imageUrl,
    filename: filename,
    mimeType: mimeType,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    inReplyTo: inReplyTo,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  ),
  sourceImageUrl: sourceImageUrl,
);

void main() {
  test('matches a single text local message with its remote event', () {
    final consumed = <String>{};
    final local = _local(
      id: 'local_outgoing_pending:1',
      timestamp: '1000',
      content: 'hi',
    );
    final remote = _remote(id: 'r1', timestamp: '1100', content: 'hi');
    final result = matchLocalOutgoingMessages([remote], [local], consumed);
    expect(result.localIds, {'local_outgoing_pending:1'});
    expect(result.remoteToLocalFlightId, {'r1': '1'});
    expect(result.remoteToLocalSortTimestamp, {'r1': 1000});
    expect(consumed, {'r1'});
  });

  test('matches alternating payloads in send order', () {
    final consumed = <String>{};
    final locals = [
      _local(id: 'local_outgoing_pending:a1', timestamp: '1000', content: 'a'),
      _local(id: 'local_outgoing_pending:b1', timestamp: '2000', content: 'b'),
      _local(id: 'local_outgoing_pending:a2', timestamp: '3000', content: 'a'),
      _local(id: 'local_outgoing_pending:b2', timestamp: '4000', content: 'b'),
    ];
    final remotes = [
      _remote(id: 'r:a1', timestamp: '1100', content: 'a'),
      _remote(id: 'r:b1', timestamp: '2100', content: 'b'),
      _remote(id: 'r:a2', timestamp: '3100', content: 'a'),
      _remote(id: 'r:b2', timestamp: '4100', content: 'b'),
    ];
    final result = matchLocalOutgoingMessages(remotes, locals, consumed);
    expect(result.localIds, {
      'local_outgoing_pending:a1',
      'local_outgoing_pending:b1',
      'local_outgoing_pending:a2',
      'local_outgoing_pending:b2',
    });
    expect(consumed, {'r:a1', 'r:b1', 'r:a2', 'r:b2'});
  });

  test('does not collapse identical text payloads sent at different times', () {
    final consumed = <String>{};
    final local1 = _local(
      id: 'local_outgoing_pending:1',
      timestamp: '1000',
      content: 'hi',
    );
    final local2 = _local(
      id: 'local_outgoing_pending:2',
      timestamp: '5000',
      content: 'hi',
    );
    final remote1 = _remote(id: 'r1', timestamp: '1100', content: 'hi');

    // First call: only the first local is present.
    var result = matchLocalOutgoingMessages([remote1], [local1], consumed);
    expect(result.localIds, {'local_outgoing_pending:1'});
    expect(consumed, {'r1'});

    // Second call: the second local arrives; r1 is already consumed.
    result = matchLocalOutgoingMessages([remote1], [local2], consumed);
    expect(result.localIds, isEmpty);
    expect(consumed, {'r1'});

    // Third call: the second remote arrives.
    final remote2 = _remote(id: 'r2', timestamp: '5100', content: 'hi');
    result = matchLocalOutgoingMessages([remote1, remote2], [local2], consumed);
    expect(result.localIds, {'local_outgoing_pending:2'});
    expect(consumed, {'r1', 'r2'});
  });

  test(
    'matches duplicate sends in order even when remotes arrive out of order',
    () {
      final consumed = <String>{};
      final local1 = _local(
        id: 'local_outgoing_pending:1',
        timestamp: '1000',
        content: 'hi',
      );
      final local2 = _local(
        id: 'local_outgoing_pending:2',
        timestamp: '5000',
        content: 'hi',
      );
      // Second remote arrives before the first.
      final remote2 = _remote(id: 'r2', timestamp: '5100', content: 'hi');
      final remote1 = _remote(id: 'r1', timestamp: '1100', content: 'hi');

      final result = matchLocalOutgoingMessages(
        [remote2, remote1],
        [local1, local2],
        consumed,
      );
      expect(result.localIds, {
        'local_outgoing_pending:1',
        'local_outgoing_pending:2',
      });
      expect(result.remoteToLocalFlightId, {'r1': '1', 'r2': '2'});
      expect(result.remoteToLocalSortTimestamp, {'r1': 1000, 'r2': 5000});
      expect(consumed, {'r1', 'r2'});
    },
  );

  group('optimistic image uploads', () {
    LocalOutgoingMessage uploaded({String? filename, String? mimeType}) =>
        _local(
          id: 'local_outgoing_pending:image',
          timestamp: '1000',
          content: 'photo.jpg',
          msgType: rust.MessageType.image,
          // No sourceImageUrl: the mxc URI does not exist until the upload is
          // done, so the echo has to be recognized by its declared metadata.
          imageUrl: 'local-preview:local_outgoing_pending:image',
          filename: filename ?? 'photo.jpg',
          mimeType: mimeType ?? 'image/jpeg',
          imageWidth: 1024,
          imageHeight: 768,
        );

    test('matches the echo by filename, mime type and dimensions', () {
      final consumed = <String>{};
      final remote = _remote(
        id: 'r1',
        timestamp: '1100',
        content: 'photo.jpg',
        msgType: rust.MessageType.image,
        imageUrl: 'mxc://example.org/uploaded',
        filename: 'photo.jpg',
        mimeType: 'image/jpeg',
        imageWidth: 1024,
        imageHeight: 768,
      );
      final result = matchLocalOutgoingMessages(
        [remote],
        [uploaded()],
        consumed,
      );
      expect(result.localIds, {'local_outgoing_pending:image'});
      expect(result.remoteToLocalFlightId, {'r1': 'image'});
      expect(consumed, {'r1'});
    });

    test('does not match a different file of the same size', () {
      final consumed = <String>{};
      final remote = _remote(
        id: 'r1',
        timestamp: '1100',
        content: 'other.jpg',
        msgType: rust.MessageType.image,
        imageUrl: 'mxc://example.org/other',
        filename: 'other.jpg',
        mimeType: 'image/jpeg',
        imageWidth: 1024,
        imageHeight: 768,
      );
      final result = matchLocalOutgoingMessages(
        [remote],
        [uploaded()],
        consumed,
      );
      expect(result.localIds, isEmpty);
      expect(consumed, isEmpty);
    });
  });

  test('matches sticker payloads by source image url', () {
    final consumed = <String>{};
    final local = _local(
      id: 'local_outgoing_pending:sticker',
      timestamp: '1000',
      content: 'cat',
      msgType: rust.MessageType.sticker,
      sourceImageUrl: 'mxc://example.org/cat.png',
      imageUrl: 'mxc://example.org/cat.png',
    );
    final remote = _remote(
      id: 'r1',
      timestamp: '1100',
      content: 'cat',
      msgType: rust.MessageType.sticker,
      imageUrl: 'mxc://example.org/cat.png',
    );
    final result = matchLocalOutgoingMessages([remote], [local], consumed);
    expect(result.localIds, {'local_outgoing_pending:sticker'});
  });

  test('does not collapse two identical stickers onto one remote', () {
    final consumed = <String>{};
    final local1 = _local(
      id: 'local_outgoing_pending:1',
      timestamp: '1000',
      content: 'cat',
      msgType: rust.MessageType.sticker,
      sourceImageUrl: 'mxc://example.org/cat.png',
      imageUrl: 'mxc://example.org/cat.png',
    );
    final local2 = _local(
      id: 'local_outgoing_pending:2',
      timestamp: '5000',
      content: 'cat',
      msgType: rust.MessageType.sticker,
      sourceImageUrl: 'mxc://example.org/cat.png',
      imageUrl: 'mxc://example.org/cat.png',
    );
    final remote1 = _remote(
      id: 'r1',
      timestamp: '1100',
      content: 'cat',
      msgType: rust.MessageType.sticker,
      imageUrl: 'mxc://example.org/cat.png',
    );

    var result = matchLocalOutgoingMessages([remote1], [local1], consumed);
    expect(result.localIds, {'local_outgoing_pending:1'});

    result = matchLocalOutgoingMessages([remote1], [local2], consumed);
    expect(result.localIds, isEmpty);
  });

  test('ignores remote events from other senders', () {
    final consumed = <String>{};
    final local = _local(
      id: 'local_outgoing_pending:1',
      timestamp: '1000',
      content: 'hi',
    );
    final remote = rust.ChatMessage(
      id: 'r1',
      senderId: '@other:example.org',
      senderName: 'Other',
      content: 'hi',
      mentionedUserIds: const [],
      mentionsRoom: false,
      timestamp: '1100',
      isMe: false,
      msgType: rust.MessageType.text,
      isEdited: false,
      editHistory: const [],
      reactions: const [],
      readers: const [],
      totalMembers: 2,
    );
    final result = matchLocalOutgoingMessages([remote], [local], consumed);
    expect(result.localIds, isEmpty);
  });

  test(
    'does not match remote events that arrived long before the local message',
    () {
      final consumed = <String>{};
      final local = _local(
        id: 'local_outgoing_pending:1',
        timestamp: '100000',
        content: 'hi',
      );
      final remote = _remote(id: 'r1', timestamp: '1000', content: 'hi');
      final result = matchLocalOutgoingMessages([remote], [local], consumed);
      expect(result.localIds, isEmpty);
    },
  );

  test('never matches a failed message: its echo belongs to a later successful resend', () {
    // The user sent "hi" (failed), then typed "hi" again (pending). Only
    // one echo arrives — for the successful resend. The failed entry must
    // not consume it: it never produced a remote event, and eating the
    // echo would leave the successful send's bubble unreconciled forever.
    final consumed = <String>{};
    final failed = _local(
      id: 'local_outgoing_failed:1',
      timestamp: '1000',
      content: 'hi',
    );
    final resent = _local(
      id: 'local_outgoing_pending:2',
      timestamp: '2000',
      content: 'hi',
    );
    final echo = _remote(id: 'r1', timestamp: '2100', content: 'hi');
    final result = matchLocalOutgoingMessages(
      [echo],
      [failed, resent],
      consumed,
    );
    expect(result.localIds, {'local_outgoing_pending:2'});
    expect(result.remoteToLocalFlightId, {'r1': '2'});
    expect(consumed, {'r1'});
  });
}
