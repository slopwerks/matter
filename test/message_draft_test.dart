import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_source_store.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async {
    return true;
  }

  Completer<String>? pendingSend;
  Completer<bool>? pendingEncryptionCheck;

  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    return (pendingSend ??= Completer<String>()).future;
  }

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) {
    return pendingEncryptionCheck?.future ?? Future.value(false);
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
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
    rustApi.pendingEncryptionCheck = null;
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
    await tester.pumpAndSettle();

    // The page was unmounted when the send completed: the optimistic entry
    // is dropped outright (its echo renders as a normal message via sync)
    // rather than marked "sent" and left to resurface as a stuck bubble on
    // the next visit.
    final outgoing = container.read(
      localOutgoingMessagesProvider((
        roomId: roomId,
        userId: '@alice:example.org',
      )),
    );
    expect(outgoing, isEmpty);
  });

  testWidgets('failed send after unmount marks the local message failed', (
    tester,
  ) async {
    const roomId = '!failed-after-unmount:example.org';
    const key = (roomId: roomId, userId: '@alice:example.org');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, roomId));
    await tester.enterText(find.byType(TextField), 'will fail');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(
      container.read(localOutgoingMessagesProvider(key)).single.message.id,
      startsWith(localOutgoingPendingPrefix),
    );

    await tester.pumpWidget(_home(container));
    rustApi.pendingSend!.completeError(StateError('offline'));
    await tester.pumpAndSettle();

    expect(
      container.read(localOutgoingMessagesProvider(key)).single.message.id,
      startsWith(localOutgoingFailedPrefix),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter sends a message from an Android hardware keyboard', (
    tester,
  ) async {
    await _runWithTargetPlatform(TargetPlatform.android, () async {
      const roomId = '!enter:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(_messageInput(container, roomId));
      await tester.enterText(find.byType(TextField), 'send with Enter');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(_inputText(tester), isEmpty);
      expect(rustApi.pendingSend, isNotNull);

      await tester.pumpWidget(_home(container));
      rustApi.pendingSend!.complete(r'$sent');
      await tester.pumpAndSettle();

      expect(
        await const MarkdownSourceStore().load(
          userId: '@alice:example.org',
          roomId: roomId,
          eventId: r'$sent',
          body: 'send with Enter',
          formattedBody: null,
          allowPersistence: true,
        ),
        'send with Enter',
      );
    });
  });

  testWidgets('edit prefill completion is ignored after unmount', (
    tester,
  ) async {
    const roomId = '!edit-unmount:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    rustApi.pendingEncryptionCheck = Completer<bool>();

    await tester.pumpWidget(_messageInput(container, roomId));
    container
            .read(
              editingMessageProvider((
                roomId: roomId,
                userId: '@alice:example.org',
              )).notifier,
            )
            .value =
        _messageToEdit();
    await tester.pump();

    await tester.pumpWidget(_home(container));
    rustApi.pendingEncryptionCheck!.complete(false);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('Shift+Enter does not send from an Android hardware keyboard', (
    tester,
  ) async {
    await _runWithTargetPlatform(TargetPlatform.android, () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(_messageInput(container, '!newline:example.org'));
      await tester.enterText(find.byType(TextField), 'first line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(_inputText(tester), 'first line');
      expect(rustApi.pendingSend, isNull);
    });
  });

  testWidgets('Tab replaces a named emoji without sending', (tester) async {
    await _runWithTargetPlatform(TargetPlatform.macOS, () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(_messageInput(container, '!emoji:example.org'));
      await tester.enterText(find.byType(TextField), ':thinking:');
      await tester.pump();

      expect(find.text(':thinking:'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(_inputText(tester), '🤔');
      expect(rustApi.pendingSend, isNull);
      expect(_autocompleteOptions(), findsNothing);
    });
  });

  testWidgets('desktop mouse click selects an autocomplete option', (
    tester,
  ) async {
    await _runWithTargetPlatform(TargetPlatform.macOS, () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(
        _messageInput(container, '!mouse-emoji:example.org'),
      );
      await tester.enterText(find.byType(TextField), ':thinking:');
      await tester.pump();
      final option = find.byKey(
        const ValueKey('composer-autocomplete-option-0'),
      );

      final mouse = await tester.startGesture(
        tester.getCenter(option),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.up();
      await tester.pump();

      expect(_inputText(tester), '🤔');
    });
  });

  testWidgets('autocomplete follows input method composing state', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, '!ime:example.org'));
    await tester.enterText(find.byType(TextField), ':thinking:');
    await tester.pump();
    expect(_autocompleteOptions(), findsWidgets);

    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    controller.value = const TextEditingValue(
      text: ':thinking:',
      selection: TextSelection.collapsed(offset: 10),
      composing: TextRange(start: 1, end: 9),
    );
    await tester.pump();
    expect(_autocompleteOptions(), findsNothing);

    controller.value = const TextEditingValue(
      text: ':thinking:',
      selection: TextSelection.collapsed(offset: 10),
    );
    await tester.pump();
    expect(_autocompleteOptions(), findsWidgets);
  });

  testWidgets('an unselected emoji name is sent as plain text', (tester) async {
    const roomId = '!plain-emoji:example.org';
    const key = (roomId: roomId, userId: '@alice:example.org');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, roomId));
    await tester.enterText(find.byType(TextField), ':thinking:');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(
      container.read(localOutgoingMessagesProvider(key)).single.message.content,
      ':thinking:',
    );
    await tester.pumpWidget(_home(container));
    rustApi.pendingSend!.complete(r'$plain-emoji');
    await tester.pumpAndSettle();
  });

  testWidgets('selecting a member inserts a Matrix user id', (tester) async {
    const roomId = '!mentions:example.org';
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith(
          (ref) async => const [
            rust.Contact(
              id: '@alice:example.org',
              name: 'Alice',
              status: '@alice:example.org',
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';

    await tester.pumpWidget(_messageInput(container, roomId));
    await tester.enterText(find.byType(TextField), '@ali');
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('composer-autocomplete-option-0')),
    );
    await tester.pump();

    expect(_inputText(tester), '@alice:example.org ');
  });

  testWidgets('selecting a room inserts its stable Matrix permalink', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    const selectedRoomId = '!general-b:example.org';
    final container = ProviderContainer(
      overrides: [
        chatRoomsProvider.overrideWith(
          (ref) async => [
            _room(id: '!general-a:example.org', name: 'General'),
            _room(id: selectedRoomId, name: 'General'),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, roomId));
    await tester.enterText(find.byType(TextField), 'see #gen');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('composer-autocomplete-option-1')),
    );
    await tester.pump();

    expect(
      _inputText(tester),
      'see [#General](https://matrix.to/#/${Uri.encodeComponent(selectedRoomId)}) ',
    );

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    final message = container
        .read(
          localOutgoingMessagesProvider((
            roomId: roomId,
            userId: '@alice:example.org',
          )),
        )
        .single
        .message;
    expect(message.content, 'see #General');
    expect(
      message.formattedBody,
      contains(Uri.encodeComponent(selectedRoomId)),
    );

    await tester.pumpWidget(_home(container));
    rustApi.pendingSend!.complete(r'$room-link');
    await tester.pumpAndSettle();
  });

  testWidgets('autocomplete caps large member result sets', (tester) async {
    const roomId = '!large:example.org';
    final members = List.generate(
      80,
      (index) => rust.Contact(
        id: '@member$index:example.org',
        name: 'Member $index',
        status: '@member$index:example.org',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => members),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, roomId));
    await tester.enterText(find.byType(TextField), '@');
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-autocomplete-panel')),
        matching: find.byType(ListView),
      ),
    );
    expect(
      (list.childrenDelegate as SliverChildBuilderDelegate).childCount,
      50,
    );
  });

  testWidgets('autocomplete list scrolls with a shorter narrow viewport', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    tester.view.physicalSize = const Size(390, 700);
    await tester.pumpWidget(_messageInput(container, '!narrow:example.org'));
    await tester.enterText(find.byType(TextField), ':');
    await tester.pump();
    final panel = find.byKey(const ValueKey('composer-autocomplete-panel'));
    final list = find.descendant(of: panel, matching: find.byType(ListView));
    expect(tester.getSize(list).height, 4 * 52 - 2);
    final narrowList = tester.widget<ListView>(list);
    expect(narrowList.controller!.position.maxScrollExtent, greaterThan(0));
    await tester.drag(panel, const Offset(0, -104));
    await tester.pumpAndSettle();
    expect(narrowList.controller!.offset, greaterThan(0));

    tester.view.physicalSize = const Size(1000, 700);
    await tester.pumpWidget(_messageInput(container, '!wide:example.org'));
    await tester.enterText(find.byType(TextField), ':');
    await tester.pump();
    final wideList = find.descendant(
      of: panel,
      matching: find.byType(ListView),
    );
    expect(tester.getSize(wideList).height, 8 * 52 - 2);
  });

  testWidgets('autocomplete panel stays inside a short viewport', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    tester.view.physicalSize = const Size(390, 150);
    await tester.pumpWidget(_messageInput(container, '!short:example.org'));
    await tester.enterText(find.byType(TextField), ':');
    await tester.pump();

    final panel = find.byKey(const ValueKey('composer-autocomplete-panel'));
    expect(tester.getTopLeft(panel).dy, greaterThanOrEqualTo(0));
    expect(tester.getBottomRight(panel).dy, lessThanOrEqualTo(150));
  });

  testWidgets('tool buttons do not overflow while shrinking for send', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(_messageInput(container, '!toolbar:example.org'));
    await tester.enterText(find.byType(TextField), 'message');
    await tester.pump(const Duration(milliseconds: 90));

    expect(tester.takeException(), isNull);
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

    container
            .read(
              editingMessageProvider((
                roomId: roomId,
                userId: '@alice:example.org',
              )).notifier,
            )
            .value =
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

rust.ChatRoom _room({required String id, required String name}) {
  return rust.ChatRoom(
    id: id,
    name: name,
    lastMessage: '',
    lastMessageTime: '',
    lastEventId: '',
    unreadCount: 0,
    isMarkedUnread: false,
    roomType: 'group',
    isEncrypted: false,
    isMuted: false,
    roomState: 'joined',
  );
}

Widget _messageInput(ProviderContainer container, String roomId) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: neuTestTheme(),
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

Finder _autocompleteOptions() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(
        'composer-autocomplete-option-',
      ),
);

Future<void> _runWithTargetPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}
