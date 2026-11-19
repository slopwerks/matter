import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_reader_page.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'helpers/neu_test_theme.dart';

void main() {
  testWidgets('reader mention taps use the root navigator context after the '
      'host is disposed by a layout switch', (tester) async {
    final message = ChatMessage(
      id: r'$read-mention',
      senderId: '@bob:example.org',
      senderName: 'Bob',
      content: 'check this out',
      // A formatted (markdown) body, entered through the real
      // _openReaderFullScreen wiring (long-press menu → 全屏阅读).
      formattedBody:
          '<p><a href="https://matrix.to/#/@alice:akass.cn">'
          '@alice:akass.cn</a></p>'
          '${List.generate(3, (_) => '<p>padding line</p>').join()}',
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

    final showHost = ValueNotifier(true);
    addTearDown(showHost.dispose);

    Widget app() => ProviderScope(
      child: MaterialApp(
        theme: neuTestTheme(),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: showHost,
            builder: (_, show, _) => show
                ? MessageGroupWidget(
                    group: MessageGroup(
                      senderId: message.senderId,
                      senderName: message.senderName,
                      isMe: false,
                      messages: [message],
                    ),
                    roomId: '!room:example.org',
                    messageIndex: {message.id: message},
                    remoteToLocalFlightId: const {},
                    insertionAnimationIds: const {},
                    showAvatar: false,
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // Long-press lands on the bubble's top padding: pressing the text itself
    // starts SelectionArea word selection instead of opening the menu.
    final bubble = find.byKey(const ValueKey(r'text-bubble:$read-mention'));
    await tester.longPressAt(tester.getTopLeft(bubble) + const Offset(40, 6));
    await tester.pumpAndSettle();
    expect(find.text('全屏阅读'), findsOneWidget);

    await tester.tap(find.text('全屏阅读'));
    await tester.pumpAndSettle();
    expect(find.byType(MessageReaderPage), findsOneWidget);

    // Layout switch: the host that opened the reader is disposed; the
    // reader route on the root navigator survives.
    showHost.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(MessageReaderPage), findsOneWidget);

    // The mention inside the reader taps through the root navigator
    // context captured by _openReaderFullScreen: the profile dialog still
    // opens with no exception after the host is gone.
    await tester.tap(find.text('@alice:akass.cn', findRichText: true));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('mention-profile:@alice:akass.cn')),
      findsOneWidget,
    );
  });
}
