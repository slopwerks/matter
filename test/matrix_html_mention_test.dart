import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/matrix_html/matrix_html_renderer.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/src/rust/api/matrix.dart';

void main() {
  testWidgets('formatted mention remains breakable inline text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: MatrixHtmlMessage(
              html:
                  '前缀 <a href="https://matrix.to/#/%40alice%3Aexample.org">'
                  '@Ali</a> 后缀',
              style: TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
              mentionDisplayNames: {'@alice:example.org': 'Alice Wonderland'},
              trailingMetadata: Text('10:00'),
            ),
          ),
        ),
      ),
    );

    final paragraphs = tester.widgetList<RichText>(find.byType(RichText));
    final paragraph = paragraphs.singleWhere(
      (widget) => widget.text.toPlainText() == '前缀 @Alice Wonderland 后缀',
    );
    expect(_containsWidgetSpan(paragraph.text), isFalse);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('Matrix user links are not routed as external links', (
    tester,
  ) async {
    Uri? openedUri;
    String? mentionedUserId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MatrixHtmlMessage(
            html:
                '<a href="https://matrix.to/#/%40alice%3Aexample.org">'
                '@Ali</a>',
            style: const TextStyle(fontSize: 15),
            accentColor: Colors.cyan,
            onLinkTap: (uri) async => openedUri = uri,
            mentionDisplayNames: const {
              '@alice:example.org': 'Alice Wonderland',
            },
            onMentionTap: (userId) => mentionedUserId = userId,
          ),
        ),
      ),
    );

    expect(find.text('@Ali'), findsNothing);
    expect(find.text('@Alice Wonderland'), findsOneWidget);

    await tester.tap(find.text('@Alice Wonderland', findRichText: true));
    await tester.pump();

    expect(openedUri, isNull);
    expect(mentionedUserId, '@alice:example.org');
  });

  testWidgets('regular HTML links still use the external link handler', (
    tester,
  ) async {
    Uri? openedUri;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MatrixHtmlMessage(
            html: '<a href="https://example.org/profile">Website</a>',
            style: const TextStyle(fontSize: 15),
            accentColor: Colors.cyan,
            onLinkTap: (uri) async => openedUri = uri,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Website'));

    expect(openedUri, Uri.parse('https://example.org/profile'));
  });

  testWidgets('tapping a message mention opens the room member profile', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    const message = ChatMessage(
      id: r'$mention',
      senderId: '@bob:example.org',
      senderName: 'Bob',
      content: '@Ali',
      formattedBody:
          '<a href="https://matrix.to/#/%40alice%3Aexample.org">@Ali</a>',
      mentionedUserIds: ['@alice:example.org'],
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
              roomId: roomId,
              messageIndex: const {r'$mention': message},
              membersById: const {
                '@alice:example.org': Contact(
                  id: '@alice:example.org',
                  name: 'Alice Wonderland',
                  status: '@alice:example.org',
                ),
              },
              showAvatar: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('@Alice Wonderland', findRichText: true));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mention-profile:@alice:example.org')),
      findsOneWidget,
    );
    expect(find.text('Alice Wonderland'), findsOneWidget);
    expect(find.text('@alice:example.org'), findsOneWidget);
  });
}

bool _containsWidgetSpan(InlineSpan span) {
  if (span is WidgetSpan) return true;
  if (span is! TextSpan) return false;
  return span.children?.any(_containsWidgetSpan) ?? false;
}
