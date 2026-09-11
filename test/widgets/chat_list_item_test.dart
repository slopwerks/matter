import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:matter/src/rust/frb_generated.dart';

import '../helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  int markReadCalls = 0;
  int markUnreadCalls = 0;
  Object? markReadError;
  Object? markUnreadError;
  Completer<void>? pendingMarkUnread;

  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async {
    markReadCalls++;
    if (markReadError case final error?) throw error;
    return true;
  }

  @override
  Future<void> crateApiMatrixMarkRoomUnread({
    required String accountUserId,
    required String roomId,
  }) async {
    markUnreadCalls++;
    if (markUnreadError case final error?) throw error;
    await pendingMarkUnread?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

void main() {
  group('ChatListItem', () {
    late _FakeRustApi rustApi;

    setUpAll(() {
      rustApi = _FakeRustApi();
      RustLib.initMock(api: rustApi);
    });

    tearDownAll(RustLib.dispose);
    ChatRoom room({
      String id = '!room:example.org',
      String name = 'Room',
      String lastMessage = 'Hello',
      String lastMessageTime = '0',
      String lastEventId = '0',
      int unreadCount = 0,
      bool isMarkedUnread = false,
      bool isMuted = false,
      String roomType = 'group',
      String roomState = 'joined',
    }) => ChatRoom(
      id: id,
      name: name,
      lastMessage: lastMessage,
      lastMessageTime: lastMessageTime,
      lastEventId: lastEventId,
      unreadCount: unreadCount,
      isMarkedUnread: isMarkedUnread,
      roomType: roomType,
      isEncrypted: false,
      isMuted: isMuted,
      roomState: roomState,
    );

    testWidgets('renders room name and last message', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(body: ChatListItem(room: room())),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Room'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('draft replaces the preview and clearing restores it', (
      tester,
    ) async {
      const userId = '@alice:example.org';
      const roomId = '!room:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = userId;
      final draft = messageDraftProvider((roomId: roomId, userId: userId));
      container.read(draft.notifier).value = 'unfinished';

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId)),
            ),
          ),
        ),
      );

      expect(find.text('草稿：unfinished'), findsOneWidget);
      expect(find.text('Hello'), findsNothing);

      container.read(draft.notifier).value = '';
      await tester.pump();

      expect(find.text('草稿：unfinished'), findsNothing);
      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('draft only replaces the matching room preview', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(260, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const userId = '@alice:example.org';
      const roomA = '!room-a:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = userId;
      final draft = messageDraftProvider((roomId: roomA, userId: userId));
      container.read(draft.notifier).value = 'first line\nsecond line';

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: Column(
                children: [
                  ChatListItem(
                    room: room(
                      id: roomA,
                      name: 'Room A',
                      lastMessage: 'Message A',
                      unreadCount: 150,
                    ),
                  ),
                  ChatListItem(
                    room: room(
                      id: '!room-b:example.org',
                      name: 'Room B',
                      lastMessage: 'Message B',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('草稿：first line second line'), findsOneWidget);
      expect(find.text('Message A'), findsNothing);
      expect(find.text('Message B'), findsOneWidget);
      expect(find.text('99+'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows unread count badge', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(body: ChatListItem(room: room(unreadCount: 5))),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('caps unread badge at 99+', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(body: ChatListItem(room: room(unreadCount: 150))),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('shows a dot for an explicit unread marker', (tester) async {
      const roomId = '!marked-unread:example.org';
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId, isMarkedUnread: true)),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('room-unread-dot:$roomId')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('room-unread-badge:$roomId')),
        findsNothing,
      );
    });

    testWidgets('shows mute state in the room list', (tester) async {
      const roomId = '!muted:example.org';
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId, isMuted: true)),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('room-muted-icon:$roomId')),
        findsOneWidget,
      );
    });

    testWidgets('optimistic read state overrides stale unread counts', (
      tester,
    ) async {
      const roomId = '!optimistic-read:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(roomUnreadOverrideProvider(roomId).notifier)
          .value = const RoomUnreadOverride(
        unread: false,
        baselineUnreadCount: 5,
        baselineMarkedUnread: false,
        baselineLastEventId: '0',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId, unreadCount: 5)),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('room-unread-badge:$roomId')),
        findsNothing,
      );
    });

    testWidgets('optimistic unread state overrides stale read state', (
      tester,
    ) async {
      const roomId = '!optimistic-unread:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(roomUnreadOverrideProvider(roomId).notifier)
          .value = const RoomUnreadOverride(
        unread: true,
        baselineUnreadCount: 0,
        baselineMarkedUnread: false,
        baselineLastEventId: '0',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId)),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('room-unread-dot:$roomId')),
        findsOneWidget,
      );
    });

    testWidgets('new room snapshot invalidates an optimistic read state', (
      tester,
    ) async {
      const roomId = '!optimistic-new-message:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(roomUnreadOverrideProvider(roomId).notifier)
          .value = const RoomUnreadOverride(
        unread: false,
        baselineUnreadCount: 5,
        baselineMarkedUnread: false,
        baselineLastEventId: '0',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId, unreadCount: 6)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('6'), findsOneWidget);
      expect(container.read(roomUnreadOverrideProvider(roomId)), isNull);
    });

    testWidgets(
      'a room that advanced with the same counters invalidates an optimistic read state',
      (tester) async {
        const roomId = '!optimistic-advanced:example.org';
        final container = ProviderContainer();
        addTearDown(container.dispose);
        // The room was marked read at unreadCount 1; a new message arrived
        // before the refresh, so the refreshed room still has unreadCount 1
        // — and even the same millisecond timestamp. The changed latest-event
        // ID must drop the stale override.
        container
            .read(roomUnreadOverrideProvider(roomId).notifier)
            .value = const RoomUnreadOverride(
          unread: false,
          baselineUnreadCount: 1,
          baselineMarkedUnread: false,
          baselineLastEventId: r'$old-event',
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: neuTestTheme(),
              home: Scaffold(
                body: ChatListItem(
                  room: room(
                    id: roomId,
                    unreadCount: 1,
                    lastMessageTime: '100',
                    lastEventId: r'$new-event',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('1'), findsOneWidget);
        expect(container.read(roomUnreadOverrideProvider(roomId)), isNull);
      },
    );

    testWidgets('shows a person icon for dm rooms', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(roomType: 'dm')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    });

    testWidgets('shows a tree icon for space rooms', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(roomType: 'space')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.account_tree_rounded), findsOneWidget);
    });

    testWidgets('does not show room read actions for spaces', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(roomType: 'space')),
            ),
          ),
        ),
      );

      await tester.longPress(find.text('Room'));
      await tester.pumpAndSettle();

      expect(find.text('标记为已读'), findsNothing);
      expect(find.text('标记为未读'), findsNothing);
    });

    testWidgets('uses the dense layout when requested', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(body: ChatListItem(room: room(), dense: true)),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Room'), findsOneWidget);
    });

    testWidgets('uses the selection callback instead of pushing a route', (
      tester,
    ) async {
      ChatRoom? selectedRoom;
      final selected = room();

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(
                room: selected,
                isSelected: true,
                onRoomSelected: (room) => selectedRoom = room,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Room'));
      await tester.pump();

      expect(selectedRoom, selected);
      expect(find.byType(ChatListItem), findsOneWidget);
    });

    testWidgets('shows invite actions for invited rooms', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(roomState: 'invited')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('邀请你加入'), findsOneWidget);
      expect(find.text('接受'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
    });

    testWidgets('shows withdraw action for knocked rooms', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(roomState: 'knocked')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('等待对方批准'), findsOneWidget);
      expect(find.text('撤回'), findsOneWidget);
    });

    testWidgets('marking a room unread from the long-press menu works', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(sessionReadyProvider.notifier).value = true;
      rustApi.markUnreadCalls = 0;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId)),
            ),
          ),
        ),
      );
      await tester.longPress(find.text('Room'));
      await tester.pumpAndSettle();

      expect(find.text('标记为未读'), findsOneWidget);
      expect(find.text('标记为已读'), findsOneWidget);

      await tester.tap(find.text('标记为未读'));
      await tester.pumpAndSettle();

      expect(rustApi.markUnreadCalls, 1);
      expect(find.text('已标记为未读'), findsOneWidget);
      // The optimistic unread override and its suppression are applied.
      expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);
      expect(container.read(roomUnreadOverrideProvider(roomId)), isNotNull);
    });

    testWidgets('a failed room action restores the suppression', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(sessionReadyProvider.notifier).value = true;
      rustApi.markUnreadCalls = 0;
      rustApi.markUnreadError = StateError('offline');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId)),
            ),
          ),
        ),
      );
      await tester.longPress(find.text('Room'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标记为未读'));
      await tester.pumpAndSettle();

      expect(rustApi.markUnreadCalls, 1);
      // The sheet closes first so the failure message is actually visible.
      expect(find.text('标记为未读'), findsNothing);
      expect(find.textContaining('操作失败:'), findsOneWidget);
      // The failed action must not leave the room stuck in suppression.
      expect(container.read(roomAutoReadSuppressedProvider(roomId)), isFalse);

      rustApi.markUnreadError = null;
    });

    testWidgets('a result after the sheet was dismissed still surfaces', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(sessionReadyProvider.notifier).value = true;
      rustApi.markUnreadCalls = 0;
      rustApi.pendingMarkUnread = Completer<void>();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ChatListItem(room: room(id: roomId)),
            ),
          ),
        ),
      );
      await tester.longPress(find.text('Room'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标记为未读'));
      await tester.pump();

      // The user dismisses the sheet while the request is in flight.
      await tester.tapAt(const Offset(400, 60));
      await tester.pumpAndSettle();
      expect(find.text('标记为未读'), findsNothing);

      // The request completes after the sheet is gone: the result must
      // still be shown (without popping the route below the sheet).
      rustApi.pendingMarkUnread!.complete();
      await tester.pumpAndSettle();

      expect(find.text('已标记为未读'), findsOneWidget);
      expect(find.byType(ChatListItem), findsOneWidget);
      rustApi.pendingMarkUnread = null;
    });
  });
}
