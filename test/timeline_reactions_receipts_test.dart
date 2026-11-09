import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/timeline/timeline_reactions_bar.dart';
import 'package:matter/pages/chat/timeline/timeline_read_receipts.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/widgets/neu_decoration.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _room = '!reactions:example.org';
const _alice = '@alice:example.org';

class _Api implements RustLibApi {
  Completer<rust.ChatMessage>? response;
  final calls = <String>[];

  @override
  Future<rust.ChatMessage> crateApiMatrixToggleReaction({
    required String accountUserId,
    required String roomId,
    required String eventId,
    required String key,
  }) {
    calls.add('$accountUserId/$roomId/$eventId/$key');
    return (response = Completer<rust.ChatMessage>()).future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  late _Api api;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _Api();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  for (final material in [false, true]) {
    for (final brightness in Brightness.values) {
      final label = '${material ? 'Material' : 'Neu'} $brightness';
      final theme = material
          ? buildMaterialTheme(brightness)
          : buildNeuTheme(
              brightness == Brightness.dark ? NeuColors.dark : NeuColors.light,
              brightness,
            );
      testWidgets(
        '$label reaction keys, counts, alignment and active account stay live',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(activeUserIdProvider.notifier).value = _alice;
          final toggled = <String>[];
          final message = _message(
            reactions: [
              rust.Reaction(key: '👍', senders: [_alice, '@bob:example.org']),
              rust.Reaction(key: '❤️', senders: ['@bob:example.org']),
            ],
          );
          await tester.pumpWidget(
            _app(
              container,
              theme,
              TimelineReactionsBar(
                message: message,
                isMe: true,
                onToggle: toggled.add,
              ),
            ),
          );
          final chip = find.byKey(const ValueKey(r'$event:👍'));
          expect(
            find.descendant(of: chip, matching: find.text('2')),
            findsOneWidget,
          );
          expect(
            tester.widget<Wrap>(find.byType(Wrap)).alignment,
            WrapAlignment.end,
          );
          NeuDecoration decoration() =>
              tester
                      .widget<Container>(
                        find.descendant(
                          of: chip,
                          matching: find.byType(Container),
                        ),
                      )
                      .decoration!
                  as NeuDecoration;
          expect(decoration().borderColor, isNotNull);
          await tester.tap(chip);
          expect(toggled, ['👍']);
          container.read(activeUserIdProvider.notifier).value =
              '@carol:example.org';
          await tester.pump();
          expect(decoration().borderColor, isNull);
        },
      );

      testWidgets(
        '$label receipt keeps its slot and opens ordered reader names',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          Widget indicator(rust.ChatMessage message) => Align(
            alignment: Alignment.topLeft,
            child: TimelineReadIndicator(
              message: message,
              roomId: _room,
              color: Colors.red,
            ),
          );
          await tester.pumpWidget(
            _app(container, theme, indicator(_message(members: 1))),
          );
          expect(
            find.byKey(const ValueKey(r'message-read-receipt:$event')),
            findsNothing,
          );
          final slot = find.descendant(
            of: find.byType(TimelineReadIndicator),
            matching: find.byType(SizedBox),
          );
          expect(tester.getSize(slot), const Size.square(15));
          await tester.pumpWidget(
            _app(container, theme, indicator(_message())),
          );
          await tester.pumpAndSettle();
          final key = find.byKey(
            const ValueKey(r'message-read-receipt:$event'),
          );
          expect(find.byIcon(Icons.done_rounded), findsOneWidget);
          expect(tester.widget<GestureDetector>(key).onTap, isNull);
          final originalRect = tester.getRect(key);
          await tester.pumpWidget(
            _app(
              container,
              theme,
              indicator(
                _message(
                  readers: const [
                    rust.MessageReader(
                      userId: '@bob:example.org',
                      displayName: 'Bob',
                    ),
                    rust.MessageReader(userId: _alice, displayName: 'Alice'),
                  ],
                  members: 3,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(key), originalRect);
          expect(find.byTooltip('已读 2/2，点击查看'), findsOneWidget);
          await tester.tap(key);
          await tester.pumpAndSettle();
          expect(find.text('已读 2'), findsOneWidget);
          expect(
            tester.getTopLeft(find.text('Bob')).dy,
            lessThan(tester.getTopLeft(find.text('Alice')).dy),
          );
          await tester.tap(find.byIcon(Icons.close_rounded));
          await tester.pumpAndSettle();
          expect(find.text('已读 2'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'toggle merges returned snapshot while keeping older cached messages',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = _alice;
      final older = _message(id: 'older', timestamp: '0');
      container.read(messageCacheProvider(_room).notifier).value = [
        older,
        _message(),
      ];
      await tester.pumpWidget(_toggleHost(container));
      await tester.tap(find.text('toggle'));
      api.response!.complete(
        _message(
          reactions: [
            rust.Reaction(key: '👍', senders: [_alice]),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final cached = container.read(messageCacheProvider(_room));
      expect(cached.map((message) => message.id), ['older', r'$event']);
      expect(cached.last.reactions.single.senders, [_alice]);
      expect(api.calls.single, '$_alice/$_room/\$event/👍');
    },
  );

  for (final unmount in [false, true]) {
    testWidgets(
      'late toggle does not update another account or disposed host (unmount=$unmount)',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(activeUserIdProvider.notifier).value = _alice;
        final original = _message();
        container.read(messageCacheProvider(_room).notifier).value = [original];
        await tester.pumpWidget(_toggleHost(container));
        await tester.tap(find.text('toggle'));
        if (unmount) {
          await tester.pumpWidget(const SizedBox());
        } else {
          container.read(activeUserIdProvider.notifier).value =
              '@bob:example.org';
        }
        api.response!.complete(
          _message(
            reactions: [
              rust.Reaction(key: '👍', senders: [_alice]),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          container.read(messageCacheProvider(_room)).single,
          same(original),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed reaction preserves snapshot and reports the error', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = _alice;
    final original = _message();
    container.read(messageCacheProvider(_room).notifier).value = [original];
    await tester.pumpWidget(_toggleHost(container));
    await tester.tap(find.text('toggle'));
    api.response!.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(container.read(messageCacheProvider(_room)).single, same(original));
    expect(find.textContaining('回应失败:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _toggleHost(ProviderContainer container) => _app(
  container,
  buildMaterialTheme(Brightness.light),
  Consumer(
    builder: (context, ref, _) => TextButton(
      onPressed: () => toggleTimelineReaction(
        context,
        ref,
        roomId: _room,
        eventId: r'$event',
        emoji: '👍',
      ),
      child: const Text('toggle'),
    ),
  ),
);
Widget _app(ProviderContainer container, ThemeData theme, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        home: Scaffold(body: child),
      ),
    );
rust.ChatMessage _message({
  String id = r'$event',
  List<rust.Reaction> reactions = const [],
  List<rust.MessageReader> readers = const [],
  int members = 2,
  String timestamp = '1',
}) => rust.ChatMessage(
  id: id,
  senderId: _alice,
  senderName: 'Alice',
  content: id,
  timestamp: timestamp,
  isMe: true,
  msgType: rust.MessageType.text,
  mentionedUserIds: const [],
  mentionsRoom: false,
  isEdited: false,
  editHistory: const [],
  reactions: reactions,
  readers: readers,
  totalMembers: members,
);
