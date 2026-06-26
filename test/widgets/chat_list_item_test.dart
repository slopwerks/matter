import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/src/rust/api/matrix.dart';

void main() {
  group('ChatListItem', () {
    ChatRoom room({
      String name = 'Room',
      String lastMessage = 'Hello',
      String lastMessageTime = '0',
      int unreadCount = 0,
      String roomType = 'group',
      String roomState = 'joined',
    }) => ChatRoom(
      id: '!room:example.org',
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
