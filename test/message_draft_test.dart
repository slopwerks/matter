import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRustApi implements RustLibApi {
  Completer<String>? pendingSend;

  @override
  Future<String> crateApiMatrixSendMessage({
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    return (pendingSend ??= Completer<String>()).future;
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String roomId,
    required bool typing,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

void main() {
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    rustApi.pendingSend = null;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('restores separate drafts after leaving each room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, '!room-a:example.org'));
    await tester.enterText(find.byType(TextField), 'draft for room A');
    await tester.pump();

    await tester.pumpWidget(_home(container));
    await tester.pump();
    await tester.pumpWidget(_messageInput(container, '!room-b:example.org'));
    expect(_inputText(tester), isEmpty);

    await tester.enterText(find.byType(TextField), 'draft for room B');
    await tester.pump();
    await tester.pumpWidget(_home(container));
    await tester.pump();

    await tester.pumpWidget(_messageInput(container, '!room-a:example.org'));
    expect(_inputText(tester), 'draft for room A');
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);

    await tester.pumpWidget(_messageInput(container, '!room-b:example.org'));
    expect(_inputText(tester), 'draft for room B');

    await tester.pumpWidget(_home(container));
    await tester.pump();
  });

  testWidgets('keeps drafts separate for two accounts in the same room', (
    tester,
  ) async {
    const roomId = '!shared:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    await tester.pumpWidget(_messageInput(container, roomId));
    await tester.enterText(find.byType(TextField), 'Alice draft');
    await tester.pump();
    await tester.pumpWidget(_home(container));
    await tester.pump();

    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    await tester.pumpWidget(_messageInput(container, roomId));
    expect(_inputText(tester), isEmpty);
    await tester.enterText(find.byType(TextField), 'Bob draft');
    await tester.pump();
    await tester.pumpWidget(_home(container));
    await tester.pump();

    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    await tester.pumpWidget(_messageInput(container, roomId));
    expect(_inputText(tester), 'Alice draft');

    await tester.pumpWidget(_home(container));
    await tester.pump();
  });

  testWidgets('sending a message clears its stored draft', (tester) async {
    const roomId = '!send:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, roomId));
    await tester.enterText(find.byType(TextField), 'ready to send');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(_inputText(tester), isEmpty);
    expect(rustApi.pendingSend, isNotNull);

    await tester.pumpWidget(_home(container));
    await tester.pump();
    await tester.pumpWidget(_messageInput(container, roomId));
    expect(_inputText(tester), isEmpty);

    await tester.pumpWidget(_home(container));
    rustApi.pendingSend!.complete(r'$sent');
    await tester.pump();
  });

  testWidgets('editing a message does not overwrite the room draft', (
    tester,
  ) async {
    const roomId = '!edit:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, roomId));
    await tester.enterText(find.byType(TextField), 'unfinished draft');
    await tester.pump();

    container.read(editingMessageProvider(roomId).notifier).value =
        _messageToEdit();
    await tester.pump();
    await tester.pump();
    expect(_inputText(tester), 'message being edited');

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(_inputText(tester), 'unfinished draft');

    await tester.pumpWidget(_home(container));
    await tester.pump();
    await tester.pumpWidget(_messageInput(container, roomId));
    expect(_inputText(tester), 'unfinished draft');

    await tester.pumpWidget(_home(container));
    await tester.pump();
  });
}

rust.ChatMessage _messageToEdit() {
  return rust.ChatMessage(
    id: r'$edit',
    senderId: '@alice:example.org',
    senderName: 'Alice',
    content: 'message being edited',
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: '1',
    isMe: true,
    msgType: rust.MessageType.text,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  );
}

Widget _messageInput(ProviderContainer container, String roomId) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MessageInput(
            key: ValueKey('message-input-$roomId'),
            roomId: roomId,
            totalMembers: 2,
            panelMode: InputPanelMode.none,
            pickerHeight: 0,
            pickerFullHeight: 300,
            pickerBaseHeight: 300,
            pickerMaxHeight: 500,
            animatePickerHeight: false,
            onPanelModeChanged: (_) {},
            onPickerHeightChanged: (_) {},
            resolveSendPresentation: () => MessageSendPresentation.quiet,
            onMessageQueued: (_, _) {},
            onMessageSent: (_, _) {},
          ),
        ),
      ),
    ),
  );
}

Widget _home(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: SizedBox.shrink()),
  );
}

String _inputText(WidgetTester tester) {
  return tester.widget<TextField>(find.byType(TextField)).controller!.text;
}
