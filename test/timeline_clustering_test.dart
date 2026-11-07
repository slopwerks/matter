import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_timestamp.dart';
import 'package:matter/pages/chat/image_message_runs.dart';
import 'package:matter/pages/chat/message_group.dart' as legacy;
import 'package:matter/pages/chat/timeline/timeline_clustering.dart';
import 'package:matter/src/rust/api/matrix.dart';

String _id(ChatMessage message) => message.id;
List<List<String>> _ids(List<MessageGroup> groups) => [
  for (final group in groups)
    [for (final message in group.messages) message.id],
];

void main() {
  test('empty timeline has no groups', () {
    expect(clusterTimelineMessages([], layoutId: _id), isEmpty);
  });

  test('sender and local calendar day define clusters, not message type or time gap', () {
    final groups = clusterTimelineMessages([
      _message('one', time: _time(1, 1)),
      _message('event', time: _time(1, 20), type: MessageType.event),
      _message('bob', sender: 'bob', time: _time(1, 21)),
      _message('alice-again', time: _time(1, 22)),
      _message('next-day', time: _time(2, 1)),
    ], layoutId: _id);
    expect(_ids(groups), [
      ['one', 'event'],
      ['bob'],
      ['alice-again'],
      ['next-day'],
    ]);
    expect(
      groups.every((group) => group.startsCluster && group.endsCluster),
      isTrue,
    );
  });

  test('render blocks split at 12 without splitting the visual cluster', () {
    final groups = clusterTimelineMessages(
      List.generate(25, (i) => _message('$i')),
      layoutId: _id,
    );
    expect(groups.map((group) => group.messages.length), [12, 12, 1]);
    expect(groups.map((group) => group.startsCluster), [true, false, false]);
    expect(groups.map((group) => group.endsCluster), [false, false, true]);
    expect(
      groups.expand((group) => group.messages).map((message) => message.id),
      List.generate(25, (i) => '$i'),
    );
  });

  test('a new sender after a full block starts a new visual cluster', () {
    final groups = clusterTimelineMessages([
      ...List.generate(12, (i) => _message('$i')),
      _message('bob', sender: 'bob'),
    ], layoutId: _id);
    expect(groups.map((group) => group.startsCluster), [true, true]);
    expect(groups.map((group) => group.endsCluster), [true, true]);
  });

  test(
    'input ordering and references are retained, not sorted or deduplicated',
    () {
      final first = _message('later', time: _time(1, 20));
      final last = _message('earlier', time: _time(1, 1));
      final input = [first, first, last];
      final groups = clusterTimelineMessages(input, layoutId: _id);
      expect(groups.single.messages, input);
      expect(groups.single.messages.first, same(first));
      expect(groups.single.messages.last, same(last));
      expect(input, [first, first, last]);
      groups.single.messages.add(_message('new'));
      expect(input, hasLength(3));
    },
  );

  test(
    'malformed timestamps retain the existing raw-value date key behavior',
    () {
      final groups = clusterTimelineMessages([
        _message('one', time: 'bad'),
        _message('two', time: 'bad'),
        _message('three', time: 'other'),
      ], layoutId: _id);
      expect(_ids(groups), [
        ['one', 'two'],
        ['three'],
      ]);
    },
  );

  test('group metadata comes from its first message', () {
    final first = _message('one', name: 'Original', isMe: true);
    final second = _message('two', name: 'Renamed');
    final group = clusterTimelineMessages([
      first,
      second,
    ], layoutId: _id).single;
    expect(group.senderId, first.senderId);
    expect(group.senderName, 'Original');
    expect(group.isMe, isTrue);
  });

  test('image collections remain indivisible across the soft block limit', () {
    final input = [
      ...List.generate(11, (i) => _message('$i')),
      _image('a'),
      _image('b'),
      _message('after'),
    ];
    final groups = clusterTimelineMessages(input, layoutId: _id);
    expect(groups.map((group) => group.messages.length), [13, 1]);
    expect(groups.first.imageRuns!.last.messages.map((message) => message.id), [
      'a',
      'b',
    ]);
    expect(groups.first.endsCluster, isFalse);
    expect(groups.last.startsCluster, isFalse);
  });

  test('interleaved explicit albums keep the existing image-run ordering', () {
    final input = [
      _image('root'),
      _message('between', sender: 'bob'),
      _image('child', root: 'root'),
    ];
    final groups = clusterTimelineMessages(input, layoutId: _id);
    expect(_ids(groups), [
      ['root', 'child'],
      ['between'],
    ]);
    expect(groups.first.imageRuns!.single.album, isTrue);
  });

  test(
    'reading pivot freezes only its image members and retains append order',
    () {
      final input = [
        _image('before'),
        _image('pivot-a'),
        _image('pivot-b'),
        _image('after'),
      ];
      final groups = clusterTimelineMessages(
        input,
        layoutId: _id,
        pivotRunIds: {'pivot-a', 'pivot-b'},
        pivotEndId: 'pivot-b',
        pivotEndsCluster: false,
      );
      expect(_ids(groups), [
        ['before', 'pivot-a', 'pivot-b'],
        ['after'],
      ]);
      expect(
        groups
            .expand((group) => group.imageRuns!)
            .map((run) => run.messages.map((message) => message.id).toList()),
        [
          ['before'],
          ['pivot-a', 'pivot-b'],
          ['after'],
        ],
      );
      expect(groups.map((group) => group.startsCluster), [true, false]);
      expect(groups.map((group) => group.endsCluster), [false, true]);
    },
  );

  test('pivot trailing cluster flag is preserved when newer same-sender messages arrive', () {
    for (final endsCluster in [false, true]) {
      final groups = clusterTimelineMessages(
        [_message('pivot'), _message('new')],
        layoutId: _id,
        pivotEndId: 'pivot',
        pivotEndsCluster: endsCluster,
      );
      expect(_ids(groups), [
        ['pivot'],
        ['new'],
      ]);
      expect(groups.first.endsCluster, endsCluster);
      expect(groups.last.startsCluster, isFalse);
    }
  });

  test('stable layout ids preserve pivot grouping through pending/sent/remote handoff', () {
    for (final id in [
      'local_outgoing_pending:flight',
      'local_outgoing_sent:flight',
      r'$remote',
    ]) {
      final groups = clusterTimelineMessages(
        [_message(id), _message('next')],
        layoutId: (message) => message.id == id ? 'flight' : message.id,
        pivotRunIds: {'flight'},
        pivotEndId: 'flight',
        pivotEndsCluster: false,
      );
      expect(groups.map((group) => group.messages.length), [1, 1]);
      expect(groups.first.endsCluster, isFalse);
      expect(groups.last.startsCluster, isFalse);
      expect(groups.first.messages.single.id, id);
    }
  });

  test('anchored interleaved album freezes actual members, not the intervening text', () {
    final input = [
      _image('root'),
      _message('between', sender: 'bob'),
      _image('child', root: 'root'),
      _image('new-child', root: 'root'),
    ];
    final groups = clusterTimelineMessages(
      input,
      layoutId: _id,
      pivotRunIds: {'root', 'child'},
      pivotAlbum: true,
      pivotEndId: 'child',
    );
    final runs = groups.expand((group) => group.imageRuns!).toList();
    expect(
      runs.map((run) => run.messages.map((message) => message.id).toList()),
      [
        ['root', 'child'],
        ['new-child'],
        ['between'],
      ],
    );
    expect(runs.first.album, isTrue);
  });

  test('extraction matches the pre-extraction algorithm across boundary combinations', () {
    for (final length in [0, 1, 11, 12, 13, 24, 25]) {
      for (final pivot in [null, '5', '11', 'missing']) {
        for (final ends in [false, true]) {
          final input = List.generate(
            length,
            (i) => _message(
              '$i',
              sender: i % 7 == 0 ? 'bob' : 'alice',
              time: _time(1 + i ~/ 13, 12),
              type: i % 4 == 0 ? MessageType.event : MessageType.text,
            ),
          );
          final expected = _originalGroups(input, pivot: pivot, ends: ends);
          final actual = clusterTimelineMessages(
            input,
            layoutId: _id,
            pivotEndId: pivot,
            pivotEndsCluster: ends,
          );
          expect(
            _signature(actual),
            _signature(expected),
            reason: 'length=$length pivot=$pivot ends=$ends',
          );
        }
      }
    }
  });
}

