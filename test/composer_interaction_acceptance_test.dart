import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/pages/chat/emoji_data.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/markdown_composer_page.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _room = '!acceptance:example.org';
const _key = (roomId: _room, userId: '@alice:example.org');

class _Api implements RustLibApi {
  final sent = <rust.FormattedMessageInput>[];
  final typing = <bool>[];

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async =>
      false;

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {
    this.typing.add(typing);
  }

  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) async {
    expect(accountUserId, _key.userId);
    sent.add(message);
    return r'$accepted';
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessages({
    required String roomId,
  }) async =>
      sent.isEmpty ? const [] : [_message(r'$accepted', sent.last.body)];

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
      testWidgets(
        '${material ? 'Material' : 'Neu'} $brightness full touch composer journey',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final container = ProviderContainer(
            overrides: [
              stickerPacksProvider(_room).overrideWith((ref) async => []),
              messagesProvider(_room).overrideWith(
                (ref) => api.crateApiMatrixGetMessages(roomId: _room),
              ),
              chatRoomsProvider.overrideWith((ref) async => []),
            ],
          );
          addTearDown(container.dispose);
          container.read(activeUserIdProvider.notifier).value = _key.userId;
          final host = GlobalKey<_HostState>();
          final theme =
              (material
                      ? buildMaterialTheme(brightness)
                      : buildNeuTheme(
                          brightness == Brightness.dark
                              ? NeuColors.dark
                              : NeuColors.light,
                          brightness,
                        ))
                  .copyWith(platform: TargetPlatform.android);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: theme,
                home: _Host(key: host),
              ),
            ),
          );
          Finder inlineField() => find
              .descendant(
                of: find.byType(MessageInput),
                matching: find.byType(TextField),
              )
              .first;
          String text() =>
              tester.widget<TextField>(inlineField()).controller!.text;

          // Keyboard -> emoji -> sticker -> keyboard, with no draft loss.
          await tester.tap(inlineField());
          await tester.pumpAndSettle();
          expect(host.currentState!.mode, InputPanelMode.keyboard);
          await tester.enterText(inlineField(), 'hello ');
          await tester.pump();
          await tester.tap(find.byIcon(Icons.sentiment_satisfied_alt_rounded));
          await tester.pumpAndSettle();
          expect(host.currentState!.mode, InputPanelMode.emoji);
          expect(
            tester.widget<TextField>(inlineField()).focusNode!.hasFocus,
            isFalse,
          );
          final emoji = kEmojiCategories.first.emojis.first;
          await tester.tap(find.text(emoji).first);
          await tester.pump();
          final draft = 'hello $emoji';
          expect(text(), draft);
          await tester.tap(find.text('贴纸'));
          await tester.pumpAndSettle();
          expect(find.byType(StickerPackPanel), findsOneWidget);
          await tester.tap(find.byIcon(Icons.keyboard_rounded));
          await tester.pumpAndSettle();
          expect(host.currentState!.mode, InputPanelMode.keyboard);
          expect(
            tester.widget<TextField>(inlineField()).focusNode!.hasFocus,
            isTrue,
          );
          expect(text(), draft);
          await tester.enterText(inlineField(), '$draft again');
          await tester.pump();
          final ordinary = '$draft again';

          // Reply cancel does not change text; edit cancel restores that draft.
          container.read(replyingToProvider(_key).notifier).value = _message(
            r'$reply',
            'quoted text',
          );
          await tester.pumpAndSettle();
          expect(find.text('quoted text'), findsOneWidget);
          await tester.tap(find.byIcon(Icons.close_rounded));
          await tester.pump();
          expect(container.read(replyingToProvider(_key)), isNull);
          expect(text(), ordinary);
          container.read(editingMessageProvider(_key).notifier).value =
              _message(r'$edit', 'original edit');
          await tester.pumpAndSettle();
          expect(text(), 'original edit');
          await tester.enterText(inlineField(), 'changed edit');
          await tester.pump();
          await tester.tap(find.byIcon(Icons.close_rounded));
          await tester.pumpAndSettle();
          expect(container.read(editingMessageProvider(_key)), isNull);
          expect(container.read(editingDraftProvider(_key)), isNull);
          expect(text(), ordinary);
          expect(container.read(messageDraftProvider(_key)), ordinary);

          Future<void> openEditor() async {
            await tester.longPress(find.byIcon(Icons.add_rounded));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Markdown 编辑器'));
            await tester.pumpAndSettle();
            expect(find.byType(MarkdownComposerPage), findsOneWidget);
          }

          Finder editorField() => find.descendant(
            of: find.byType(MarkdownComposerPage),
            matching: find.byType(TextField),
          );
          await openEditor();
          await tester.enterText(editorField(), '**accepted** draft');
          await tester.pump();
          await tester.tap(find.text('预览'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('编辑'));
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(editorField()).controller!.text,
            '**accepted** draft',
          );
          await tester.tap(find.byTooltip('关闭'));
          await tester.pumpAndSettle();
          expect(text(), '**accepted** draft');
          expect(
            container.read(messageDraftProvider(_key)),
            '**accepted** draft',
          );

          await openEditor();
          await tester.tap(find.byTooltip('发送'));
          await tester.pumpAndSettle();
          // Let the normal post-send refresh observe the server echo.
          await tester.pump(const Duration(seconds: 1));
          await tester.pumpAndSettle();
          expect(find.byType(MarkdownComposerPage), findsNothing);
          expect(api.sent, hasLength(1));
          expect(api.sent.single.body, 'accepted draft');
          expect(
            api.sent.single.formattedBody,
            contains('<strong>accepted</strong>'),
          );
          expect(text(), isEmpty);
          expect(container.read(messageDraftProvider(_key)), isEmpty);
          expect(
            container
                .read(localOutgoingMessagesProvider(_key))
                .single
                .message
                .id,
            startsWith(localOutgoingSentPrefix),
          );
          expect(
            container.read(messageCacheProvider(_room)).single.id,
            r'$accepted',
          );
          expect(api.typing, containsAllInOrder([true, false]));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          // The input-only host has no timeline matcher. On unmount the
          // reconciliation loop exits after its already scheduled delay.
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
        },
      );
    }
  }
}

rust.ChatMessage _message(String id, String content) => rust.ChatMessage(
  id: id,
  senderId: _key.userId,
  senderName: 'Alice',
  content: content,
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

class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  InputPanelMode mode = InputPanelMode.none;
  @override
  Widget build(BuildContext context) {
    final open =
        mode == InputPanelMode.emoji || mode == InputPanelMode.attachment;
    return Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MessageInput(
          roomId: _room,
          totalMembers: 2,
          panelMode: mode,
          pickerHeight: open ? 300 : 0,
          pickerFullHeight: 300,
          pickerBaseHeight: 300,
          pickerMaxHeight: 500,
          animatePickerHeight: false,
          onPanelModeChanged: (next) => setState(() => mode = next),
          onPickerHeightChanged: (_) {},
          resolveSendPresentation: () => MessageSendPresentation.quiet,
          onMessageQueued: (_, _) {},
          onMessageSent: (_, _) {},
        ),
      ),
    );
  }
}
