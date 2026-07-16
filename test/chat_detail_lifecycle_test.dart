import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_detail_page.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/pages/chat/message_insert_animation.dart';
import 'package:matter/pages/chat/send_flight.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRustApi implements RustLibApi {
  int unsubscribeTypingCalls = 0;
  int subscribeRoomCalls = 0;
  int unsubscribeRoomCalls = 0;
  Completer<String>? pendingSend;

  @override
  Future<String> crateApiMatrixSendMessage({
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    return (pendingSend ??= Completer<String>()).future;
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String roomId,
    required bool typing,
  }) async {}

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

rust.ChatMessage _ownMessage(
  String id, {
  required String content,
  required String timestamp,
  rust.MessageType msgType = rust.MessageType.text,
  String? imageUrl,
  int? imageWidth,
  int? imageHeight,
}) {
  return rust.ChatMessage(
    id: id,
    senderId: '',
    senderName: '我',
    content: content,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: timestamp,
    isMe: true,
    msgType: msgType,
    imageUrl: imageUrl,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
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
    rustApi.pendingSend = null;
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
    expect(
      rustApi.subscribeRoomCalls,
      1,
      reason: 'entering old room subscribes',
    );

    await tester.pumpWidget(buildChat('!new:example.org'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(currentRoomIdProvider), '!new:example.org');
    // old room disposed (unsubscribes), new room initialized (subscribes).
    expect(
      rustApi.subscribeRoomCalls,
      2,
      reason: 'entering new room subscribes',
    );
    expect(
      rustApi.unsubscribeRoomCalls,
      1,
      reason: 'old room unsubscribe on dispose',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    expect(
      rustApi.unsubscribeRoomCalls,
      2,
      reason: 'new room unsubscribe on dispose',
    );
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

  testWidgets('appending a sticker keeps the previous sticker image state', (
    tester,
  ) async {
    const roomId = '!sticker-append:example.org';
    final firstSticker = _ownMessage(
      r'$first-sticker',
      content: 'first',
      timestamp: '100',
      msgType: rust.MessageType.sticker,
      imageUrl: 'https://example.org/first.png',
      imageWidth: 512,
      imageHeight: 512,
    );
    final secondSticker = _ownMessage(
      r'$second-sticker',
      content: 'second',
      timestamp: '101',
      msgType: rust.MessageType.sticker,
      imageUrl: 'https://example.org/second.png',
      imageWidth: 512,
      imageHeight: 512,
    );
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      firstSticker,
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
    await tester.pump();

    final firstBubble = find.byKey(
      const ValueKey(r'image-bubble:$first-sticker'),
    );
    expect(firstBubble, findsOneWidget);
    final firstState = tester.state(firstBubble);

    container.read(messageCacheProvider(roomId).notifier).value = [
      firstSticker,
      secondSticker,
    ];
    await tester.pump();

    expect(tester.state(firstBubble), same(firstState));
    expect(find.byType(ImageMessageBubble), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a rapid bottom send cancels flight and inserts smoothly', (
    tester,
  ) async {
    const roomId = '!animated-send:example.org';
    final oldMessage = _ownMessage(
      r'$old-message',
      content: 'old',
      timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [oldMessage];
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
    await tester.pump();

    final oldBubble = find.byKey(const ValueKey(r'text-bubble:$old-message'));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 220));
    final initialTop = tester.getTopLeft(oldBubble).dy;
    final canceledFlight = registerSendFlight(
      '${localOutgoingPendingPrefix}already-flying',
      const SendFlightSpec(
        sourceRect: Rect.fromLTWH(20, 500, 80, 80),
        kind: SendFlightKind.sticker,
        child: SizedBox(),
      ),
    );
    expect(hasOngoingSendFlight, isTrue);

    final sendButton = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('send_only')),
        matching: find.byType(IconButton),
      ),
    );
    sendButton.onPressed!();
    await tester.pump();

    expect(hasOngoingSendFlight, isFalse);
    await expectLater(canceledFlight, completes);
    expect(find.byType(MessageInsertAnimation), findsOneWidget);
    final lateralSlide = tester.widget<SlideTransition>(
      find.descendant(
        of: find.byType(MessageInsertAnimation),
        matching: find.byType(SlideTransition),
      ),
    );
    expect(lateralSlide.position.value.dx, greaterThan(0));
    expect(tester.getTopLeft(oldBubble).dy, closeTo(initialTop, 0.1));

    await tester.pump(const Duration(milliseconds: 120));
    final middleTop = tester.getTopLeft(oldBubble).dy;
    expect(middleTop, lessThan(initialTop));

    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getTopLeft(oldBubble).dy, lessThan(middleTop));

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
