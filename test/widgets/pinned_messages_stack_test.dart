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

  @override
  Future<bool> crateApiMatrixSetPinnedMessage({
    required String accountUserId,
    required String roomId,
    required String eventId,
    required bool pinned,
  }) async {
    expect(pinned, isFalse);
    unpinnedEventId = eventId;
    return false;
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
        pinnedMessagesProvider((
          roomId: roomId,
          userId: '@me:example.org',
        )).overrideWith((ref) async => messages),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@me:example.org';
    String? jumpedTo;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: PinnedMessagesStack(
              roomId: roomId,
              onMessageTap: (messageId) => jumpedTo = messageId,
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
      138,
    );

    await tester.tap(find.byKey(const ValueKey(r'pinned-message:$one')));
    expect(jumpedTo, r'$one');

    await tester.tap(find.byKey(const ValueKey(r'unpin-message:$one')));
    await tester.pumpAndSettle();

    expect(api.unpinnedEventId, r'$one');
    expect(find.byKey(const ValueKey(r'pinned-message:$one')), findsNothing);
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
        pinnedMessagesProvider((
          roomId: roomId,
          userId: bob,
        )).overrideWith((ref) => bobPins.future),
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
    expect(find.text('Alice pin'), findsOneWidget);

    container.read(activeUserIdProvider.notifier).value = bob;
    await tester.pump();

    expect(find.text('Alice pin'), findsNothing);
    expect(find.byKey(const ValueKey('pinned-messages-stack')), findsNothing);

    bobPins.complete(const []);
    await tester.pumpAndSettle();
  });
}

void _noop(String _) {}
