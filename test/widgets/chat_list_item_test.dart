import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';

void main() {
  group('ChatListItem', () {
    ChatRoom room({
      String id = '!room:example.org',
      String name = 'Room',
      String lastMessage = 'Hello',
      String lastMessageTime = '0',
      int unreadCount = 0,
      String roomType = 'group',
      String roomState = 'joined',
    }) => ChatRoom(
      id: id,
      name: name,
      lastMessage: lastMessage,
      lastMessageTime: lastMessageTime,
      unreadCount: unreadCount,
      roomType: roomType,
      isEncrypted: false,
      roomState: roomState,
    );

    testWidgets('renders room name and last message', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
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
            home: Scaffold(body: ChatListItem(room: room(unreadCount: 150))),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('shows a person icon for dm rooms', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
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
            home: Scaffold(
              body: ChatListItem(room: room(roomType: 'space')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.account_tree_rounded), findsOneWidget);
    });

    testWidgets('uses the dense layout when requested', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: ChatListItem(room: room(), dense: true)),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Room'), findsOneWidget);
    });

    testWidgets('shows invite actions for invited rooms', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
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
  });
}