List<Object> _signature(List<MessageGroup> groups) => [
  for (final group in groups)
    [
      group.senderId,
      group.senderName,
      group.isMe,
      group.startsCluster,
      group.endsCluster,
      [for (final message in group.messages) message.id],
      [
        for (final run in group.imageRuns!)
          [
            run.album,
            [for (final message in run.messages) message.id],
          ],
      ],
    ],
];

// Characterization oracle copied from ChatDetailPage before extraction.
List<legacy.MessageGroup> _originalGroups(
  List<ChatMessage> messages, {
  String? pivot,
  required bool ends,
}) {
  final groups = <legacy.MessageGroup>[];
  for (final run in chatImageRuns(messages)) {
    final message = run.messages.first;
    final startsNewCluster =
        groups.isEmpty ||
        groups.last.senderId != message.senderId ||
        chatDateKey(groups.last.messages.last.timestamp) !=
            chatDateKey(message.timestamp);
    final startsNewRenderGroup =
        startsNewCluster ||
        groups.last.messages.last.id == pivot ||
        groups.last.messages.length >= 12;
    if (startsNewRenderGroup) {
      if (!startsNewCluster && groups.isNotEmpty) {
        groups.last.endsCluster = false;
      }
      groups.add(
        legacy.MessageGroup(
          senderId: message.senderId,
          senderName: message.senderName,
          isMe: message.isMe,
          messages: List.of(run.messages),
          imageRuns: [run],
          startsCluster: startsNewCluster,
        ),
      );
    } else {
      groups.last.messages.addAll(run.messages);
      groups.last.imageRuns!.add(run);
    }
  }
  for (final group in groups) {
    if (group.messages.last.id == pivot) group.endsCluster = ends;
  }
  return groups;
}

String _time(int day, int hour) =>
    DateTime(2026, 11, day, hour).millisecondsSinceEpoch.toString();
ChatMessage _image(String id, {String? root}) =>
    _message(id, type: MessageType.image, root: root);
ChatMessage _message(
  String id, {
  String sender = 'alice',
  String? name,
  bool isMe = false,
  String? time,
  MessageType type = MessageType.text,
  String? root,
}) => ChatMessage(
  id: id,
  senderId: sender,
  senderName: name ?? sender,
  content: id,
  timestamp: time ?? _time(1, 12),
  isMe: isMe,
  msgType: type,
  imageUrl: type == MessageType.image ? 'mxc://example.org/$id' : null,
  imageMetadata: root == null
      ? null
      : ImageMessageMetadata(albumRoot: root, spoiler: false),
  mentionedUserIds: const [],
  mentionsRoom: false,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);
