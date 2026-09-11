import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/neu_colors.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

ChatMessage _mentionMessage({required bool isMe}) => ChatMessage(
  id: isMe ? r'$mention-me' : r'$mention-other',
  senderId: isMe ? '@me:example.org' : '@bob:example.org',
  senderName: isMe ? '我' : 'Bob',
  content: 'hi @alice:example.org',
  mentionedUserIds: const ['@alice:example.org'],
  mentionsRoom: false,
  timestamp: '100',
  isMe: isMe,
  msgType: MessageType.text,
  inReplyTo: null,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 3,
);

TextSpan _mentionSpan(WidgetTester tester) {
  final finder = find.textContaining('@Alice', findRichText: true);
  expect(finder, findsOneWidget);
  final richText = tester.widget<RichText>(finder);
  TextSpan? found;
  void visit(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.text == '@Alice') found = span;
    span.children?.forEach(visit);
  }

  visit(richText.text);
  expect(found, isNotNull);
  return found!;
}

void main() {
  setUpAll(() {
    RustLib.initMock(api: _FakeRustApi());
  });

  tearDownAll(RustLib.dispose);

  testWidgets('mention highlight contrasts with the bubble background', (
    tester,
  ) async {
    for (final isMe in [true, false]) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final message = _mentionMessage(isMe: isMe);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: MessageGroupWidget(
                group: MessageGroup(
                  senderId: message.senderId,
                  senderName: message.senderName,
                  isMe: isMe,
                  messages: [message],
                ),
                roomId: '!room:example.org',
                messageIndex: {message.id: message},
                membersById: const {
                  '@alice:example.org': Contact(
                    id: '@alice:example.org',
                    name: 'Alice',
                    status: '',
                  ),
                },
                showAvatar: false,
              ),
            ),
          ),
        ),
      );

      expect(
        _mentionSpan(tester).style?.color,
        isMe ? Colors.white : NeuColors.dark.accent,
        reason: isMe ? 'own bubble' : 'other bubble',
      );
    }
  });
}
