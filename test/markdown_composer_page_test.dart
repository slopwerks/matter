import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_source_store.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/markdown_composer_page.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  Completer<String>? pendingSend;
  Completer<String>? pendingReply;
  Completer<String>? pendingEdit;
  rust.FormattedMessageInput? lastMessage;
  String? lastAccountUserId;
  String? lastReplyToEventId;
  List<String>? lastPreviousMentionedUserIds;
  bool? lastPreviousMentionsRoom;
  final typingNotices = <bool>[];
  final typingNoticeAccountUserIds = <String>[];
  int getMessagesCalls = 0;

  /// When set, [crateApiMatrixIsRoomEncrypted] waits on this completer
  /// instead of resolving immediately, letting a test hold the edit-prefill
  /// pipeline open at its async store read (see the prefill race test).
  Completer<bool>? blockedIsRoomEncrypted;

  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    lastAccountUserId = accountUserId;
    lastMessage = message;
    return (pendingSend ??= Completer<String>()).future;
  }

  @override
  Future<String> crateApiMatrixEditMessage({
    required String accountUserId,
    required String roomId,
    required String eventId,
    required rust.FormattedMessageInput message,
    required List<String> previousMentionedUserIds,
    required bool previousMentionsRoom,
  }) {
    lastAccountUserId = accountUserId;
    lastMessage = message;
    lastPreviousMentionedUserIds = previousMentionedUserIds;
    lastPreviousMentionsRoom = previousMentionsRoom;
    return (pendingEdit ??= Completer<String>()).future;
  }

  @override
  Future<String> crateApiMatrixSendReply({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
    required String replyToEventId,
    String? replyToUserId,
  }) {
    lastAccountUserId = accountUserId;
    lastMessage = message;
    lastReplyToEventId = replyToEventId;
    return (pendingReply ??= Completer<String>()).future;
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessages({
    required String roomId,
  }) {
    getMessagesCalls++;
    return Future.value(const <rust.ChatMessage>[]);
  }

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async {
    final blocked = blockedIsRoomEncrypted;
    if (blocked != null) return blocked.future;
    return false;
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {
    typingNoticeAccountUserIds.add(accountUserId);
    typingNotices.add(typing);
  }

  @override
  Future<List<String>> crateApiMatrixGetPinnedEventIds({
    required String accountUserId,
    required String roomId,
  }) async => const [];

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
    rustApi.pendingReply = null;
    rustApi.pendingEdit = null;
    rustApi.blockedIsRoomEncrypted = null;
    rustApi.lastMessage = null;
    rustApi.lastReplyToEventId = null;
    rustApi.lastPreviousMentionedUserIds = null;
    rustApi.lastPreviousMentionsRoom = null;
    rustApi.typingNotices.clear();
    rustApi.typingNoticeAccountUserIds.clear();
    rustApi.getMessagesCalls = 0;
    SharedPreferences.setMockInitialValues({});
  });

  group('MarkdownComposerPage', () {
    Future<void> openComposer(
      WidgetTester tester, {
      String initialText = '',
      required Future<bool> Function(String text, WidgetRef ref) onSend,
      void Function(MarkdownComposerResult? result)? onResult,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final result = await Navigator.of(context)
                      .push<MarkdownComposerResult>(
                        MaterialPageRoute(
                          fullscreenDialog: true,
                          builder: (_) => MarkdownComposerPage(
                            initialText: initialText,
                            onSend: onSend,
                          ),
                        ),
                      );
                  onResult?.call(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownComposerPage), findsOneWidget);
    }

    testWidgets('preview renders the compiled markdown, tables included', (
      tester,
    ) async {
      await openComposer(
        tester,
        initialText: '| Name | Value |\n|---|---|\n| Alice | 7 |',
        onSend: (_, _) async => false,
      );

      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();

      expect(find.text('Name', findRichText: true), findsOneWidget);
      expect(find.text('Alice', findRichText: true), findsOneWidget);
      // Switching back to edit mode keeps the source untouched.
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byType(MarkdownComposerPage),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '| Name | Value |\n|---|---|\n| Alice | 7 |',
      );
    });

    testWidgets('send delivers the text and closes with a sent result', (
      tester,
    ) async {
      String? sentText;
      MarkdownComposerResult? result;
      await openComposer(
        tester,
        onSend: (text, _) async {
          sentText = text;
          return true;
        },
        onResult: (r) => result = r,
      );

      await tester.enterText(find.byType(TextField), '**hi** there');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(sentText, '**hi** there');
      expect(result?.sent, isTrue);
      expect(find.byType(MarkdownComposerPage), findsNothing);
    });

    testWidgets('failed send keeps the editor open with its draft', (
      tester,
    ) async {
      var sendAttempts = 0;
      var resultDelivered = false;
      await openComposer(
        tester,
        onSend: (_, _) async {
          sendAttempts++;
          return false;
        },
        onResult: (_) => resultDelivered = true,
      );

      await tester.enterText(find.byType(TextField), 'do not lose me');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(sendAttempts, 1);
      expect(find.byType(MarkdownComposerPage), findsOneWidget);
      expect(resultDelivered, isFalse);
    });

    testWidgets('closing returns the edited draft', (tester) async {
      MarkdownComposerResult? result;
      await openComposer(
        tester,
        initialText: 'draft',
        onSend: (_, _) async => false,
        onResult: (r) => result = r,
      );

      await tester.enterText(find.byType(TextField), 'draft v2');
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(result?.sent, isFalse);
      expect(result?.text, 'draft v2');
    });

    testWidgets('system back returns the edited draft instead of dropping '
        'it', (tester) async {
      MarkdownComposerResult? result;
      await openComposer(
        tester,
        onSend: (_, _) async => false,
        onResult: (r) => result = r,
      );

      await tester.enterText(find.byType(TextField), 'kept across back');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(result?.sent, isFalse);
      expect(result?.text, 'kept across back');
    });

    testWidgets('a rapid second close does not pop the page underneath', (
      tester,
    ) async {
      var resultCount = 0;
      await openComposer(
        tester,
        onSend: (_, _) async => false,
        onResult: (_) => resultCount++,
      );

      // The first tap starts the pop animation; while the composer is
      // still animating out, a system back (or a second tap) lands on the
      // same page and must be swallowed by the closing latch.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(resultCount, 1);
      expect(find.byType(MarkdownComposerPage), findsNothing);
      // The host page survived: only the composer route was popped.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('closing during an in-flight send consumes the text, and '
        'the late send completion does not pop again', (tester) async {
      final sendCompleter = Completer<bool>();
      MarkdownComposerResult? result;
      await openComposer(
        tester,
        onSend: (_, _) => sendCompleter.future,
        onResult: (r) => result = r,
      );

      await tester.enterText(find.byType(TextField), 'in flight');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      // Closing mid-send takes effect immediately: the text was already
      // handed to the send pipeline, so the close reports it consumed
      // (sent, empty text) instead of returning it as a draft.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(result?.sent, isTrue);
      expect(result?.text, isEmpty);
      expect(find.byType(MarkdownComposerPage), findsNothing);
      // Only the composer route was popped: the host page survived.
      expect(find.text('open'), findsOneWidget);

      // The late send completion is swallowed by the closing latch: no
      // second pop.
      sendCompleter.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('closing while the send never settles still closes '
        'immediately', (tester) async {
      final neverCompleter = Completer<bool>();
      MarkdownComposerResult? result;
      await openComposer(
        tester,
        onSend: (_, _) => neverCompleter.future,
        onResult: (r) => result = r,
      );

      await tester.enterText(find.byType(TextField), 'in flight forever');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      // The network call never settles, but closing must still leave right
      // away — a parked close behind an endless request would strand the
      // user in the editor. The spinner animates while the route is up, so
      // no pumpAndSettle until the pop animation has finished.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      expect(find.byType(MarkdownComposerPage), findsNothing);
      expect(result?.sent, isTrue);
      expect(result?.text, isEmpty);
    });
  });

  group('message input integration', () {
    Widget messageInput(ProviderContainer container, String roomId) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MessageInput(
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

    Finder composerField() => find.descendant(
      of: find.byType(MarkdownComposerPage),
      matching: find.byType(TextField),
    );

    // skipOffstage: false everywhere — the input sits under the opaque
    // composer route.
    Finder inputField() => find.descendant(
      of: find.byType(MessageInput, skipOffstage: false),
      matching: find.byType(TextField, skipOffstage: false),
      skipOffstage: false,
    );

    /// A persistent MaterialApp/Navigator whose body can drop the input,
    /// mimicking a responsive layout switch disposing the chat page while
    /// the composer route (pushed on the root navigator) stays open.
    Future<ValueNotifier<bool>> pumpSwitchableHost(
      WidgetTester tester,
      ProviderContainer container,
      String roomId,
    ) async {
      final showInput = ValueNotifier(true);
      addTearDown(showInput.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: showInput,
                builder: (_, show, _) => show
                    ? Align(
                        alignment: Alignment.bottomCenter,
                        child: MessageInput(
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
                          resolveSendPresentation: () =>
                              MessageSendPresentation.quiet,
                          onMessageQueued: (_, _) {},
                          onMessageSent: (_, _) {},
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      return showInput;
    }

    rust.ChatMessage chatMessage({
      required String id,
      required String senderId,
      required String content,
      required bool isMe,
    }) => rust.ChatMessage(
      id: id,
      senderId: senderId,
      senderName: senderId,
      content: content,
      formattedBody: null,
      mentionedUserIds: [],
      mentionsRoom: false,
      timestamp: '100',
      isMe: isMe,
      msgType: rust.MessageType.text,
      isEdited: false,
      editHistory: [],
      reactions: [],
      readers: [],
      totalMembers: 2,
    );

    Future<void> openInputComposer(WidgetTester tester) async {
      await tester.longPress(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Markdown 编辑器'));
      await tester.pumpAndSettle();
    }

    testWidgets('composer edits flow back into the input draft', (
      tester,
    ) async {
      const roomId = '!composer-draft:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      await tester.enterText(find.byType(TextField), 'hello');
      await openInputComposer(tester);

      expect(find.byType(MarkdownComposerPage), findsOneWidget);
      expect(
        tester.widget<TextField>(composerField()).controller!.text,
        'hello',
      );

      await tester.enterText(composerField(), 'hello **markdown**');
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownComposerPage), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'hello **markdown**',
      );
      expect(container.read(messageDraftProvider(key)), 'hello **markdown**');
    });

    testWidgets('attachment tools remain available while the draft changes', (
      tester,
    ) async {
      const roomId = '!composer-entry:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'short');
      await tester.pump();
      expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'a' * 81);
      await tester.pump();
      expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);

      // Let the typing timers (idle stop + keep-alive) run out so none are
      // left pending at the end of the test.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('wide layouts do not add a dedicated editor icon', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      const roomId = '!composer-entry-wide:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    });

    testWidgets('long-pressing attachment opens the composer with a draft', (
      tester,
    ) async {
      const roomId = '!composer-menu:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      await tester.enterText(find.byType(TextField), 'draft');
      await tester.pump();
      await tester.longPress(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Markdown 编辑器'), findsOneWidget);
      await tester.tap(find.text('Markdown 编辑器'));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownComposerPage), findsOneWidget);
    });

    testWidgets('composer edits sync to the draft provider while open', (
      tester,
    ) async {
      const roomId = '!composer-live-sync:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      await openInputComposer(tester);

      await tester.enterText(composerField(), 'live synced');
      await tester.pump();
      expect(container.read(messageDraftProvider(key)), 'live synced');

      // Flush the typing timers started by the draft ping.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('composer still sends after the input host is disposed by a '
        'layout switch', (tester) async {
      const roomId = '!composer-disposed:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'hello');
      await tester.pump();
      expect(container.read(messageDraftProvider(key)), 'hello');

      // Layout switch: the input state is disposed; the composer stays.
      showInput.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownComposerPage), findsOneWidget);

      // The disposed input sent its final `false`; further edits in the
      // surviving route must start a fresh notice through the route-owned
      // fallback instead of silently losing typing state.
      rustApi.typingNotices.clear();
      await tester.enterText(composerField(), 'hello after layout switch');
      await tester.pump();
      expect(rustApi.typingNotices, contains(true));

      // The input host is gone, but the composer falls back to provider-
      // only state, so sending still initiates (instead of degrading to
      // "not sent" through a dead ref).
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(rustApi.pendingSend, isNotNull);
      expect(rustApi.lastAccountUserId, '@alice:example.org');

      rustApi.pendingSend!.complete('evt-composer-1');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(MarkdownComposerPage), findsNothing);
      expect(container.read(messageDraftProvider(key)), '');

      // Flush the typing timers started while composing.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('closing the composer mid-fallback-send leaves no resendable '
        'draft', (tester) async {
      const roomId = '!composer-mid-fallback-close:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'once only');
      await tester.pump();

      // Layout switch: the input is disposed; the composer falls back to
      // provider-only state.
      showInput.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingSend, isNotNull);
      // The fallback consumed the provider state up front, so nothing is
      // left over to resend while the first request is still in flight.
      expect(container.read(messageDraftProvider(key)), '');

      // Closing mid-flight reports the text as consumed and pops
      // immediately; the in-flight request keeps running.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MarkdownComposerPage), findsNothing);

      // A fresh input mounts while the first send is still in flight: it
      // must not recover the consumed text as a resendable draft.
      showInput.value = true;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(inputField()).controller!.text, '');
      expect(container.read(messageDraftProvider(key)), '');

      rustApi.pendingSend!.complete('evt-x');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Flush the typing timers started while composing.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a failed fallback send after an in-flight close restores '
        'the draft for retry', (tester) async {
      const roomId = '!composer-mid-fallback-fail:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'once only');
      await tester.pump();

      showInput.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingSend, isNotNull);
      expect(container.read(messageDraftProvider(key)), '');

      // Closing mid-flight pops immediately; the failure then lands on the
      // fallback, which restores the consumed draft so the text is not
      // lost for good.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(MarkdownComposerPage), findsNothing);

      rustApi.pendingSend!.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(container.read(messageDraftProvider(key)), 'once only');

      // A remounted input recovers the restored draft for the retry.
      showInput.value = true;
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'once only',
      );

      // Flush the typing timers started while composing.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a failed fallback send preserves a newer remounted draft and '
        'still reports the failure', (tester) async {
      const roomId = '!composer-mid-fallback-new-draft:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'first draft');
      await tester.pump();

      showInput.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingSend, isNotNull);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      showInput.value = true;
      await tester.pumpAndSettle();
      await tester.enterText(inputField(), 'newer draft');
      await tester.pump();
      expect(container.read(messageDraftProvider(key)), 'newer draft');

      rustApi.pendingSend!.completeError(StateError('offline'));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(container.read(messageDraftProvider(key)), 'newer draft');
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'newer draft',
      );
      expect(find.textContaining('发送失败'), findsOneWidget);
      final failed = container.read(localOutgoingMessagesProvider(key));
      expect(failed, hasLength(1));
      expect(failed.single.message.id, startsWith(localOutgoingFailedPrefix));
      expect(failed.single.message.content, 'first draft');

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('fallback send refreshes the message list through the '
        'container', (tester) async {
      const roomId = '!composer-fallback-refresh:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      // The post-send refresh only fetches when the Rust session is ready;
      // open the gate so messagesProvider actually calls getMessages.
      container.read(sessionReadyProvider.notifier).value = true;

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'refresh me');
      await tester.pump();

      showInput.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingSend, isNotNull);

      rustApi.pendingSend!.complete('evt-refresh');
      await tester.pumpAndSettle();
      // The refresh is unawaited: give the invalidate → fetch chain time to
      // run to the end before asserting the fetch happened.
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(rustApi.getMessagesCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('live composer send refreshes after its input is disposed', (
      tester,
    ) async {
      const roomId = '!composer-live-disposed-refresh:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(sessionReadyProvider.notifier).value = true;

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'refresh after disposal');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(rustApi.pendingSend, isNotNull);
      expect(container.read(localOutgoingMessagesProvider(key)), hasLength(1));

      // The route survives, but the input state that initiated the send does
      // not. The accepted event still needs an explicit fetch after its local
      // optimistic entry is removed.
      showInput.value = false;
      await tester.pump();
      rustApi.pendingSend!.complete(r'$sent-after-disposal');
      await tester.pumpAndSettle();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(MarkdownComposerPage), findsNothing);
      expect(container.read(localOutgoingMessagesProvider(key)), isEmpty);
      expect(rustApi.getMessagesCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('fallback send stays bound to its initiating account and '
        'does not refresh the next account', (tester) async {
      const roomId = '!composer-fallback-account:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(sessionReadyProvider.notifier).value = true;

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'send as alice');
      await tester.pump();

      showInput.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingSend, isNotNull);
      expect(rustApi.lastAccountUserId, '@alice:example.org');

      rustApi.blockedIsRoomEncrypted = Completer<bool>();
      rustApi.pendingSend!.complete(r'$sent-as-alice');
      await tester.pump();
      container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      rustApi.blockedIsRoomEncrypted!.complete(false);
      rustApi.blockedIsRoomEncrypted = null;
      await tester.pumpAndSettle();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(rustApi.getMessagesCalls, 0);
    });

    testWidgets('a failed fallback send does not show feedback in the next '
        'account', (tester) async {
      const roomId = '!composer-fallback-account-error:example.org';
      const aliceKey = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'alice draft');
      await tester.pump();

      showInput.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      container.read(activeUserIdProvider.notifier).value = '@bob:example.org';

      rustApi.pendingSend!.completeError(StateError('offline'));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('发送失败'), findsNothing);
      expect(container.read(messageDraftProvider(aliceKey)), 'alice draft');

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
    });

    testWidgets('inline edits while editing sync the editing draft '
        'provider', (tester) async {
      const roomId = '!composer-edit-sync:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await pumpSwitchableHost(tester, container, roomId);
      container.read(editingMessageProvider(key).notifier).value = chatMessage(
        id: r'$edit-2',
        senderId: '@alice:example.org',
        content: 'orig',
        isMe: true,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(inputField()).controller!.text, 'orig');

      // Typing inline while editing mirrors the text into the surviving
      // editing draft, matched by message id, so a layout switch never
      // recovers an older full-screen edit over a newer inline one.
      await tester.enterText(inputField(), 'inline edit v3');
      await tester.pump();
      final draft = container.read(editingDraftProvider(key));
      expect(draft?.text, 'inline edit v3');
      expect(draft?.editingId, r'$edit-2');

      // Flush the typing timers started by the prefill and the edit.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a successful edit send with a disposed host clears the '
        'editing state', (tester) async {
      const roomId = '!composer-edit-send-disposed:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(editingMessageProvider(key).notifier).value = chatMessage(
        id: r'$edit-1',
        senderId: '@alice:example.org',
        content: 'orig text',
        isMe: true,
      );

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'orig text',
      );

      await openInputComposer(tester);
      await tester.enterText(composerField(), 'edited via composer');
      await tester.pump();

      // Layout switch disposes the input mid-edit; the edit send then runs
      // through the composer's provider-only fallback.
      showInput.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(rustApi.pendingEdit, isNotNull);

      rustApi.pendingEdit!.complete('editEvt1');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The server accepted the edit, so a later-mounted input must not
      // resurrect the stale editing bar or its in-progress draft.
      expect(container.read(editingMessageProvider(key)), isNull);
      expect(container.read(editingDraftProvider(key)), isNull);

      // Flush the typing timers started while composing.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets(
      'a detached edit stays recoverable while its send is in flight',
      (tester) async {
        const roomId = '!composer-edit-in-flight:example.org';
        const key = (roomId: roomId, userId: '@alice:example.org');
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(activeUserIdProvider.notifier).value =
            '@alice:example.org';
        container
            .read(editingMessageProvider(key).notifier)
            .value = chatMessage(
          id: r'$edit-in-flight',
          senderId: '@alice:example.org',
          content: 'original',
          isMe: true,
        );

        final showInput = await pumpSwitchableHost(tester, container, roomId);
        await tester.pumpAndSettle();
        await openInputComposer(tester);
        await tester.enterText(composerField(), 'unsaved edit');
        await tester.pump();

        // Force the composer onto the provider-only send path, then close it
        // while the request is pending and mount a fresh input behind it.
        showInput.value = false;
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.send_rounded));
        await tester.pump();
        expect(rustApi.pendingEdit, isNotNull);
        await tester.tap(find.byIcon(Icons.close_rounded));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        showInput.value = true;
        // The remounted input intentionally shows an in-flight spinner, so
        // pump only enough frames for its asynchronous edit prefill.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // The remounted input must retain the edit while the send is pending;
        // otherwise starting another action here can overwrite the only copy.
        expect(
          container.read(editingMessageProvider(key))?.id,
          r'$edit-in-flight',
        );
        expect(container.read(editingDraftProvider(key))?.text, 'unsaved edit');

        rustApi.pendingEdit!.completeError(StateError('offline'));
        await tester.pumpAndSettle();
        expect(
          container.read(editingMessageProvider(key))?.id,
          r'$edit-in-flight',
        );
        expect(container.read(editingDraftProvider(key))?.text, 'unsaved edit');

        await tester.pump(const Duration(seconds: 4));
      },
    );

    testWidgets('an in-flight edit cannot be replaced by edit or reply', (
      tester,
    ) async {
      const roomId = '!edit-transition-guard:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      final currentEdit = chatMessage(
        id: r'$edit-current',
        senderId: '@alice:example.org',
        content: 'current edit',
        isMe: true,
      );
      final otherMessage = chatMessage(
        id: r'$edit-other',
        senderId: '@alice:example.org',
        content: 'other message',
        isMe: true,
      );
      container.read(editingMessageProvider(key).notifier).value = currentEdit;
      container.read(editingSendInFlightProvider(key).notifier).value =
          currentEdit.id;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: MessageGroupWidget(
                group: MessageGroup(
                  senderId: otherMessage.senderId,
                  senderName: otherMessage.senderName,
                  isMe: true,
                  messages: [otherMessage],
                ),
                roomId: roomId,
                messageIndex: {otherMessage.id: otherMessage},
                showAvatar: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bubble = find.byKey(const ValueKey('text-bubble:\$edit-other'));
      await tester.longPress(bubble);
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pump();
      expect(container.read(editingMessageProvider(key))?.id, r'$edit-current');
      expect(find.text('编辑正在发送，请稍候'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.longPress(bubble);
      await tester.pumpAndSettle();
      await tester.tap(find.text('回复'));
      await tester.pump();
      expect(container.read(editingMessageProvider(key))?.id, r'$edit-current');
      expect(container.read(replyingToProvider(key)), isNull);
    });

    testWidgets('switching from edit to reply restores the plain draft', (
      tester,
    ) async {
      const roomId = '!edit-to-reply:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(messageDraftProvider(key).notifier).value = 'plain draft';
      final editing = chatMessage(
        id: r'$editing',
        senderId: '@alice:example.org',
        content: 'edit this message',
        isMe: true,
      );
      final replyTarget = chatMessage(
        id: r'$reply-target',
        senderId: '@bob:example.org',
        content: 'reply to me',
        isMe: false,
      );
      container.read(editingMessageProvider(key).notifier).value = editing;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: MessageGroupWidget(
                      group: MessageGroup(
                        senderId: replyTarget.senderId,
                        senderName: replyTarget.senderName,
                        isMe: false,
                        messages: [replyTarget],
                      ),
                      roomId: roomId,
                      messageIndex: {replyTarget.id: replyTarget},
                      showAvatar: false,
                    ),
                  ),
                  MessageInput(
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
                    resolveSendPresentation: () =>
                        MessageSendPresentation.quiet,
                    onMessageQueued: (_, _) {},
                    onMessageSent: (_, _) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        editing.content,
      );

      await tester.longPress(
        find.byKey(const ValueKey('text-bubble:\$reply-target')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('回复'));
      await tester.pumpAndSettle();

      expect(container.read(editingMessageProvider(key)), isNull);
      expect(container.read(replyingToProvider(key))?.id, replyTarget.id);
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'plain draft',
      );
    });

    testWidgets('a successful edit keeps the previous plain draft', (
      tester,
    ) async {
      const roomId = '!composer-edit-keeps-draft:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      await tester.enterText(inputField(), 'keep this draft');
      await tester.pump();
      expect(container.read(messageDraftProvider(key)), 'keep this draft');

      container.read(editingMessageProvider(key).notifier).value = chatMessage(
        id: r'$edit-keep',
        senderId: '@alice:example.org',
        content: 'original',
        isMe: true,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'original',
      );

      await openInputComposer(tester);
      await tester.enterText(composerField(), 'edited better');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingEdit, isNotNull);
      expect(rustApi.lastAccountUserId, '@alice:example.org');

      rustApi.pendingEdit!.complete('editEvt2');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(container.read(editingMessageProvider(key)), isNull);
      // The pre-edit plain draft survives the successful edit: clearing
      // the controller after sendDraftText already exited editing mode
      // would have wiped it, so the input restores the draft instead.
      expect(container.read(messageDraftProvider(key)), 'keep this draft');
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'keep this draft',
      );

      // Flush the typing timers started while composing.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('text typed during an edit send remains as a follow-up edit', (
      tester,
    ) async {
      const roomId = '!edit-keeps-newer-text:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(editingMessageProvider(key).notifier).value = chatMessage(
        id: r'$edit-newer',
        senderId: '@alice:example.org',
        content: 'original',
        isMe: true,
      );

      await tester.pumpWidget(messageInput(container, roomId));
      await tester.pumpAndSettle();
      await tester.enterText(inputField(), 'first edit');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingEdit, isNotNull);

      await tester.enterText(inputField(), 'follow-up edit');
      await tester.pump();
      rustApi.pendingEdit!.complete(r'$edit-sent');
      await tester.pump();
      await tester.pump();

      expect(container.read(editingMessageProvider(key))?.id, r'$edit-newer');
      expect(container.read(editingDraftProvider(key))?.text, 'follow-up edit');
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'follow-up edit',
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('a follow-up edit diffs mentions against the accepted edit', (
      tester,
    ) async {
      const roomId = '!edit-mention-baseline:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      const bob = '@bob:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(editingMessageProvider(key).notifier).value = chatMessage(
        id: r'$edit-mentions',
        senderId: '@alice:example.org',
        content: 'original',
        isMe: true,
      );

      await tester.pumpWidget(messageInput(container, roomId));
      await tester.pumpAndSettle();
      await tester.enterText(inputField(), '$bob first edit');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.lastPreviousMentionedUserIds, isEmpty);

      await tester.enterText(inputField(), '$bob follow-up edit');
      rustApi.pendingEdit!.complete(r'$first-edit');
      await tester.pump();
      await tester.pump();

      rustApi.pendingEdit = Completer<String>();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(rustApi.lastPreviousMentionedUserIds, [bob]);
      expect(rustApi.lastPreviousMentionsRoom, isFalse);

      rustApi.pendingEdit!.complete(r'$second-edit');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a newer composer edit wins over the stored original while '
        'the edit prefill read is in flight', (tester) async {
      const roomId = '!composer-prefill-race:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await pumpSwitchableHost(tester, container, roomId);

      // Hold _prefillEditingSource open at its async store read so the
      // race window is deterministic: the edit draft is written between
      // the prefill's first read and its post-await re-check.
      rustApi.blockedIsRoomEncrypted = Completer<bool>();
      container.read(editingMessageProvider(key).notifier).value = chatMessage(
        id: r'$edit-3',
        senderId: '@alice:example.org',
        content: 'original',
        isMe: true,
      );
      await tester.pump(); // prefill starts and suspends on the block
      expect(rustApi.blockedIsRoomEncrypted, isNotNull);

      // The full-screen composer syncs a newer edit while the prefill's
      // store read is still in flight.
      container.read(editingDraftProvider(key).notifier).value = (
        editingId: r'$edit-3',
        text: 'newer composer edit',
      );

      // Unblock the read: the prefill's post-await re-check must honor
      // the newer draft over the stored original.
      rustApi.blockedIsRoomEncrypted!.complete(false);
      rustApi.blockedIsRoomEncrypted = null;
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'newer composer edit',
      );
      expect(
        container.read(editingDraftProvider(key))?.text,
        'newer composer edit',
      );

      // Flush the typing timers started by the prefill.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('edit actions stay disabled until source prefill completes', (
      tester,
    ) async {
      const roomId = '!edit-prefill-disabled:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      await tester.enterText(inputField(), 'unrelated draft');
      await tester.pump();

      rustApi.blockedIsRoomEncrypted = Completer<bool>();
      container.read(editingMessageProvider(key).notifier).value = chatMessage(
        id: r'$edit-loading',
        senderId: '@alice:example.org',
        content: 'original source',
        isMe: true,
      );
      await tester.pump();

      expect(tester.widget<TextField>(inputField()).readOnly, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('send_only')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<NeuIconButton>(
              find.ancestor(
                of: find.byIcon(Icons.add_rounded),
                matching: find.byType(NeuIconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<GestureDetector>(
              find.ancestor(
                of: find.byIcon(Icons.add_rounded),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is GestureDetector &&
                      widget.child is NeuIconButton,
                ),
              ),
            )
            .onLongPress,
        isNull,
      );

      rustApi.blockedIsRoomEncrypted!.complete(false);
      rustApi.blockedIsRoomEncrypted = null;
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(inputField()).readOnly, isFalse);
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'original source',
      );
      expect(
        tester
            .widget<NeuIconButton>(
              find.widgetWithIcon(NeuIconButton, Icons.send_rounded),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<GestureDetector>(
              find.ancestor(
                of: find.byIcon(Icons.add_rounded),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is GestureDetector &&
                      widget.child is NeuIconButton,
                ),
              ),
            )
            .onLongPress,
        isNotNull,
      );
    });

    testWidgets('editing a message in the composer survives a layout '
        'switch', (tester) async {
      const roomId = '!composer-edit-disposed:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(editingMessageProvider(key).notifier).value = chatMessage(
        id: r'$edit-me',
        senderId: '@alice:example.org',
        content: 'original text',
        isMe: true,
      );

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'original text',
      );

      await openInputComposer(tester);
      await tester.enterText(composerField(), 'edited v2');
      await tester.pump();

      // Layout switch disposes the input mid-edit; closing the composer
      // must not drop the modifications.
      showInput.value = false;
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Remounting prefills the edited text, not the original message.
      showInput.value = true;
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'edited v2',
      );

      // Flush the typing timers started by the prefill.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a composer send failing after host disposal restores the '
        'draft and the reply relation', (tester) async {
      const roomId = '!composer-send-disposed:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(replyingToProvider(key).notifier).value = chatMessage(
        id: r'$reply-target',
        senderId: '@bob:example.org',
        content: 'reply target',
        isMe: false,
      );

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'keep me');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingReply, isNotNull);
      expect(rustApi.lastAccountUserId, '@alice:example.org');

      // Layout switch while the send is in flight, then the failure
      // lands on the disposed state. (No pumpAndSettle here: the
      // composer's sending spinner animates until the send settles.)
      showInput.value = false;
      await tester.pump();
      rustApi.pendingReply!.completeError(StateError('offline'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(container.read(localOutgoingMessagesProvider(key)), isEmpty);
      expect(container.read(messageDraftProvider(key)), 'keep me');
      expect(container.read(replyingToProvider(key))?.id, r'$reply-target');
    });

    testWidgets('a failed send preserves a newer reply selection', (
      tester,
    ) async {
      const roomId = '!reply-failure-keeps-newer:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      final firstReply = chatMessage(
        id: r'$reply-first',
        senderId: '@bob:example.org',
        content: 'first',
        isMe: false,
      );
      final nextReply = chatMessage(
        id: r'$reply-next',
        senderId: '@carol:example.org',
        content: 'next',
        isMe: false,
      );
      container.read(replyingToProvider(key).notifier).value = firstReply;

      await tester.pumpWidget(messageInput(container, roomId));
      await tester.enterText(inputField(), '**send this first**');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingReply, isNotNull);

      // The first relation was consumed at queue time. This selection belongs
      // to the next draft and must survive settlement of the older request.
      container.read(replyingToProvider(key).notifier).value = nextReply;
      await tester.pump();
      rustApi.pendingReply!.completeError(StateError('offline'));
      await tester.pumpAndSettle();

      expect(container.read(replyingToProvider(key))?.id, r'$reply-next');
      expect(
        container
            .read(localOutgoingMessagesProvider(key))
            .single
            .markdownSource,
        '**send this first**',
      );
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a remounted input follows the composer draft instead of '
        'going stale', (tester) async {
      const roomId = '!composer-remount:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final showInput = await pumpSwitchableHost(tester, container, roomId);
      await openInputComposer(tester);
      await tester.enterText(composerField(), 'v1');
      await tester.pump();

      // desktop → mobile → desktop while the composer stays open.
      showInput.value = false;
      await tester.pumpAndSettle();
      showInput.value = true;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(inputField()).controller!.text, 'v1');

      // Further composer edits reach the mounted input too, so it can
      // never send (or overwrite the provider with) a stale text.
      await tester.enterText(composerField(), 'v2');
      await tester.pump();
      expect(tester.widget<TextField>(inputField()).controller!.text, 'v2');

      // Closing returns to the dead original host; the mounted input
      // still ends up with the final text.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(inputField()).controller!.text, 'v2');
      expect(container.read(messageDraftProvider(key)), 'v2');

      // Flush the typing timers started on the remounted input.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('typing in the composer keeps the typing notice alive', (
      tester,
    ) async {
      const roomId = '!composer-typing:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      await openInputComposer(tester);

      await tester.enterText(composerField(), 'typing away');
      await tester.pump();
      expect(rustApi.typingNotices, contains(true));

      // Let the idle-stop typing timers run out so none are left pending.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a live input stays bound to its initiating account', (
      tester,
    ) async {
      const roomId = '!typing-account:example.org';
      const alice = '@alice:example.org';
      const aliceKey = (roomId: roomId, userId: alice);
      const bobKey = (roomId: roomId, userId: '@bob:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = alice;

      await tester.pumpWidget(messageInput(container, roomId));
      container.read(activeUserIdProvider.notifier).value = bobKey.userId;
      await tester.enterText(inputField(), 'still Alice draft');
      await tester.pump();

      expect(
        container.read(messageDraftProvider(aliceKey)),
        'still Alice draft',
      );
      expect(container.read(messageDraftProvider(bobKey)), '');
      expect(rustApi.typingNoticeAccountUserIds, [alice]);

      // Flush the input's idle-stop timer.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('retry after a failed composer send resends cleanly and '
        'keeps the reply relation', (tester) async {
      const roomId = '!composer-retry:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      const original = rust.ChatMessage(
        id: r'$original',
        senderId: '@bob:example.org',
        senderName: 'Bob',
        content: 'original message',
        formattedBody: null,
        mentionedUserIds: [],
        mentionsRoom: false,
        timestamp: '100',
        isMe: false,
        msgType: rust.MessageType.text,
        isEdited: false,
        editHistory: [],
        reactions: [],
        readers: [],
        totalMembers: 2,
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(replyingToProvider(key).notifier).value = original;

      await tester.pumpWidget(messageInput(container, roomId));
      await openInputComposer(tester);

      await tester.enterText(composerField(), 'retry me');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingReply, isNotNull);

      rustApi.pendingReply!.completeError(StateError('offline'));
      await tester.pumpAndSettle();

      // The composer keeps the draft; the optimistic entry is removed
      // rather than left as a failed bubble, and the reply relation
      // cleared at queue time is restored for the retry.
      expect(find.byType(MarkdownComposerPage), findsOneWidget);
      expect(container.read(localOutgoingMessagesProvider(key)), isEmpty);
      expect(container.read(replyingToProvider(key))?.id, r'$original');

      rustApi.pendingReply = null;
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingReply, isNotNull);
      expect(rustApi.lastReplyToEventId, r'$original');

      rustApi.pendingReply!.complete(r'$sent');
      await tester.pumpAndSettle();

      // Exactly one local message — the retry's — not a failed duplicate
      // plus a resend.
      expect(container.read(localOutgoingMessagesProvider(key)), hasLength(1));
      expect(find.byType(MarkdownComposerPage), findsNothing);
      expect(container.read(replyingToProvider(key)), isNull);

      // Let the reconciliation retry loop exhaust itself.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('sending from the composer compiles markdown and clears the '
        'input', (tester) async {
      const roomId = '!composer-send:example.org';
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      await openInputComposer(tester);

      await tester.enterText(composerField(), '**bold** move');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();

      expect(rustApi.pendingSend, isNotNull);
      expect(rustApi.lastMessage?.body, 'bold move');
      expect(
        rustApi.lastMessage?.formattedBody,
        contains('<strong>bold</strong>'),
      );

      rustApi.pendingSend!.complete(r'$sent');
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownComposerPage), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      // The local-message reconciliation retries with delays until the
      // server echo arrives; no echo comes in this harness, so let the
      // retry loop exhaust itself instead of leaving timers pending.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      // The markdown source is persisted for later editing, like a send from
      // the inline input.
      expect(
        await const MarkdownSourceStore().load(
          userId: '@alice:example.org',
          roomId: roomId,
          eventId: r'$sent',
          body: 'bold move',
          formattedBody: '<p><strong>bold</strong> move</p>',
          allowPersistence: true,
        ),
        '**bold** move',
      );
    });

    testWidgets('a successful send does not clear the next inline draft', (
      tester,
    ) async {
      const roomId = '!send-keeps-next-draft:example.org';
      const key = (roomId: roomId, userId: '@alice:example.org');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(messageInput(container, roomId));
      await tester.enterText(inputField(), 'first message');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingSend, isNotNull);

      await tester.enterText(inputField(), 'next draft');
      await tester.pump();
      expect(container.read(messageDraftProvider(key)), 'next draft');

      rustApi.pendingSend!.complete(r'$sent-first');
      await tester.pump();
      await tester.pump();

      expect(container.read(messageDraftProvider(key)), 'next draft');
      expect(
        tester.widget<TextField>(inputField()).controller!.text,
        'next draft',
      );

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });
  });
}
