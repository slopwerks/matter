import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';

/// Records every typing-notice send and holds each one in flight until the
/// test resolves it, so the race between a stale `true` and the stop
/// `false` can be reproduced deterministically.
class _TypingFakeRustApi implements RustLibApi {
  final calls = <bool>[];
  final _pending = <Completer<void>>[];

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) {
    calls.add(typing);
    final completer = Completer<void>();
    _pending.add(completer);
    return completer.future;
  }

  /// Completes the i-th in-flight call (in send order), running its
  /// `whenComplete`.
  void complete(int i) {
    _pending[i].complete();
  }

  void completeAll() {
    for (final completer in List.of(_pending)) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }

  void reset() {
    calls.clear();
    _pending.clear();
  }
}

void main() {
  late _TypingFakeRustApi rustApi;

  setUpAll(() {
    rustApi = _TypingFakeRustApi();
    RustLib.initMock(api: rustApi);
  });
  tearDownAll(RustLib.dispose);
  setUp(() => rustApi.reset());

  testWidgets(
    'a stale in-flight typing notice is corrected with a stop after the '
    'user stopped typing',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(_messageInput(container, '!race:example.org'));

      // Start typing: the start notice (true) goes out and stays in flight.
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      expect(rustApi.calls, [true]);

      // Stop typing: the stop notice (false) always goes out, even while
      // the stale `true` above is still on the wire.
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(rustApi.calls, [true, false]);

      // The stale `true` resolves AFTER the stop that superseded it: on a
      // flaky network it may have reached the remote last, reviving
      // "正在输入" — the completion must re-send the stop so the remote ends
      // stopped (there is no keep-alive left to correct it).
      rustApi.complete(0);
      await tester.pump();
      expect(rustApi.calls, [true, false, false]);

      // Draining the remaining calls produces no further corrections.
      rustApi.completeAll();
      await tester.pump();
      expect(rustApi.calls, [true, false, false]);

      await tester.pumpWidget(_home(container));
      await tester.pump();
      rustApi.completeAll();
      await tester.pump();
    },
  );

  testWidgets(
    'no stop correction fires when the user started typing again before '
    'the stale notice completes',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(_messageInput(container, '!retry:example.org'));

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'there');
      await tester.pump();
      expect(rustApi.calls, [true, false, true]);

      // The stale first `true` completes after the new session start: the
      // user is typing again, so a corrective stop would only hide the
      // indicator the newer `true` is landing — skip it.
      rustApi.complete(0);
      await tester.pump();
      expect(rustApi.calls, [true, false, true]);

      rustApi.completeAll();
      await tester.pump();
      expect(rustApi.calls, [true, false, true]);

      // Unmounting while typing sends the final stop notice.
      await tester.pumpWidget(_home(container));
      await tester.pump();
      rustApi.completeAll();
      await tester.pump();
    },
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
