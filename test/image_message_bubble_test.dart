import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/src/rust/api/matrix.dart';

void main() {
  testWidgets('sticker uses a small repaint-isolated bubble without Hero', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ImageMessageBubble(
              imageUrl: 'https://example.org/sticker.png',
              imageWidth: 512,
              imageHeight: 512,
              isMe: false,
              heroTag: 'sticker-test',
              isSticker: true,
              metadata: SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Hero), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('msg-image:sticker-test'))),
      const Size(160, 160),
    );
  });

  testWidgets('media read indicator opens the readers sheet', (tester) async {
    const message = ChatMessage(
      id: r'$sticker',
      senderId: '@me:example.org',
      senderName: '我',
      content: 'sticker',
      timestamp: '100',
      isMe: true,
      msgType: MessageType.sticker,
      imageUrl: 'https://example.org/sticker.png',
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [
        MessageReader(userId: '@alice:example.org', displayName: 'Alice'),
      ],
      totalMembers: 2,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MessageGroupWidget(
              group: MessageGroup(
                senderId: message.senderId,
                senderName: message.senderName,
                isMe: true,
                messages: const [message],
              ),
              roomId: '!room:example.org',
              messageIndex: const {r'$sticker': message},
              showAvatar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final indicator = find.byKey(
      const ValueKey(r'message-read-receipt:$sticker'),
    );
    expect(indicator, findsOneWidget);
    expect(
      find.descendant(
        of: indicator,
        matching: find.byIcon(Icons.done_all_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(indicator);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('已读 1'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('text metadata is aligned to the bubble bottom right', (
    tester,
  ) async {
    const message = ChatMessage(
      id: r'$text',
      senderId: '@me:example.org',
      senderName: '我',
      content: '这是一条足够长的文本消息',
      timestamp: '100',
      isMe: true,
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
          home: Scaffold(
            body: MessageGroupWidget(
              group: MessageGroup(
                senderId: message.senderId,
                senderName: message.senderName,
                isMe: true,
                messages: const [message],
              ),
              roomId: '!room:example.org',
              messageIndex: const {r'$text': message},
              showAvatar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final bubbleRect = tester.getRect(
      find.byKey(const ValueKey(r'text-bubble:$text')),
    );
    final metadataRect = tester.getRect(
      find.byKey(const ValueKey(r'message-metadata:$text')),
    );
    expect(bubbleRect.right - metadataRect.right, closeTo(14, 0.1));
    expect(bubbleRect.bottom - metadataRect.bottom, closeTo(10, 0.1));
  });

  testWidgets('wrapped text lifts metadata into a short last line', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const message = ChatMessage(
      id: r'$wrapped',
      senderId: '@me:example.org',
      senderName: '我',
      content: '这是一条会自动换行而且最后一行比较短的文本消息',
      timestamp: '100',
      isMe: true,
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
          home: Scaffold(
            body: MessageGroupWidget(
              group: MessageGroup(
                senderId: message.senderId,
                senderName: message.senderName,
                isMe: true,
                messages: const [message],
              ),
              roomId: '!room:example.org',
              messageIndex: const {r'$wrapped': message},
              showAvatar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('metadata-inline')), findsOneWidget);
    expect(find.byKey(const ValueKey('metadata-below')), findsNothing);
  });
}
