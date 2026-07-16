import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/send_flight.dart';
import 'package:matter/providers/chat_provider.dart';
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
    expect(
      tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .useOldImageOnUrlChange,
      isTrue,
    );
  });

  testWidgets('sticker image state survives optimistic reconciliation', (
    tester,
  ) async {
    const localMessage = ChatMessage(
      id: '${localOutgoingSentPrefix}sticker-handoff',
      senderId: '@me:example.org',
      senderName: '我',
      content: 'sticker',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '100',
      isMe: true,
      msgType: MessageType.sticker,
      imageUrl: 'https://example.org/local-sticker.png',
      imageWidth: 512,
      imageHeight: 512,
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [],
      totalMembers: 2,
    );
    const remoteMessage = ChatMessage(
      id: r'$remote-sticker',
      senderId: '@me:example.org',
      senderName: '我',
      content: 'sticker',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '100',
      isMe: true,
      msgType: MessageType.sticker,
      imageUrl: 'https://example.org/remote-sticker.png',
      imageWidth: 512,
      imageHeight: 512,
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [],
      totalMembers: 2,
    );
    var message = localMessage;
    var remoteToLocalFlightId = const <String, String>{};
    var insertionAnimationIds = const {'sticker-handoff'};
    late StateSetter updateMessage;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                updateMessage = setState;
                return MessageGroupWidget(
                  group: MessageGroup(
                    senderId: message.senderId,
                    senderName: message.senderName,
                    isMe: true,
                    messages: [message],
                  ),
                  roomId: '!room:example.org',
                  messageIndex: {message.id: message},
                  remoteToLocalFlightId: remoteToLocalFlightId,
                  insertionAnimationIds: insertionAnimationIds,
                  showAvatar: false,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final localState = tester.state(find.byType(ImageMessageBubble));
    final flightTarget = tester.widget<SendFlightTarget>(
      find.byType(SendFlightTarget),
    );
    expect(flightTarget.endBorderRadius?.bottomRight.x, 10);

    updateMessage(() {
      message = remoteMessage;
      remoteToLocalFlightId = const {r'$remote-sticker': 'sticker-handoff'};
    });
    await tester.pump();

    expect(tester.state(find.byType(ImageMessageBubble)), same(localState));
    expect(
      find.byKey(const ValueKey('msg-image:image-preview:sticker-handoff')),
      findsOneWidget,
    );

    updateMessage(() => insertionAnimationIds = const {});
    await tester.pump();

    expect(tester.state(find.byType(ImageMessageBubble)), same(localState));
  });

  testWidgets('image caption is rendered below the media bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ImageMessageBubble(
              imageUrl: 'https://example.org/photo.png',
              imageWidth: 640,
              imageHeight: 480,
              caption: '这里是图片描述',
              isMe: false,
              heroTag: 'caption-test',
              metadata: SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('image-caption')), findsOneWidget);
    expect(find.byKey(const ValueKey('image-caption-bubble')), findsOneWidget);
    expect(find.text('这里是图片描述'), findsOneWidget);
    final imageRect = tester.getRect(
      find.byKey(const ValueKey('msg-image:caption-test')),
    );
    final captionRect = tester.getRect(
      find.byKey(const ValueKey('image-caption')),
    );
    expect(captionRect.top, closeTo(imageRect.bottom, 0.1));
  });

  testWidgets('short panoramic image uses a blurred minimum-height backdrop', (
    tester,
  ) async {
    const message = ChatMessage(
      id: r'$panorama',
      senderId: '@me:example.org',
      senderName: '我',
      content: 'panorama',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '100',
      isMe: true,
      msgType: MessageType.image,
      imageUrl: 'https://example.org/panorama.png',
      imageWidth: 2400,
      imageHeight: 200,
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
              messageIndex: const {r'$panorama': message},
              showAvatar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey(r'image-blurred-background:image-preview:$panorama'),
      ),
      findsOneWidget,
    );

    final imageRect = tester.getRect(
      find.byKey(const ValueKey(r'msg-image:image-preview:$panorama')),
    );
    final metadataRect = tester.getRect(
      find.byKey(const ValueKey(r'message-metadata:$panorama')),
    );
    expect(imageRect.height, 72);
    expect(metadataRect.top, greaterThanOrEqualTo(imageRect.top));
    expect(metadataRect.bottom, lessThanOrEqualTo(imageRect.bottom));
  });

  testWidgets('regular image does not add a blurred backdrop', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ImageMessageBubble(
              imageUrl: 'https://example.org/photo.png',
              imageWidth: 640,
              imageHeight: 480,
              isMe: false,
              heroTag: 'regular-photo',
              metadata: SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('image-blurred-background:regular-photo')),
      findsNothing,
    );
  });

  testWidgets('media read indicator opens the readers sheet', (tester) async {
    const message = ChatMessage(
      id: r'$sticker',
      senderId: '@me:example.org',
      senderName: '我',
      content: 'sticker',
      mentionedUserIds: [],
      mentionsRoom: false,
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

  testWidgets(
    'reply preview width keeps short text metadata inline at bubble edge',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const original = ChatMessage(
        id: r'$original',
        senderId: '@alice:example.org',
        senderName: 'Alice',
        content: '这是一条很长很长的被回复消息内容，用来把回复预览撑到接近气泡最大宽度',
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '90',
        isMe: false,
        msgType: MessageType.text,
        isEdited: false,
        editHistory: [],
        reactions: [],
        readers: [],
        totalMembers: 2,
      );
      const reply = ChatMessage(
        id: r'$reply',
        senderId: '@me:example.org',
        senderName: '我',
        content: '收到',
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '100',
        isMe: true,
        msgType: MessageType.text,
        inReplyTo: r'$original',
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
                  senderId: reply.senderId,
                  senderName: reply.senderName,
                  isMe: true,
                  messages: const [reply],
                ),
                roomId: '!room:example.org',
                messageIndex: const {r'$original': original, r'$reply': reply},
                showAvatar: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final bubbleRect = tester.getRect(
        find.byKey(const ValueKey(r'text-bubble:$reply')),
      );
      final metadataRect = tester.getRect(
        find.byKey(const ValueKey(r'message-metadata:$reply')),
      );

      expect(find.byKey(const ValueKey('metadata-inline')), findsOneWidget);
      expect(find.byKey(const ValueKey('metadata-below')), findsNothing);
      expect(bubbleRect.right - metadataRect.right, closeTo(14, 0.1));
      expect(bubbleRect.bottom - metadataRect.bottom, closeTo(10, 0.1));
    },
  );

  testWidgets(
    'reply preview width keeps formatted text metadata inline at bubble edge',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const original = ChatMessage(
        id: r'$formatted-original',
        senderId: '@alice:example.org',
        senderName: 'Alice',
        content: '这是一条很长很长的被回复消息内容，用来把回复预览撑到接近气泡最大宽度',
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '90',
        isMe: false,
        msgType: MessageType.text,
        isEdited: false,
        editHistory: [],
        reactions: [],
        readers: [],
        totalMembers: 2,
      );
      const reply = ChatMessage(
        id: r'$formatted-reply',
        senderId: '@me:example.org',
        senderName: '我',
        content: '光环新作',
        formattedBody: '<p>光环新作</p>',
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '100',
        isMe: true,
        msgType: MessageType.text,
        inReplyTo: r'$formatted-original',
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
                  senderId: reply.senderId,
                  senderName: reply.senderName,
                  isMe: true,
                  messages: const [reply],
                ),
                roomId: '!room:example.org',
                messageIndex: const {
                  r'$formatted-original': original,
                  r'$formatted-reply': reply,
                },
                showAvatar: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final bubbleRect = tester.getRect(
        find.byKey(const ValueKey(r'text-bubble:$formatted-reply')),
      );
      final metadataRect = tester.getRect(
        find.byKey(const ValueKey(r'message-metadata:$formatted-reply')),
      );
      final bodyRect = tester.getRect(find.text('光环新作', findRichText: true));

      expect(metadataRect.top, lessThan(bodyRect.bottom));
      expect(bubbleRect.right - metadataRect.right, closeTo(14, 0.1));
      expect(bubbleRect.bottom - metadataRect.bottom, closeTo(10, 0.1));
    },
  );

  testWidgets(
    'reply preview width keeps structured rich text metadata on its last line',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const original = ChatMessage(
        id: r'$structured-original',
        senderId: '@alice:example.org',
        senderName: 'Alice',
        content: '这是一条很长很长的被回复消息内容，用来把回复预览撑到接近气泡最大宽度',
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '90',
        isMe: false,
        msgType: MessageType.text,
        isEdited: false,
        editHistory: [],
        reactions: [],
        readers: [],
        totalMembers: 2,
      );
      const reply = ChatMessage(
        id: r'$structured-reply',
        senderId: '@me:example.org',
        senderName: '我',
        content: '第一项\n第二项',
        formattedBody: '<ul><li>第一项</li><li><strong>第二项</strong></li></ul>',
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '100',
        isMe: true,
        msgType: MessageType.text,
        inReplyTo: r'$structured-original',
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
                  senderId: reply.senderId,
                  senderName: reply.senderName,
                  isMe: true,
                  messages: const [reply],
                ),
                roomId: '!room:example.org',
                messageIndex: const {
                  r'$structured-original': original,
                  r'$structured-reply': reply,
                },
                showAvatar: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final bubbleRect = tester.getRect(
        find.byKey(const ValueKey(r'text-bubble:$structured-reply')),
      );
      final bodyRect = tester.getRect(find.text('第二项', findRichText: true));
      final metadataRect = tester.getRect(
        find.byKey(const ValueKey(r'message-metadata:$structured-reply')),
      );

      expect(metadataRect.top, lessThan(bodyRect.bottom));
      expect(bubbleRect.right - metadataRect.right, closeTo(14, 0.1));
      expect(bubbleRect.bottom - metadataRect.bottom, closeTo(10, 0.1));
    },
  );

  testWidgets('metadata survives formatted body structure changes', (
    tester,
  ) async {
    Widget buildMessage(String content, String? formattedBody) {
      final message = ChatMessage(
        id: r'$structure-change',
        senderId: '@me:example.org',
        senderName: '我',
        content: content,
        formattedBody: formattedBody,
        mentionedUserIds: const [],
        mentionsRoom: false,
        timestamp: '100',
        isMe: true,
        msgType: MessageType.text,
        isEdited: false,
        editHistory: const [],
        reactions: const [],
        readers: const [],
        totalMembers: 2,
      );
      return ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MessageGroupWidget(
              group: MessageGroup(
                senderId: message.senderId,
                senderName: message.senderName,
                isMe: true,
                messages: [message],
              ),
              roomId: '!room:example.org',
              messageIndex: {message.id: message},
              showAvatar: false,
            ),
          ),
        ),
      );
    }

    const bodies = [
      ('段落', '<p>段落</p>'),
      ('第一项\n第二项', '<ul><li>第一项</li><li>第二项</li></ul>'),
      ('引用', '<blockquote><p>引用</p></blockquote>'),
      ('code', '<pre><code>code</code></pre>'),
      ('普通文本', null),
      ('标题', '<h1>标题</h1>'),
      ('链接', '<p><a href="https://example.org">链接</a></p>'),
    ];

    for (final body in bodies) {
      await tester.pumpWidget(buildMessage(body.$1, body.$2));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey(r'message-metadata:$structure-change')),
        findsOneWidget,
      );
    }
  });

  testWidgets('own text bubble keeps read-indicator space before member data', (
    tester,
  ) async {
    Widget buildMessage(int totalMembers) {
      final message = ChatMessage(
        id: r'$stable-read-space',
        senderId: '@me:example.org',
        senderName: '我',
        content: '短消息',
        mentionedUserIds: const [],
        mentionsRoom: false,
        timestamp: '100',
        isMe: true,
        msgType: MessageType.text,
        isEdited: false,
        editHistory: const [],
        reactions: const [],
        readers: const [],
        totalMembers: totalMembers,
      );
      return ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MessageGroupWidget(
              group: MessageGroup(
                senderId: message.senderId,
                senderName: message.senderName,
                isMe: true,
                messages: [message],
              ),
              roomId: '!room:example.org',
              messageIndex: {message.id: message},
              showAvatar: false,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildMessage(0));
    await tester.pump();
    final sizeBeforeMembers = tester.getSize(
      find.byKey(const ValueKey(r'text-bubble:$stable-read-space')),
    );
    expect(
      find.byKey(const ValueKey(r'message-read-receipt:$stable-read-space')),
      findsNothing,
    );

    await tester.pumpWidget(buildMessage(2));
    await tester.pump();
    final sizeAfterMembers = tester.getSize(
      find.byKey(const ValueKey(r'text-bubble:$stable-read-space')),
    );

    expect(sizeAfterMembers, sizeBeforeMembers);
    expect(
      find.byKey(const ValueKey(r'message-read-receipt:$stable-read-space')),
      findsOneWidget,
    );
  });

  testWidgets('outgoing message groups use joined corners', (tester) async {
    const first = ChatMessage(
      id: r'$group-first',
      senderId: '@me:example.org',
      senderName: '我',
      content: '第一条',
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
    const last = ChatMessage(
      id: r'$group-last',
      senderId: '@me:example.org',
      senderName: '我',
      content: '第二条',
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '101',
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
                senderId: first.senderId,
                senderName: first.senderName,
                isMe: true,
                messages: const [first, last],
              ),
              roomId: '!room:example.org',
              messageIndex: const {
                r'$group-first': first,
                r'$group-last': last,
              },
              showAvatar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    BorderRadius radiusFor(Key key) {
      final container = tester.widget<Container>(find.byKey(key));
      return (container.decoration! as BoxDecoration).borderRadius!
          as BorderRadius;
    }

    final firstRadius = radiusFor(const ValueKey(r'text-bubble:$group-first'));
    final lastRadius = radiusFor(const ValueKey(r'text-bubble:$group-last'));
    expect(firstRadius.bottomRight.x, 6);
    expect(lastRadius.topRight.x, 6);
    expect(lastRadius.bottomRight.x, 10);
  });

  testWidgets('group-chat incoming messages keep the sticky avatar slot', (
    tester,
  ) async {
    const message = ChatMessage(
      id: r'$incoming-avatar',
      senderId: '@alice:example.org',
      senderName: 'Alice',
      content: '你好',
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
          home: Scaffold(
            body: MessageGroupWidget(
              group: MessageGroup(
                senderId: message.senderId,
                senderName: message.senderName,
                isMe: false,
                messages: const [message],
              ),
              roomId: '!room:example.org',
              messageIndex: const {r'$incoming-avatar': message},
              showAvatar: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('sticky-group-avatar-slot')),
      findsOneWidget,
    );
    expect(find.text('A'), findsOneWidget);
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
