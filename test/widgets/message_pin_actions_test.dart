import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_pin_actions.dart';
import 'package:matter/pages/chat/pinned_message_indicator.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

import '../helpers/neu_test_theme.dart';

class _Api implements RustLibApi {
  final states = <bool>[];
  bool failNext = false;

  @override
  Future<bool> crateApiMatrixSetPinnedMessage({
    required String accountUserId,
    required String roomId,
    required String eventId,
    required bool pinned,
  }) async {
    states.add(pinned);
    if (failNext) {
      failNext = false;
      throw StateError('network unavailable');
    }
    return pinned;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call: ${invocation.memberName}');
}

void main() {
  late _Api api;
  setUpAll(() {
    api = _Api();
    RustLib.initMock(api: api);
  });
  setUp(() {
    api.states.clear();
    api.failNext = false;
  });
  tearDownAll(RustLib.dispose);

  Future<ProviderContainer> pumpActions(
    WidgetTester tester, {
    bool initiallyPinned = true,
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@me:example.org';
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () async {
                    if (!await confirmMessagePinChange(
                          context,
                          pinned: initiallyPinned,
                        ) ||
                        !context.mounted) {
                      return;
                    }
                    await rust.setPinnedMessage(
                      accountUserId: '@me:example.org',
                      roomId: '!room:example.org',
                      eventId: r'$message',
                      pinned: initiallyPinned,
                    );
                    if (!context.mounted) return;
                    showMessagePinFeedback(
                      context: context,
                      container: container,
                      accountUserId: '@me:example.org',
                      roomId: '!room:example.org',
                      eventId: r'$message',
                      pinned: initiallyPinned,
                    );
                  },
                  child: const Text('操作'),
                );
              },
            ),
          ),
        ),
      ),
    );
    return container;
  }

  Future<void> confirm(WidgetTester tester, {bool pinned = true}) async {
    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(pinned ? '置顶' : '取消置顶').last);
    await tester.pumpAndSettle();
  }

  testWidgets('cancel leaves the server untouched', (tester) async {
    await pumpActions(tester);
    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    expect(find.text('置顶这条消息？'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(api.states, isEmpty);
    expect(find.text('撤销'), findsNothing);
  });

  for (final pinned in [true, false]) {
    testWidgets('confirm, undo and redo use explicit states ($pinned)', (
      tester,
    ) async {
      await pumpActions(tester, initiallyPinned: pinned);
      await confirm(tester, pinned: pinned);
      expect(api.states, [pinned]);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(api.states, [pinned, !pinned]);
      await tester.tap(find.text('重做'));
      await tester.pumpAndSettle();
      expect(api.states, [pinned, !pinned, pinned]);
      expect(find.text('撤销'), findsOneWidget);
    });
  }

  testWidgets('undo and redo prompts auto-dismiss after three seconds', (
    tester,
  ) async {
    await pumpActions(tester);
    await confirm(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('撤销'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(api.states, [true]);

    await confirm(tester);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('重做'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(api.states, [true, true, false]);
  });

  testWidgets('a failed undo retries the same explicit target', (tester) async {
    await pumpActions(tester);
    await confirm(tester);
    api.failNext = true;
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(api.states, [true, false]);
    expect(find.text('重做'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(api.states, [true, false, false]);
    expect(find.text('重做'), findsOneWidget);
  });

  testWidgets('old-account undo never writes to the new account', (
    tester,
  ) async {
    final container = await pumpActions(tester);
    await confirm(tester);
    container.read(activeUserIdProvider.notifier).value = '@other:example.org';
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(api.states, [true]);
  });

  testWidgets('many pins keep a bounded moving indicator window', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: neuTestTheme(),
        home: const Scaffold(
          body: PinnedMessageIndicator(count: 27, index: 26),
        ),
      ),
    );
    expect(find.byType(AnimatedContainer), findsNWidgets(5));
    expect(find.byKey(const ValueKey('pin-segment:26')), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-segment:0')), findsNothing);
    final selected = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('pin-segment:26')),
    );
    expect((selected.decoration as BoxDecoration).color!.a, 1);
  });
}
