import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/pinned_messages_stack.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

import '../helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  String? unpinnedEventId;
  final states = <bool>[];

  @override
  Future<bool> crateApiMatrixSetPinnedMessage({
    required String accountUserId,
    required String roomId,
    required String eventId,
    required bool pinned,
  }) async {
    states.add(pinned);
    if (!pinned) unpinnedEventId = eventId;
    return pinned;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

rust.ChatMessage _message(String id, String content) => rust.ChatMessage(
  id: id,
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: content,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '100',
  isMe: false,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

void main() {
  late _FakeRustApi api;

  setUpAll(() {
    api = _FakeRustApi();
    RustLib.initMock(api: api);
  });

  tearDownAll(RustLib.dispose);
  setUp(() {
    api.unpinnedEventId = null;
    api.states.clear();
  });

  testWidgets('pinned messages stack, jump, and unpin in the chat header', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final messages = [
      _message(r'$one', 'One'),
      _message(r'$two', 'Two'),
      _message(r'$three', 'Three'),
      _message(r'$four', 'Four'),
    ];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        pinnedMessagesProvider((roomId: roomId, userId: '@me:example.org'))
            .overrideWith((ref) async => messages),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@me:example.org';
    String? jumpedTo;
    final jumpTarget = ValueNotifier<String?>(null);
    addTearDown(jumpTarget.dispose);
    var openedAll = false;
    int? visibleCount;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: PinnedMessagesStack(
              roomId: roomId,
              onMessageTap: (messageId) => jumpedTo = messageId,
              onShowAll: () => openedAll = true,
              jumpTarget: jumpTarget,
              onVisibleCountChanged: (count) => visibleCount = count,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pinned-messages-stack')), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('pinned-messages-stack')))
          .height,
      46,
    );

    expect(visibleCount, 1);
    expect(find.byKey(const ValueKey('pin-segment:0')), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-segment:3')), findsOneWidget);
    await tester.tap(find.byTooltip('查看全部置顶消息'));
    expect(openedAll, isTrue);
    await tester.tap(find.byKey(const ValueKey(r'pinned-message:$one')));
    expect(jumpedTo, r'$one');

    await tester.pump();
    expect(find.text('Alice：One'), findsOneWidget);
    final currentSegment = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('pin-segment:0')),
    );
    final nextSegment = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('pin-segment:1')),
    );
    expect(
      (currentSegment.decoration as BoxDecoration).color!.a,
      greaterThan((nextSegment.decoration as BoxDecoration).color!.a),
    );
    await tester.tap(find.byKey(const ValueKey(r'pinned-message:$one')));
    await tester.pump();
    expect(jumpedTo, r'$two');
    expect(find.text('Alice：Two'), findsOneWidget);
    final firstSegment = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('pin-segment:0')),
    );
    final secondSegment = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('pin-segment:1')),
    );
    expect(
      (firstSegment.decoration as BoxDecoration).color!.a,
      lessThan((secondSegment.decoration as BoxDecoration).color!.a),
    );
    openedAll = false;
    await tester.longPress(find.byKey(const ValueKey(r'pinned-message:$two')));
    expect(openedAll, isTrue);
    expect(find.text('Alice：One'), findsNothing);
    await tester.tap(find.byKey(const ValueKey(r'pinned-message:$two')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey(r'pinned-message:$three')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey(r'pinned-message:$four')));
    await tester.pump();
    // Returning from the full pinned list must select the same marker.
    jumpTarget.value = r'$four';
    await tester.pumpAndSettle();
    expect(find.text('Alice：Four'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey(r'pinned-message:$four')));
    await tester.pumpAndSettle();
    expect(jumpedTo, r'$one');
    expect(find.text('Alice：One'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey(r'unpin-message:$one')));
    await tester.pumpAndSettle();

    expect(find.text('取消置顶这条消息？'), findsOneWidget);
    expect(api.unpinnedEventId, isNull);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(r'pinned-message:$one')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey(r'unpin-message:$one')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消置顶').last);
    await tester.pumpAndSettle();
    expect(api.unpinnedEventId, r'$one');
    expect(find.byKey(const ValueKey(r'pinned-message:$one')), findsNothing);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(r'pinned-message:$one')), findsOneWidget);
    await tester.tap(find.text('重做'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(r'pinned-message:$one')), findsNothing);
    expect(api.states, [false, true, false]);
  });

  testWidgets('account reload never exposes the previous account pins', (
    tester,
  ) async {
    const roomId = '!account-pins:example.org';
    const alice = '@alice:example.org';
    const bob = '@bob:example.org';
    final bobPins = Completer<List<rust.ChatMessage>>();
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        pinnedMessagesProvider((
          roomId: roomId,
          userId: alice,
        )).overrideWith((ref) async => [_message(r'$alice-pin', 'Alice pin')]),
        pinnedMessagesProvider((roomId: roomId, userId: bob))
            .overrideWith((ref) => bobPins.future),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = alice;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const Scaffold(
            body: PinnedMessagesStack(roomId: roomId, onMessageTap: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alice：Alice pin'), findsOneWidget);

    await tester.tap(find.byTooltip('取消置顶'));
    await tester.pumpAndSettle();
    container.read(activeUserIdProvider.notifier).value = bob;
    await tester.pump();

    expect(find.text('Alice：Alice pin'), findsNothing);
    expect(find.byKey(const ValueKey('pinned-messages-stack')), findsNothing);

    await tester.tap(find.text('取消置顶').last);
    await tester.pumpAndSettle();
    expect(api.states, isEmpty);
    bobPins.complete(const []);
    await tester.pumpAndSettle();
  });
}

void _noop(String _) {}
