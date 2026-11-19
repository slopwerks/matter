import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _roomId = '!color:example.org';
const _userId = '@me:example.org';
const _roomKey = (roomId: _roomId, userId: _userId);
const _text = 'Message color transition';

class _RustApi implements RustLibApi {
  Completer<String>? pendingSend;
  rust.ChatMessage? echo;

  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    pendingSend = Completer<String>();
    echo = rust.ChatMessage(
      id: r'$echo',
      senderId: accountUserId,
      senderName: '我',
      content: message.body,
      formattedBody: message.formattedBody,
      mentionedUserIds: message.mentionedUserIds,
      mentionsRoom: message.mentionsRoom,
      timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
      isMe: true,
      msgType: rust.MessageType.text,
      isEdited: false,
      editHistory: const [],
      reactions: const [],
      readers: const [],
      totalMembers: 2,
    );
    return pendingSend!.future;
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {}

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async =>
      true;

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessages({
    required String roomId,
  }) async => [?echo];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

class _ChatHarness extends ConsumerWidget {
  const _ChatHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = [
      ...ref.watch(messageCacheProvider(_roomId)),
      ...ref
          .watch(localOutgoingMessagesProvider(_roomKey))
          .map((entry) => entry.message),
    ];
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.bottomRight,
              child: messages.isEmpty
                  ? const SizedBox()
                  : MessageGroupWidget(
                      group: MessageGroup(
                        senderId: _userId,
                        senderName: '我',
                        isMe: true,
                        messages: messages,
                      ),
                      roomId: _roomId,
                      messageIndex: {
                        for (final message in messages) message.id: message,
                      },
                      showAvatar: false,
                    ),
            ),
          ),
          MessageInput(
            roomId: _roomId,
            totalMembers: 2,
            panelMode: InputPanelMode.none,
            pickerHeight: 0,
            pickerFullHeight: 300,
            pickerBaseHeight: 300,
            pickerMaxHeight: 500,
            animatePickerHeight: false,
            onPanelModeChanged: (_) {},
            onPickerHeightChanged: (_) {},
            resolveSendPresentation: () => MessageSendPresentation.flight,
            onMessageQueued: (_, _) {},
            onMessageSent: (_, _) {},
          ),
        ],
      ),
    );
  }
}

Color _paintedTextColor(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: text, matching: find.byType(RichText)).first,
  );
  Color? colorForText(InlineSpan span, Color? inherited) {
    final color = span.style?.color ?? inherited;
    if (span is TextSpan) {
      if (span.text?.contains(_text) == true) return color;
      for (final child in span.children ?? const <InlineSpan>[]) {
        final found = colorForText(child, color);
        if (found != null) return found;
      }
    }
    return null;
  }

  return colorForText(paragraph.text, null)!;
}

void main() {
  late _RustApi api;
  setUpAll(() {
    api = _RustApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.pendingSend = null;
    api.echo = null;
  });

  for (final material in [true, false]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '${material ? 'Material' : 'Neu'} $brightness text flight matches the bubble on landing and server echo',
        (tester) async {
          final theme = material
              ? buildMaterialTheme(brightness)
              : buildNeuTheme(
                  brightness == Brightness.dark
                      ? NeuColors.dark
                      : NeuColors.light,
                  brightness,
                );
          final colors = theme.extension<NeuColors>()!;
          final container = ProviderContainer(
            overrides: [
              activeUserIdProvider.overrideWith(() => MutableState(_userId)),
              currentUserProvider.overrideWith(
                () => MutableState(
                  const CurrentUser(
                    id: _userId,
                    displayName: '我',
                    homeserver: 'https://example.org',
                  ),
                ),
              ),
              sessionReadyProvider.overrideWith(() => MutableState(true)),
              ignoredUserIdsProvider.overrideWith((ref) async => {}),
            ],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(theme: theme, home: const _ChatHarness()),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), _text);
          await tester.pump();
          await tester.tap(find.byIcon(Icons.send_rounded));
          await tester.pump();
          await tester.pump();
          expect(api.pendingSend, isNotNull);
          final flightText = find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == _text,
          );
          expect(flightText, findsOneWidget);
          expect(_paintedTextColor(tester, flightText), colors.text);
          await tester.pump(const Duration(milliseconds: 299));
          expect(flightText, findsOneWidget);
          final landingColor = _paintedTextColor(tester, flightText);
          expect(landingColor.r, closeTo(colors.onAccent.r, .01));
          expect(landingColor.g, closeTo(colors.onAccent.g, .01));
          expect(landingColor.b, closeTo(colors.onAccent.b, .01));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump();
          expect(flightText, findsNothing);
          final body = find.text(_text);
          expect(body, findsOneWidget);
          expect(_paintedTextColor(tester, body), colors.onAccent);
          api.pendingSend!.complete(r'$echo');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump();
          final echoBubble = find.byKey(const ValueKey(r'text-bubble:$echo'));
          expect(echoBubble, findsOneWidget);
          final echoText = find.descendant(
            of: echoBubble,
            matching: find.text(_text),
          );
          expect(echoText, findsOneWidget);
          expect(_paintedTextColor(tester, echoText), colors.onAccent);
          expect(
            container.read(messageCacheProvider(_roomId)).single.id,
            r'$echo',
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 3));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
