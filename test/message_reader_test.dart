import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_reader_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'helpers/neu_test_theme.dart';

void main() {
  group('full-screen reader entry', () {
    const message = ChatMessage(
      id: r'$read',
      senderId: '@bob:example.org',
      senderName: 'Bob',
      content: '**Hello** markdown',
      formattedBody: '<p><strong>Hello</strong> markdown</p>',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '100',
      isMe: false,
      msgType: MessageType.text,
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [],
      totalMembers: 2,
    );

    Widget app() => ProviderScope(
      child: MaterialApp(
        theme: neuTestTheme(),
        home: Scaffold(
          body: MessageGroupWidget(
            group: MessageGroup(
              senderId: message.senderId,
              senderName: message.senderName,
              isMe: false,
              messages: const [message],
            ),
            roomId: '!room:example.org',
            messageIndex: const {r'$read': message},
            membersById: const {},
            showAvatar: false,
          ),
        ),
      ),
    );

    testWidgets('long-press menu opens the full-screen reader', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey('text-bubble:\$read')));
      await tester.pumpAndSettle();

      expect(find.text('全屏阅读'), findsOneWidget);
      await tester.tap(find.text('全屏阅读'));
      await tester.pumpAndSettle();

      expect(find.byType(MessageReaderPage), findsOneWidget);
      expect(find.text('Hello markdown', findRichText: true), findsOneWidget);
    });

    testWidgets('reader is not offered for plain-text messages', (
      tester,
    ) async {
      const plain = ChatMessage(
        id: r'$plain',
        senderId: '@bob:example.org',
        senderName: 'Bob',
        content: 'just plain text',
        formattedBody: null,
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '100',
        isMe: false,
        msgType: MessageType.text,
        isEdited: false,
        editHistory: [],
        reactions: [],
        readers: [],
        totalMembers: 2,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: MessageGroupWidget(
                group: MessageGroup(
                  senderId: plain.senderId,
                  senderName: plain.senderName,
                  isMe: false,
                  messages: const [plain],
                ),
                roomId: '!room:example.org',
                messageIndex: const {r'$plain': plain},
                membersById: const {},
                showAvatar: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.byKey(const ValueKey('text-bubble:\$plain')));
      await tester.pumpAndSettle();

      expect(find.text('全屏阅读'), findsNothing);
    });
  });

  testWidgets('starting an edit clears a previously selected reply', (
    tester,
  ) async {
    const roomId = '!edit-reply:example.org';
    const key = (roomId: roomId, userId: 'anonymous');
    const reply = ChatMessage(
      id: r'$reply',
      senderId: '@bob:example.org',
      senderName: 'Bob',
      content: 'reply target',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '99',
      isMe: false,
      msgType: MessageType.text,
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [],
      totalMembers: 2,
    );
    const ownMessage = ChatMessage(
      id: r'$own',
      senderId: '@alice:example.org',
      senderName: 'Alice',
      content: 'edit me',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '100',
      isMe: true,
      msgType: MessageType.text,
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [],
      totalMembers: 2,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(replyingToProvider(key).notifier).value = reply;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: MessageGroupWidget(
              group: MessageGroup(
                senderId: ownMessage.senderId,
                senderName: ownMessage.senderName,
                isMe: true,
                messages: const [ownMessage],
              ),
              roomId: roomId,
              messageIndex: const {r'$own': ownMessage},
              showAvatar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('text-bubble:\$own')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(container.read(editingMessageProvider(key))?.id, r'$own');
    expect(container.read(replyingToProvider(key)), isNull);
  });
}
