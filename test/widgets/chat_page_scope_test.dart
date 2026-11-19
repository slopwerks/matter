import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  ChatRoom room({
    required String id,
    required String name,
    required String roomType,
  }) => ChatRoom(
    id: id,
    name: name,
    lastMessage: '',
    lastMessageTime: '0',
    lastEventId: '',
    unreadCount: 0,
    isMarkedUnread: false,
    roomType: roomType,
    isEncrypted: false,
    isMuted: false,
    roomState: 'joined',
  );

  testWidgets('direct message scope excludes group rooms', (tester) async {
    final directMessage = room(
      id: '!dm:example.org',
      name: 'Alice',
      roomType: 'dm',
    );
    final groupRoom = room(
      id: '!group:example.org',
      name: 'General',
      roomType: 'group',
    );
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith(
          (ref) async => [directMessage, groupRoom],
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const Scaffold(
            body: SizedBox(
              width: 320,
              height: 600,
              child: ChatPage(
                embedded: true,
                title: '私聊',
                directMessagesOnly: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('General'), findsNothing);
  });

  testWidgets('space scope shows only the selected space rooms', (
    tester,
  ) async {
    const spaceId = '!space:example.org';
    final spaceRoom = room(
      id: '!room:example.org',
      name: 'Announcements',
      roomType: 'group',
    );
    final container = ProviderContainer(
      overrides: [
        spaceChildrenProvider(spaceId).overrideWith((ref) async => [spaceRoom]),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const Scaffold(
            body: SizedBox(
              width: 320,
              height: 600,
              child: ChatPage(
                embedded: true,
                title: 'Workspace',
                spaceId: spaceId,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Announcements'), findsOneWidget);
  });
}
