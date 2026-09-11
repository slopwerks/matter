import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'helpers/neu_test_theme.dart';

void main() {
  testWidgets('long-press on the bubble edge opens the message menu', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      ProviderScope(
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
      ),
    );
    await tester.pumpAndSettle();
    // Press the bubble's edge padding: the formatted body is selectable,
    // so a long-press landing on the text starts selection instead of
    // opening the message menu.
    final bubbleRect = tester.getRect(
      find.byKey(const ValueKey('text-bubble:\$read')),
    );
    await tester.longPressAt(Offset(bubbleRect.right - 6, bubbleRect.top + 6));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('复制'), findsWidgets);
  });
}
