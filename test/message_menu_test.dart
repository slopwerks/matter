import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/interaction_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/src/rust/api/matrix.dart';

import 'helpers/neu_test_theme.dart';

Widget _message({bool formatted = false}) {
  final message = ChatMessage(
    id: r'$read',
    senderId: '@bob:example.org',
    senderName: 'Bob',
    content: 'Select this text',
    formattedBody: formatted ? '<p><strong>Hello</strong> markdown</p>' : null,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: '100',
    isMe: false,
    msgType: MessageType.text,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  );
  return ProviderScope(
    child: MaterialApp(
      theme: neuTestTheme(),
      home: Scaffold(
        body: MessageGroupWidget(
          group: MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
            isMe: false,
            messages: [message],
          ),
          roomId: '!room:example.org',
          messageIndex: {r'$read': message},
          membersById: const {},
          showAvatar: false,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('mode switches message selection without disabling right-click', (
    tester,
  ) async {
    await tester.pumpWidget(_message());
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MessageGroupWidget)),
    );
    await container
        .read(interactionModeProvider.notifier)
        .setMode(InteractionMode.keyboardMouse);
    await tester.pumpAndSettle();
    expect(find.byType(SelectionArea), findsOneWidget);
    await container
        .read(interactionModeProvider.notifier)
        .setMode(InteractionMode.touch);
    await tester.pumpAndSettle();
    expect(find.byType(SelectionArea), findsNothing);
    final rect = tester.getRect(
      find.byKey(const ValueKey(r'text-bubble:$read')),
    );
    await tester.tapAt(
      Offset(rect.right - 6, rect.top + 6),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('回复'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('回复'), findsNothing);
  });

  testWidgets('long-press on the bubble edge opens the message menu', (
    tester,
  ) async {
    await tester.pumpWidget(_message(formatted: true));
    await tester.pumpAndSettle();
    // Formatted text starts selection on long press; padding opens actions.
    final rect = tester.getRect(
      find.byKey(const ValueKey(r'text-bubble:$read')),
    );
    await tester.longPressAt(Offset(rect.right - 6, rect.top + 6));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('复制'), findsWidgets);
  });

  for (final formatted in [false, true]) {
    testWidgets(
      'right-click opens message actions and Escape dismisses ($formatted)',
      (tester) async {
        await tester.pumpWidget(_message(formatted: formatted));
        await tester.pumpAndSettle();
        final rect = tester.getRect(
          find.byKey(const ValueKey(r'text-bubble:$read')),
        );
        await tester.tapAt(
          Offset(rect.right - 6, rect.top + 6),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(find.text('回复'), findsOneWidget);
        expect(find.text('转发'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('回复'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }

  testWidgets('desktop plain text can be dragged and copied', (tester) async {
    await tester.pumpWidget(_message());
    await tester.pumpAndSettle();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final rect = tester.getRect(find.text('Select this text'));
    final mouse = await tester.startGesture(
      Offset(rect.left + 1, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(Offset(rect.right - 1, rect.center.dy));
    await mouse.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, 'Select this text');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
