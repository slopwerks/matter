import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_detail_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRustApi implements RustLibApi {
  int unsubscribeTypingCalls = 0;
  int subscribeRoomCalls = 0;
  int unsubscribeRoomCalls = 0;

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async {
    return false;
  }

  @override
  Future<void> crateApiMatrixSubscribeTypingForRoom({
    required String roomId,
  }) async {}

  @override
  Future<void> crateApiMatrixUnsubscribeTyping() async {
    unsubscribeTypingCalls++;
  }

  @override
  Future<void> crateApiMatrixSubscribeRoomForReceipts({
    required String roomId,
  }) async {
    subscribeRoomCalls++;
  }

  @override
  Future<void> crateApiMatrixUnsubscribeRoomForReceipts({
    required String roomId,
  }) async {
    unsubscribeRoomCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

rust.ChatMessage _message(String id) {
  return rust.ChatMessage(
    id: id,
    senderId: '@alice:example.org',
    senderName: 'Alice',
    content: 'hello',
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: '1',
    isMe: false,
    msgType: rust.MessageType.text,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  );
}

void main() {
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(RustLib.dispose);

  setUp(() {
    rustApi.unsubscribeTypingCalls = 0;
    rustApi.subscribeRoomCalls = 0;
    rustApi.unsubscribeRoomCalls = 0;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('leaving a chat clears its active room without using ref', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!room:example.org');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(currentRoomIdProvider), isNull);
    expect(rustApi.unsubscribeTypingCalls, 1);
    expect(rustApi.subscribeRoomCalls, 1);
    expect(rustApi.unsubscribeRoomCalls, 1);
  });

  testWidgets('disposing an old chat does not clear its replacement room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    Widget buildChat(String roomId) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ChatDetailPage(
            key: ValueKey(roomId),
            roomId: roomId,
            roomName: 'Room',
          ),
        ),
      );
    }

    await tester.pumpWidget(buildChat('!old:example.org'));
    await tester.pump();
    expect(rustApi.subscribeRoomCalls, 1, reason: 'entering old room subscribes');

    await tester.pumpWidget(buildChat('!new:example.org'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(currentRoomIdProvider), '!new:example.org');
    // old room disposed (unsubscribes), new room initialized (subscribes).
    expect(rustApi.subscribeRoomCalls, 2, reason: 'entering new room subscribes');
    expect(rustApi.unsubscribeRoomCalls, 1, reason: 'old room unsubscribe on dispose');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    expect(rustApi.unsubscribeRoomCalls, 2, reason: 'new room unsubscribe on dispose');
  });

  testWidgets('waits for initial members before rendering cached messages', (
    tester,
  ) async {
    const roomId = '!members:example.org';
    final members = Completer<List<rust.Contact>>();
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) => members.future),
      ],
    );
    addTearDown(container.dispose);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$members'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('text-bubble:\$members')), findsNothing);

    members.complete(const []);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('text-bubble:\$members')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('cached messages keep their first-frame vertical position', (
    tester,
  ) async {
    const roomId = '!cached:example.org';
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$cached'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );

    final bubble = find.byKey(const ValueKey('text-bubble:\$cached'));
    expect(bubble, findsNothing);

    await tester.pump();

    expect(bubble, findsOneWidget);
    final firstTop = tester.getTopLeft(bubble).dy;

    await tester.pump(const Duration(milliseconds: 180));

    expect(tester.getTopLeft(bubble).dy, closeTo(firstTop, 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
