import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_detail_page.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_insert_animation.dart';
import 'package:matter/pages/chat/pinned_messages_page.dart';
import 'package:matter/pages/chat/room_metadata_patch.dart';
import 'package:matter/pages/chat/room_management_page.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/pages/chat/send_flight.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  final syncEvents = StreamController<rust.SyncEvent>.broadcast();
  int subscribeTypingCalls = 0;
  int unsubscribeTypingCalls = 0;
  int subscribeRoomCalls = 0;
  int unsubscribeRoomCalls = 0;
  int markRoomAsReadCalls = 0;
  bool? lastMarkReadExplicit;
  int getMessagesBeforeCalls = 0;
  final typingSubscriptionAccounts = <String?>[];
  final roomSubscriptionAccounts = <String?>[];
  final messagesBeforeEventIds = <String>[];
  List<rust.ChatMessage> messagesBefore = const [];
  Object? messagesBeforeError;
  int getMessagesAroundCalls = 0;
  List<rust.ChatMessage> messagesAround = const [];
  final pendingMessagesAround = <String, Completer<List<rust.ChatMessage>>>{};
  Completer<String>? pendingSend;
  Completer<bool>? pendingRoomEncryption;
  List<rust.ChatRoom> chatRooms = const [];
  final sentMessages = <rust.FormattedMessageInput>[];

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetChatRooms({
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async {
    return chatRooms;
  }

  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    pendingSend = Completer<String>();
    sentMessages.add(message);
    return pendingSend!.future;
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {}
  String? activeTypingRoom;
  String? activeTypingSubscription;
  final activeReceiptRooms = <String>{};
  Completer<void>? typingSubscribeBarrier;
  Completer<void>? typingUnsubscribeBarrier;
  Completer<void>? roomSubscribeBarrier;
  Completer<void>? roomUnsubscribeBarrier;

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) =>
      pendingRoomEncryption?.future ?? Future.value(false);

  @override
  Future<String> crateApiMatrixSubscribeTypingForRoom({
    required String roomId,
    String? accountUserId,
  }) async {
    subscribeTypingCalls++;
    typingSubscriptionAccounts.add(accountUserId);
    final barrier = typingSubscribeBarrier;
    if (barrier != null) await barrier.future;
    activeTypingRoom = roomId;
    activeTypingSubscription = 'typing-subscription-$subscribeTypingCalls';
    return activeTypingSubscription!;
  }

  @override
  Future<void> crateApiMatrixUnsubscribeTyping({
    required String roomId,
    required String subscriptionId,
    String? accountUserId,
  }) async {
    unsubscribeTypingCalls++;
    final barrier = typingUnsubscribeBarrier;
    if (barrier != null) await barrier.future;
    if (activeTypingRoom == roomId &&
        activeTypingSubscription == subscriptionId) {
      activeTypingRoom = null;
      activeTypingSubscription = null;
    }
  }

  @override
  Future<String> crateApiMatrixSubscribeRoomForReceipts({
    required String roomId,
    String? accountUserId,
  }) async {
    subscribeRoomCalls++;
    roomSubscriptionAccounts.add(accountUserId);
    final barrier = roomSubscribeBarrier;
    if (barrier != null) await barrier.future;
    activeReceiptRooms.add(roomId);
    return 'subscription-$subscribeRoomCalls';
  }

  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async {
    markRoomAsReadCalls++;
    lastMarkReadExplicit = explicit;
    return true;
  }

  @override
  Stream<rust.TypingNotification> crateApiMatrixWatchTypingNotifications() =>
      const Stream.empty();

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessagesBefore({
    required String roomId,
    required String fromEventId,
    required int limit,
  }) async {
    getMessagesBeforeCalls++;
    messagesBeforeEventIds.add(fromEventId);
    if (messagesBeforeError case final error?) throw error;
    return messagesBefore;
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessagesAround({
    required String roomId,
    required String eventId,
    required int limit,
  }) async {
    getMessagesAroundCalls++;
    final pending = pendingMessagesAround[eventId];
    if (pending != null) return pending.future;
    return messagesAround;
  }

  @override
  Future<void> crateApiMatrixUnsubscribeRoomForReceipts({
    required String roomId,
    required String subscriptionId,
    String? accountUserId,
  }) async {
    unsubscribeRoomCalls++;
    final barrier = roomUnsubscribeBarrier;
    if (barrier != null) await barrier.future;
    activeReceiptRooms.remove(roomId);
  }

  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => syncEvents.stream;

  int pinnedMessagesCalls = 0;
  List<rust.ChatMessage> pinnedMessages = const [];

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetPinnedMessages({
    required String roomId,
  }) async {
    pinnedMessagesCalls++;
    return pinnedMessages;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

rust.ChatMessage _message(
  String id, {
  String timestamp = '1',
  String? inReplyTo,
}) {
  return rust.ChatMessage(
    id: id,
    senderId: '@alice:example.org',
    senderName: 'Alice',
    content: 'hello',
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: timestamp,
    isMe: false,
    msgType: rust.MessageType.text,
    inReplyTo: inReplyTo,
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

  tearDownAll(() async {
    await rustApi.syncEvents.close();
    RustLib.dispose();
  });

  setUp(() {
    rustApi.subscribeTypingCalls = 0;
    rustApi.unsubscribeTypingCalls = 0;
    rustApi.subscribeRoomCalls = 0;
    rustApi.unsubscribeRoomCalls = 0;
    rustApi.markRoomAsReadCalls = 0;
    rustApi.lastMarkReadExplicit = null;
    rustApi.getMessagesBeforeCalls = 0;
    rustApi.typingSubscriptionAccounts.clear();
    rustApi.roomSubscriptionAccounts.clear();
    rustApi.messagesBeforeEventIds.clear();
    rustApi.messagesBefore = const [];
    rustApi.messagesBeforeError = null;
    rustApi.getMessagesAroundCalls = 0;
    rustApi.messagesAround = const [];
    rustApi.pendingMessagesAround.clear();
    rustApi.pendingSend = null;
    rustApi.sentMessages.clear();
    rustApi.pendingRoomEncryption = null;
    rustApi.chatRooms = const [];
    rustApi.pinnedMessagesCalls = 0;
    rustApi.pinnedMessages = const [];
    rustApi.activeTypingRoom = null;
    rustApi.activeReceiptRooms.clear();
    rustApi.typingSubscribeBarrier = null;
    rustApi.typingUnsubscribeBarrier = null;
    rustApi.roomSubscribeBarrier = null;
    rustApi.roomUnsubscribeBarrier = null;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('room subscriptions are bound to the active account', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    expect(rustApi.typingSubscriptionAccounts, ['@alice:example.org']);
    expect(rustApi.roomSubscriptionAccounts, ['@alice:example.org']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'the timeline runs under the pinned stack instead of beneath it',
    (tester) async {
      const roomId = '!pinned-underlay:example.org';
      const userId = '@me:example.org';
      rustApi.pinnedMessages = [_message(r'$pinned')];
      final container = ProviderContainer(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
          roomMembersProvider(roomId).overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = userId;
      await container.read(roomMembersProvider(roomId).future);
      container.read(messageCacheProvider(roomId).notifier).value = [
        _ownMessage(r'$own', content: 'hi', timestamp: '10'),
      ];
      container.read(messageCacheOwnerProvider(roomId).notifier).value = userId;
      container.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey(r'pinned-message:$pinned')),
        findsOneWidget,
      );

      // The pinned stack is a floating glass layer: the timeline viewport must
      // start above its bottom edge so messages scroll under it. Clipping the
      // viewport exactly at that edge is what cut the background off at a hard
      // line below the stack.
      final viewport = tester.getRect(
        find.byKey(const ValueKey('pinned-messages-stack')),
      );
      final timeline = tester.getRect(find.byType(CustomScrollView));
      expect(timeline.top, lessThan(viewport.bottom));
      expect(timeline.top, lessThanOrEqualTo(viewport.top));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('switching away and back restores live room view ownership', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(roomViewOwnerProvider(roomId)), '@alice:example.org');
    final readCallsBeforeSwitch = rustApi.markRoomAsReadCalls;

    container.invalidate(roomViewOwnerProvider);
    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    await tester.pump();
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(roomViewOwnerProvider(roomId)), '@alice:example.org');
    expect(rustApi.markRoomAsReadCalls, greaterThan(readCallsBeforeSwitch));
    expect(rustApi.typingSubscriptionAccounts.last, '@alice:example.org');
    expect(rustApi.roomSubscriptionAccounts.last, '@alice:example.org');
  });

  testWidgets('the chat header opens the pinned messages page', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    rustApi.pinnedMessagesCalls = 0;
    rustApi.pinnedMessages = const [];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('置顶消息'));
    await tester.pumpAndSettle();

    expect(find.byType(PinnedMessagesPage), findsOneWidget);
    // One load feeds the chat's stacked pin strip; the pushed page performs
    // its own authoritative load.
    expect(rustApi.pinnedMessagesCalls, 2);
    expect(find.text('暂无置顶消息'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('repeated search taps open only one search route', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    final searchButton = tester.widget<NeuIconButton>(
      find.widgetWithIcon(NeuIconButton, Icons.search_rounded),
    );
    searchButton.onPressed!();
    searchButton.onPressed!();
    await tester.pumpAndSettle();

    expect(find.byType(ChatSearchPage), findsOneWidget);
  });

  testWidgets('an initial search result opens around the target message', (
    tester,
  ) async {
    const roomId = '!search-jump:example.org';
    final target = _message(r'$search-target');
    final latest = _message(r'$latest-message');
    final pendingContext = Completer<List<rust.ChatMessage>>();
    rustApi.pendingMessagesAround[r'$search-target'] = pendingContext;
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container.read(messageCacheProvider(roomId).notifier).value = [latest];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: roomId,
            roomName: 'Room',
            initialMessageId: r'$search-target',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsWidgets);

    pendingContext.complete([target]);
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 1);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$search-target')),
      findsOneWidget,
    );
  });

  testWidgets('a connected initial search result keeps the live timeline', (
    tester,
  ) async {
    const roomId = '!connected-search-jump:example.org';
    final target = _message(r'$connected-target', timestamp: '1');
    final latest = _message(r'$connected-latest', timestamp: '100');
    rustApi.messagesAround = [target, latest];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container.read(messageCacheProvider(roomId).notifier).value = [latest];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: roomId,
            roomName: 'Room',
            initialMessageId: r'$connected-target',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 1);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$connected-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$connected-latest')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LatestMessageControl>(find.byType(LatestMessageControl))
          .visible,
      isFalse,
    );
    expect(find.textContaining('正在浏览历史消息'), findsNothing);
  });

  testWidgets('a missing initial search result restores the live timeline', (
    tester,
  ) async {
    const roomId = '!missing-search-jump:example.org';
    final latest = _message(r'$latest-message');
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container.read(messageCacheProvider(roomId).notifier).value = [latest];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: roomId,
            roomName: 'Room',
            initialMessageId: r'$missing-message',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 1);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$latest-message')),
      findsOneWidget,
    );
  });

  testWidgets('long-pressing a message avatar inserts a Matrix mention', (
    tester,
  ) async {
    const roomId = '!mention:example.org';
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith(
          (ref) async => const [
            rust.Contact(
              id: '@alice:example.org',
              name: 'Alice',
              status: '@alice:example.org',
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$mention-source'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('message-sender-avatar')));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '@alice:example.org ',
    );
  });

  testWidgets('reply preview loads and jumps to an unloaded target', (
    tester,
  ) async {
    const roomId = '!reply-jump:example.org';
    final target = _message(r'$reply-target', timestamp: '1');
    final reply = _message(r'$reply', timestamp: '100', inReplyTo: target.id);
    rustApi.messagesAround = [target, reply];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [reply];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$reply-target')),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 1);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$reply-target')),
      findsOneWidget,
    );
  });

  testWidgets('a stale jump response cannot replace the latest target', (
    tester,
  ) async {
    const roomId = '!jump-generation:example.org';
    final firstTarget = _message(r'$first-target', timestamp: '1');
    final secondTarget = _message(r'$second-target', timestamp: '2');
    final firstReply = _message(
      r'$first-reply',
      timestamp: '100',
      inReplyTo: firstTarget.id,
    );
    final secondReply = _message(
      r'$second-reply',
      timestamp: '101',
      inReplyTo: secondTarget.id,
    );
    final firstLoad = Completer<List<rust.ChatMessage>>();
    final secondLoad = Completer<List<rust.ChatMessage>>();
    rustApi.pendingMessagesAround[firstTarget.id] = firstLoad;
    rustApi.pendingMessagesAround[secondTarget.id] = secondLoad;
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      firstReply,
      secondReply,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$first-target')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$second-target')),
    );
    await tester.pump();

    secondLoad.complete([secondTarget]);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$second-target')),
      findsOneWidget,
    );

    firstLoad.complete([firstTarget]);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$second-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$first-target')),
      findsNothing,
    );
  });

  testWidgets(
    'jumping to a detached message hides the live window until the latest control is tapped',
    (tester) async {
      const roomId = '!focused-jump:example.org';
      final target = _message(r'$far-target', timestamp: '1');
      // The slice around the far target does not touch the live window.
      rustApi.messagesAround = [
        target,
        _message(r'$far-neighbor', timestamp: '2'),
      ];
      final reply = _message(
        r'$live-reply',
        timestamp: '100',
        inReplyTo: target.id,
      );
      final container = ProviderContainer(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
          roomMembersProvider(roomId).overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);
      await container.read(roomMembersProvider(roomId).future);
      container.read(messageCacheProvider(roomId).notifier).value = [reply];
      container.read(messageCacheOwnerProvider(roomId).notifier).value =
          'anonymous';
      container.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey(r'reply-preview:$far-target')),
      );
      await tester.pumpAndSettle();

      // Focused browsing: the detached slice renders, the live window hides.
      expect(
        find.byKey(const ValueKey(r'text-bubble:$far-target')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey(r'text-bubble:$live-reply')),
        findsNothing,
      );

      // Let the hint snackbar clear the bottom-right control, then leave the
      // focused view through it.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(LatestMessageControl));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey(r'text-bubble:$live-reply')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey(r'text-bubble:$far-target')),
        findsNothing,
      );
    },
  );

  testWidgets('account switching clears a detached history slice', (
    tester,
  ) async {
    const roomId = '!focused-account:example.org';
    const alice = '@alice:example.org';
    final target = _message(r'$account-target', timestamp: '1');
    final reply = _message(
      r'$account-live-reply',
      timestamp: '100',
      inReplyTo: target.id,
    );
    rustApi.messagesAround = [target];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = alice;
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [reply];
    container.read(messageCacheOwnerProvider(roomId).notifier).value = alice;
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$account-target')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$account-target')),
      findsOneWidget,
    );

    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    await tester.pump();
    expect(find.text('账号已切换'), findsOneWidget);

    container.read(activeUserIdProvider.notifier).value = alice;
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$account-live-reply')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$account-target')),
      findsNothing,
    );
  });

  testWidgets('reply preview jumps to an offscreen loaded target', (
    tester,
  ) async {
    const roomId = '!reply-scroll:example.org';
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final target = _message(r'$loaded-target', timestamp: '0');
    final reply = _message(
      r'$loaded-reply',
      timestamp: '101',
      inReplyTo: target.id,
    );
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      target,
      ...List.generate(
        100,
        (index) => _message('\$middle-$index', timestamp: '${index + 1}'),
      ),
      reply,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$loaded-target')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$loaded-target')),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 0);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$loaded-target')),
      findsOneWidget,
    );
  });

  testWidgets('leaving a chat clears its active room without using ref', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!room:example.org');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: neuTestTheme(), home: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(currentRoomIdProvider), isNull);
    expect(rustApi.unsubscribeTypingCalls, 1);
    expect(rustApi.subscribeRoomCalls, 1);
    expect(rustApi.unsubscribeRoomCalls, 1);
  });

  testWidgets('dispose waits for pending room subscriptions', (tester) async {
    final subscribeBarrier = Completer<void>();
    rustApi.typingSubscribeBarrier = subscribeBarrier;
    rustApi.roomSubscribeBarrier = subscribeBarrier;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    expect(rustApi.subscribeTypingCalls, 1);
    expect(rustApi.subscribeRoomCalls, 1);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();

    expect(rustApi.unsubscribeTypingCalls, 0);
    expect(rustApi.unsubscribeRoomCalls, 0);

    subscribeBarrier.complete();
    await tester.pump();
    await tester.pump();

    expect(rustApi.unsubscribeTypingCalls, 1);
    expect(rustApi.unsubscribeRoomCalls, 1);
    expect(rustApi.activeTypingRoom, isNull);
    expect(rustApi.activeReceiptRooms, isEmpty);
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
          theme: neuTestTheme(),
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

  testWidgets('returning to a chat restores its room subscriptions', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(roomId: '!a:example.org', roomName: 'A'),
        ),
      ),
    );
    await tester.pump();

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const ChatDetailPage(roomId: '!b:example.org', roomName: 'B'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!b:example.org');

    final unsubscribeBarrier = Completer<void>();
    rustApi.typingUnsubscribeBarrier = unsubscribeBarrier;
    navigator.pop();
    await tester.pumpAndSettle();

    expect(container.read(currentRoomIdProvider), '!a:example.org');
    expect(rustApi.subscribeTypingCalls, 3);
    expect(rustApi.subscribeRoomCalls, 3);

    unsubscribeBarrier.complete();
    await tester.pump();
    expect(rustApi.activeTypingRoom, '!a:example.org');
  });

  testWidgets('a covered chat stops being the active room until uncovered', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // While covered, the chat must not be treated as the visible room:
    // incoming messages would otherwise be silently marked as read.
    expect(container.read(currentRoomIdProvider), isNull);
    final readCallsWhileCovered = rustApi.markRoomAsReadCalls;

    navigator.pop();
    await tester.pumpAndSettle();

    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(rustApi.markRoomAsReadCalls, greaterThan(readCallsWhileCovered));
  });

  testWidgets('a popup suspends reads without rebuilding room subscriptions', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final typingSubscriptions = rustApi.subscribeTypingCalls;
    final receiptSubscriptions = rustApi.subscribeRoomCalls;

    final context = tester.element(find.byType(ChatDetailPage));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('popup')),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(container.read(roomViewOwnerProvider('!room:example.org')), isNull);
    expect(rustApi.unsubscribeTypingCalls, 0);
    expect(rustApi.unsubscribeRoomCalls, 0);

    Navigator.of(tester.element(find.text('popup'))).pop();
    await tester.pumpAndSettle();

    expect(
      container.read(roomViewOwnerProvider('!room:example.org')),
      '@alice:example.org',
    );
    expect(rustApi.subscribeTypingCalls, typingSubscriptions);
    expect(rustApi.subscribeRoomCalls, receiptSubscriptions);
  });

  testWidgets('returning to a chat preserves pending unread suppression', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('management')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
        true;
    final readCallsWhileCovered = rustApi.markRoomAsReadCalls;

    navigator.pop();
    await tester.pumpAndSettle();

    expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);
    expect(rustApi.markRoomAsReadCalls, readCallsWhileCovered);
  });

  testWidgets('manual unread suppresses auto-read delayed by cache priming', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final encryptionCheck = Completer<bool>();
    rustApi.pendingRoomEncryption = encryptionCheck;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    expect(rustApi.markRoomAsReadCalls, 0);

    // The room-list action sets suppression before its unread request starts.
    // Finish cache priming only after that explicit action has won the race.
    container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
        true;
    encryptionCheck.complete(false);
    await tester.pump();
    await tester.pump();

    expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);
    expect(rustApi.markRoomAsReadCalls, 0);
  });

  testWidgets('backgrounding deactivates the room until the app resumes', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
    final readCallsBeforeBackground = rustApi.markRoomAsReadCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    // In the background the room is no longer "being viewed", so background
    // sync must not auto-mark incoming messages as read.
    expect(container.read(currentRoomIdProvider), isNull);
    expect(rustApi.unsubscribeTypingCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(rustApi.markRoomAsReadCalls, greaterThan(readCallsBeforeBackground));
  });

  testWidgets('transient inactive state keeps room subscriptions alive', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final typingSubscriptions = rustApi.subscribeTypingCalls;
    final receiptSubscriptions = rustApi.subscribeRoomCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(container.read(roomViewOwnerProvider('!room:example.org')), isNull);
    expect(rustApi.unsubscribeTypingCalls, 0);
    expect(rustApi.unsubscribeRoomCalls, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(
      container.read(roomViewOwnerProvider('!room:example.org')),
      '@alice:example.org',
    );
    expect(rustApi.subscribeTypingCalls, typingSubscriptions);
    expect(rustApi.subscribeRoomCalls, receiptSubscriptions);
  });

  testWidgets('resume waits for pending room unsubscriptions', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    final unsubscribeBarrier = Completer<void>();
    rustApi.typingUnsubscribeBarrier = unsubscribeBarrier;
    rustApi.roomUnsubscribeBarrier = unsubscribeBarrier;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(rustApi.unsubscribeTypingCalls, 1);
    expect(rustApi.unsubscribeRoomCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(rustApi.subscribeTypingCalls, 1);
    expect(rustApi.subscribeRoomCalls, 1);

    unsubscribeBarrier.complete();
    await tester.pump();
    await tester.pump();

    expect(rustApi.subscribeTypingCalls, 2);
    expect(rustApi.subscribeRoomCalls, 2);
    expect(rustApi.activeTypingRoom, '!room:example.org');
    expect(rustApi.activeReceiptRooms, contains('!room:example.org'));
  });

  testWidgets('popping a cover while paused does not reactivate the room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Pause the app, then pop the cover while still paused: the route
    // callback must not reactivate the room in the background.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    navigator.pop();
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Returning to the foreground reactivates it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
  });

  testWidgets('popping a cover while inactive does not reactivate the room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Pop the cover during a transient inactive window (e.g. notification
    // shade): the route callback must not reactivate the room.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
  });

  testWidgets('does not reactivate a chat route that is also being popped', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const Scaffold(body: SizedBox(key: ValueKey('root-route'))),
        ),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const ChatDetailPage(
            roomId: '!leaving:example.org',
            roomName: 'Leaving',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialReadCalls = rustApi.markRoomAsReadCalls;

    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    navigator.pop();
    await tester.pumpAndSettle();

    expect(find.byType(ChatDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('root-route')), findsOneWidget);
    expect(rustApi.markRoomAsReadCalls, initialReadCalls);
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
        child: MaterialApp(
          theme: neuTestTheme(),
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

  testWidgets('hides cached messages while the ignore list is unknown', (
    tester,
  ) async {
    const roomId = '!ignored-loading:example.org';
    final ignoredUsers = Completer<Set<String>>();
    final ownMessage = _ownMessage(r'$own', content: 'mine', timestamp: '2');
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) => ignoredUsers.future),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored'),
      ownMessage,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    // While the ignore list is unknown, no messages are exposed unfiltered.
    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.byKey(const ValueKey(r'text-bubble:$own')), findsNothing);

    ignoredUsers.complete(const {'@alice:example.org'});
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.byKey(const ValueKey(r'text-bubble:$own')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('keeps messages hidden when the ignore list fails to load', (
    tester,
  ) async {
    const roomId = '!ignored-failure:example.org';
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) => Future<Set<String>>.error(StateError('offline')),
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.text('无法加载忽略列表，消息已隐藏'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('loads older history when ignored messages empty the window', (
    tester,
  ) async {
    const roomId = '!ignored-window:example.org';
    final older = _ownMessage(
      r'$older-visible',
      content: 'older',
      timestamp: '0',
    );
    rustApi.messagesBefore = [older];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) async => const {'@alice:example.org'},
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored-anchor'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(1));
    expect(rustApi.messagesBeforeEventIds.first, r'$ignored-anchor');
    expect(
      find.byKey(const ValueKey(r'text-bubble:$older-visible')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a jump invalidates pagination during the encryption check', (
    tester,
  ) async {
    const roomId = '!pagination-jump-race:example.org';
    const userId = '@me:example.org';
    final stalePage = _ownMessage(
      r'$stale-page',
      content: 'stale page',
      timestamp: '0',
    );
    final jumpTarget = _ownMessage(
      r'$pagination-jump-target',
      content: 'jump target',
      timestamp: '50',
    );
    rustApi.messagesBefore = [stalePage];
    rustApi.messagesAround = [jumpTarget];
    rustApi.pinnedMessages = [jumpTarget];
    final encryptionCheck = Completer<bool>();
    rustApi.pendingRoomEncryption = encryptionCheck;
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) async => const {'@alice:example.org'},
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = userId;
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored-pagination-anchor'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value = userId;
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(1));

    await tester.tap(
      find.byKey(const ValueKey(r'pinned-message:$pagination-jump-target')),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$pagination-jump-target')),
      findsOneWidget,
    );

    encryptionCheck.complete(false);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$pagination-jump-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$stale-page')),
      findsNothing,
    );
  });

  testWidgets(
    'stops automatic back-pagination when every older page is ignored',
    (tester) async {
      const roomId = '!ignored-dead-end:example.org';
      // Every historical page is from an ignored sender: auto-pagination must
      // stop after one page instead of pulling the whole history.
      rustApi.messagesBefore = [
        _message(r'$ignored-1'),
        _message(r'$ignored-2'),
        _message(r'$ignored-3'),
      ];
      final container = ProviderContainer(
        overrides: [
          ignoredUserIdsProvider.overrideWith(
            (ref) async => const {'@alice:example.org'},
          ),
          roomMembersProvider(roomId).overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);
      await container.read(roomMembersProvider(roomId).future);
      container.read(messageCacheProvider(roomId).notifier).value = [
        _message(r'$ignored-anchor'),
      ];
      container.read(messageCacheOwnerProvider(roomId).notifier).value =
          'anonymous';
      container.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(1));
      // No visible message came back, so the timeline shows the manual retry
      // affordance and no further automatic pages are fetched.
      await tester.pump(const Duration(seconds: 1));
      final callsAfterIdle = rustApi.getMessagesBeforeCalls;
      await tester.pump(const Duration(seconds: 1));
      expect(rustApi.getMessagesBeforeCalls, callsAfterIdle);
      expect(
        find.byKey(const ValueKey(r'text-bubble:$ignored-1')),
        findsNothing,
      );
      expect(find.text('重试加载更早消息'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('removes newly ignored user messages from an open timeline', (
    tester,
  ) async {
    const roomId = '!ignored-live:example.org';
    var ignoredUsers = <String>{};
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => ignoredUsers),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$live-ignored'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$live-ignored')),
      findsOneWidget,
    );

    ignoredUsers = {'@alice:example.org'};
    container.invalidate(ignoredUserIdsProvider);
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$live-ignored')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('re-arms older-message loading after leaving a failed edge', (
    tester,
  ) async {
    const roomId = '!older-failure:example.org';
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    rustApi.messagesBeforeError = StateError('offline');
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = List.generate(
      120,
      (index) => _ownMessage(
        '\$cached-$index',
        content: 'cached $index',
        timestamp: '$index',
      ),
    );
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    final scrollController = scrollView.controller!;
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesBeforeCalls, 1);
    expect(find.textContaining('加载更早消息失败'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(rustApi.getMessagesBeforeCalls, 1);

    rustApi.messagesBeforeError = null;
    rustApi.messagesBefore = [
      _ownMessage(r'$automatic-retry', content: 'recovered', timestamp: '0'),
    ];
    scrollController.jumpTo(scrollController.position.minScrollExtent);
    await tester.pump();
    unawaited(
      scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.linear,
      ),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(2));
    expect(
      find.byKey(const ValueKey(r'text-bubble:$automatic-retry')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'a failed send offers retry and delete from its long-press menu',
    (tester) async {
      const roomId = '!failed-send:example.org';
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'doomed message');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingSend, isNotNull);

      // Fail the send: the bubble becomes a failed local message with an
      // error icon, and long-pressing must offer retry/delete instead of
      // being a dead end.
      rustApi.pendingSend!.completeError(StateError('offline'));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);

      final failedBubble = find.byKey(
        const ValueKey(r'text-bubble:$failed-message'),
      );
      expect(failedBubble, findsNothing);
      // Locate the failed bubble: it renders under the failed prefix id.
      final failedId = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'text-bubble:$localOutgoingFailedPrefix',
            ),
      );
      expect(failedId, findsOneWidget);

      // Delete from the long-press menu removes the failed message.
      await tester.scrollUntilVisible(
        failedId,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.longPress(failedId, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('删除消息'), findsOneWidget);
      await tester.tap(find.text('删除消息'));
      await tester.pumpAndSettle();
      expect(failedId, findsNothing);
      expect(tester.takeException(), isNull);

      // Let the send-flight expiry timer run out before the test ends.
      await tester.pump(const Duration(seconds: 3));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('retrying a failed send re-sends and marks the message sent', (
    tester,
  ) async {
    const roomId = '!failed-retry:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'retry me');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(rustApi.sentMessages, hasLength(1));
    rustApi.pendingSend!.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();

    final failedId = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'text-bubble:$localOutgoingFailedPrefix',
          ),
    );
    expect(failedId, findsOneWidget);

    // Retry: the send is attempted again and the message returns to a
    // normal (sent) state instead of staying failed.
    await tester.scrollUntilVisible(
      failedId,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.longPress(failedId, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试发送'));
    await tester.pump();
    await tester.pump();
    expect(rustApi.sentMessages, hasLength(2));

    // Complete the retry successfully; the failed bubble disappears.
    rustApi.pendingSend!.complete(r'$retried');
    await tester.pump();
    await tester.pump();
    expect(failedId, findsNothing);

    // Let the retry polling loop run to completion (~8s budget) so it
    // leaves no pending timers behind.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('retry polling reconciles the sent bubble via the timeline', (
    tester,
  ) async {
    // Regression: the retry path used to pass the *pending* id to the
    // polling loop after renaming the message to its `sent:` id, so the
    // first still-local check always failed and no timeline refresh ever
    // ran — the sent bubble then lingered until the next sync cycle.
    const roomId = '!retry-poll:example.org';
    // Count timeline fetches through a provider override: the polling loop
    // refreshes via messagesProvider, and without the override it would
    // short-circuit on the unset session instead of reaching the bridge.
    var getMessagesCalls = 0;
    final container = ProviderContainer(
      overrides: [
        messagesProvider(roomId).overrideWith((ref) async {
          getMessagesCalls++;
          return const <rust.ChatMessage>[];
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'retry poll');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    rustApi.pendingSend!.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();

    final failedId = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'text-bubble:$localOutgoingFailedPrefix',
          ),
    );
    expect(failedId, findsOneWidget);

    await tester.scrollUntilVisible(
      failedId,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.longPress(failedId, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试发送'));
    await tester.pump();
    await tester.pump();

    // The retry succeeds: the message flips to the sent state. The polling
    // loop must then poll the timeline (getMessages) instead of bailing out
    // on the first id mismatch.
    final readsBeforePoll = getMessagesCalls;
    rustApi.pendingSend!.complete(r'$retried-poll');
    await tester.pump();
    await tester.pump();
    expect(failedId, findsNothing);

    // Let the polling loop run; it must have refreshed the timeline at
    // least once.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(getMessagesCalls, greaterThan(readsBeforePoll));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('retrying a failed send re-stamps the message timestamp', (
    tester,
  ) async {
    const roomId = '!failed-retry-stamp:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final key = (roomId: roomId, userId: '@alice:example.org');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'retry stamp');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    rustApi.pendingSend!.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();

    final failedId = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'text-bubble:$localOutgoingFailedPrefix',
          ),
    );
    expect(failedId, findsOneWidget);
    final failedMessages = container.read(localOutgoingMessagesProvider(key));
    final failedTimestamp =
        int.tryParse(failedMessages.first.message.timestamp) ?? 0;

    // Retry through the long-press menu (same UI path as production).
    await tester.scrollUntilVisible(
      failedId,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.longPress(failedId, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试发送'));
    await tester.pump();
    await tester.pump();

    // The resent local message must carry a NEW timestamp: keeping the old
    // one would never match the server echo within the matcher's window and
    // leave a permanent duplicate bubble.
    final retriedMessages = container.read(localOutgoingMessagesProvider(key));
    final retried = retriedMessages
        .where(
          (message) =>
              message.message.id.startsWith(localOutgoingPendingPrefix),
        )
        .toList();
    expect(retried, hasLength(1));
    final retriedTimestamp = int.tryParse(retried.first.message.timestamp) ?? 0;
    expect(retriedTimestamp, greaterThan(failedTimestamp));

    rustApi.pendingSend!.complete(r'$retried-stamp');
    await tester.pump();
    await tester.pump();
    expect(failedId, findsNothing);

    // Let the retry polling loop run to completion (~8s budget) so it
    // leaves no pending timers behind.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
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
        child: MaterialApp(
          theme: neuTestTheme(),
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
        child: MaterialApp(
          theme: neuTestTheme(),
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

  testWidgets('sticker state survives local-to-remote reconciliation in chat', (
    tester,
  ) async {
    const roomId = '!sticker-reconcile:example.org';
    const flightId = 'sticker-anchor';
    const sourceImageUrl = 'https://example.org/remote-sticker.png';
    final localSticker = _ownMessage(
      '$localOutgoingSentPrefix$flightId',
      content: 'sticker',
      timestamp: '100',
      msgType: rust.MessageType.sticker,
      imageUrl: 'https://example.org/local-sticker.png',
      imageWidth: 512,
      imageHeight: 512,
    );
    final remoteSticker = _ownMessage(
      r'$remote-sticker-anchor',
      content: 'sticker',
      timestamp: '101',
      msgType: rust.MessageType.sticker,
      imageUrl: sourceImageUrl,
      imageWidth: 512,
      imageHeight: 512,
    );
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = const [];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container
        .read(
          localOutgoingMessagesProvider((
            roomId: roomId,
            userId: 'anonymous',
          )).notifier,
        )
        .value = [
      LocalOutgoingMessage(
        message: localSticker,
        sourceImageUrl: sourceImageUrl,
      ),
    ];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final localState = tester.state(find.byType(ImageMessageBubble));

    container.read(messageCacheProvider(roomId).notifier).value = [
      remoteSticker,
    ];
    await tester.pump();

    expect(tester.state(find.byType(ImageMessageBubble)), same(localState));
    await tester.pump();
    expect(tester.state(find.byType(ImageMessageBubble)), same(localState));
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
        child: MaterialApp(
          theme: neuTestTheme(),
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

    final sendButton = tester.widget<NeuIconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('send_only')),
        matching: find.byType(NeuIconButton),
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

  testWidgets('opening a chat reads the room without the explicit clear', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rustApi.markRoomAsReadCalls, greaterThan(0));
    // Opening a room relies on the store-checked inner clear (explicit:false);
    // the unconditional explicit write is reserved for the explicit
    // "标记为已读" actions.
    expect(rustApi.lastMarkReadExplicit, isFalse);
  });

  testWidgets('an open chat follows server-side room renames', (tester) async {
    rust.ChatRoom room(String name) => rust.ChatRoom(
      id: '!room:example.org',
      name: name,
      lastMessage: '',
      lastMessageTime: '',
      lastEventId: '',
      unreadCount: 0,
      isMarkedUnread: false,
      roomType: 'group',
      isEncrypted: false,
      isMuted: false,
      roomState: 'joined',
    );
    rustApi.chatRooms = [room('Old name')];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Old name',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Old name'), findsWidgets);

    // Another client renamed the room; the next room-list snapshot carries it.
    rustApi.chatRooms = [room('New name')];
    container.invalidate(chatRoomsProvider);
    await tester.pump();
    await tester.pump();

    expect(find.text('Old name'), findsNothing);
    expect(find.text('New name'), findsWidgets);
  });

  testWidgets('repeated local room names wait for the matching event echo', (
    tester,
  ) async {
    rust.ChatRoom room(String name, String nameEventId) => rust.ChatRoom(
      id: '!room:example.org',
      name: name,
      nameEventId: nameEventId,
      lastMessage: '',
      lastMessageTime: '',
      lastEventId: '',
      unreadCount: 0,
      isMarkedUnread: false,
      roomType: 'group',
      isEncrypted: false,
      isMuted: false,
      roomState: 'joined',
    );
    rustApi.chatRooms = [room('Name A', r'$name-a0')];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Name A',
            nameEventId: r'$name-a0',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('房间管理'));
    await tester.pumpAndSettle();

    final management = tester.widget<RoomManagementPage>(
      find.byType(RoomManagementPage),
    );
    management.onRoomDetailsChanged!(
      const RoomNamePatch(
        roomId: '!room:example.org',
        name: 'Name B',
        nameEventId: r'$name-b',
      ),
    );
    management.onRoomDetailsChanged!(
      const RoomNamePatch(
        roomId: '!room:example.org',
        name: 'Name A',
        nameEventId: r'$name-a2',
      ),
    );
    await tester.pump();
    Navigator.of(tester.element(find.byType(RoomManagementPage))).pop();
    await tester.pumpAndSettle();

    // Re-deliver the cached original A event. Its equal display value must not
    // confirm the final A edit.
    rustApi.chatRooms = [room('Name A', r'$name-a0')];
    container.invalidate(chatRoomsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Name A'), findsWidgets);

    // B is the real echo of the superseded first edit. Keep the final A.
    rustApi.chatRooms = [room('Name B', r'$name-b')];
    container.invalidate(chatRoomsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Name B'), findsNothing);
    expect(find.text('Name A'), findsWidgets);

    // Only the distinct event ID of the final A confirms the latest edit.
    rustApi.chatRooms = [room('Name A', r'$name-a2')];
    container.invalidate(chatRoomsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Name A'), findsWidgets);

    // A real remote edit may reuse B's value, but has its own event ID.
    rustApi.chatRooms = [room('Name B', r'$name-b-remote')];
    container.invalidate(chatRoomsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Name B'), findsWidgets);
  });
}
