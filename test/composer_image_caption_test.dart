import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/attachment_media_draft.dart';
import 'package:matter/pages/chat/attachment_media_gallery.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/composer/composer_draft_controller.dart';
import 'package:matter/pages/chat/composer/composer_input.dart';
import 'package:matter/pages/chat/composer/composer_text_field.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/composer_attachment_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = (roomId: '!room:example.org', userId: '@me:example.org');
final _pixels = Uint8List.fromList(
  img.encodePng(img.Image(width: 2, height: 2)),
);
XFile _image() => XFile.fromData(
  _pixels,
  path: '/photo.png',
  name: 'photo.png',
  mimeType: 'image/png',
);

class _Api implements RustLibApi {
  final images = <({String room, String filename, String? caption})>[];
  bool fail = false;

  @override
  Future<String> crateApiMatrixSendImageMessage({
    required String accountUserId,
    required String roomId,
    required List<int> imageData,
    required String filename,
    String? mimeType,
    int? width,
    int? height,
    String? caption,
    String? sharedCaption,
    rust.ImageMessageMetadata? metadata,
  }) async {
    if (fail) throw StateError('offline');
    images.add((room: roomId, filename: filename, caption: caption));
    return r'$image';
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ProviderContainer> _pumpComposer(
  WidgetTester tester,
  GlobalKey<MessageInputState> key, {
  InputPanelMode panelMode = InputPanelMode.none,
}) async {
  final container = ProviderContainer();
  container.read(activeUserIdProvider.notifier).value = _key.userId;
  container.read(messageDraftProvider(_key).notifier).value = 'A sunset';
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildMaterialTheme(Brightness.light)
            .copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MessageInput(
              key: key,
              roomId: _key.roomId,
              totalMembers: 2,
              panelMode: panelMode,
              pickerHeight: 250,
              pickerFullHeight: 250,
              pickerBaseHeight: 250,
              pickerMaxHeight: 350,
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
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.images.clear();
    api.fail = false;
  });

  testWidgets('touch composer stages images above text without uploading', (
    tester,
  ) async {
    final key = GlobalKey<MessageInputState>();
    final container = await _pumpComposer(tester, key);
    final released = key.currentState!.previewExternalFiles([_image()]);
    await tester.pumpAndSettle();
    final strip = find.byKey(const ValueKey('composer-attachment-strip'));
    expect(strip, findsOneWidget);
    expect(
      tester.getTopLeft(strip).dy,
      lessThan(tester.getTopLeft(find.byType(ComposerTextField)).dy),
    );
    expect(find.text('A sunset'), findsOneWidget);
    final remove = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '移除图片',
      ),
    );
    expect(remove.style!.fixedSize!.resolve({}), const Size.square(24));
    final removeFinder = find.byWidget(remove);
    final thumbnail = find.byKey(
      ValueKey(
        'pending-attachment:${container.read(composerAttachmentDraftProvider(_key)).selected.single.id}',
      ),
    );
    expect(tester.getSize(removeFinder).width, 24);
    expect(tester.getTopRight(removeFinder), tester.getTopRight(thumbnail));
    final target = find
        .ancestor(
          of: removeFinder,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is GestureDetector && widget.excludeFromSemantics,
          ),
        )
        .first;
    expect(tester.getSize(target).width, 48);
    expect(api.images, isEmpty);
    await tester.tap(find.byTooltip('移除图片'));
    await tester.pumpAndSettle();
    await released;
    expect(strip, findsNothing);
    expect(container.read(messageDraftProvider(_key)), 'A sunset');
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  testWidgets(
    'touch send puts text on the image and clears a successful draft',
    (tester) async {
      final key = GlobalKey<MessageInputState>();
      final container = await _pumpComposer(tester, key);
      unawaited(key.currentState!.previewExternalFiles([_image()]));
      await tester.pumpAndSettle();
      // The transport mock has no sync stream; emulate the reconciled echo.
      final pending = container.read(composerAttachmentDraftProvider(_key));
      pending.addListener(() {
        if (pending.isSending && pending.selected.isEmpty) {
          container.read(localOutgoingMessagesProvider(_key).notifier).value =
              [];
        }
      });
      await tester.tap(find.byKey(const ValueKey('send_only')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(api.images, [
        (room: _key.roomId, filename: 'photo.png', caption: 'A sunset'),
      ]);
      expect(pending.selected, isEmpty);
      expect(
        find.byKey(const ValueKey('composer-attachment-strip')),
        findsNothing,
      );
      expect(find.text('A sunset'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );

  testWidgets('touch composer still sends an image without text', (
    tester,
  ) async {
    final key = GlobalKey<MessageInputState>();
    final container = await _pumpComposer(tester, key);
    container.read(messageDraftProvider(_key).notifier).value = '';
    await tester.pump();
    unawaited(key.currentState!.previewExternalFiles([_image()]));
    await tester.pumpAndSettle();
    // The transport mock has no sync stream; emulate the reconciled echo.
    final pending = container.read(composerAttachmentDraftProvider(_key));
    pending.addListener(() {
      if (pending.isSending && pending.selected.isEmpty) {
        container.read(localOutgoingMessagesProvider(_key).notifier).value = [];
      }
    });
    await tester.tap(find.byKey(const ValueKey('send_only')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(api.images, [
      (room: _key.roomId, filename: 'photo.png', caption: null),
    ]);
    expect(pending.selected, isEmpty);
    expect(
      find.byKey(const ValueKey('composer-attachment-strip')),
      findsNothing,
    );
    expect(find.text('A sunset'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  testWidgets('failed image send preserves text and pending image', (
    tester,
  ) async {
    api.fail = true;
    final key = GlobalKey<MessageInputState>();
    final container = await _pumpComposer(tester, key);
    unawaited(key.currentState!.previewExternalFiles([_image()]));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('send_only')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    expect(
      find.byKey(const ValueKey('composer-attachment-strip')),
      findsOneWidget,
    );
    expect(container.read(messageDraftProvider(_key)), 'A sunset');
    expect(
      container.read(composerAttachmentDraftProvider(_key)).selected,
      hasLength(1),
    );
    expect(api.images, isEmpty);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  test('gallery handoff retains edits and original/compression controls', () {
    final gallery = AttachmentMediaDraft();
    final pending = ComposerAttachmentDraft();
    final item = gallery.forFile(_image());
    gallery.toggle(item);
    gallery.applyEdit(item, Uint8List.fromList(_pixels), 'edited.png');
    gallery.toggleSpoiler(item);
    pending.addItems(gallery.selected);
    gallery.dispose();
    expect(pending.selected.single, same(item));
    expect(item.editedFilename, 'edited.png');
    expect(item.spoiler, isTrue);
    pending.toggleSendOriginal();
    expect(item.compress, isTrue);
    pending.addItems([item]);
    expect(pending.selected, hasLength(1));
    pending.dispose();
  });

  test('pending images stay isolated by room and account', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final pending = container.read(composerAttachmentDraftProvider(_key));
    unawaited(pending.stage([_image()]));
    expect(
      container
          .read(
            composerAttachmentDraftProvider((
              roomId: '!other',
              userId: _key.userId,
            )),
          )
          .selected,
      isEmpty,
    );
    expect(
      container
          .read(
            composerAttachmentDraftProvider((
              roomId: _key.roomId,
              userId: '@other',
            )),
          )
          .selected,
      isEmpty,
    );
    expect(pending.selected, hasLength(1));
  });

  testWidgets('gallery selection updates composer while picker stays open', (
    tester,
  ) async {
    final key = GlobalKey<MessageInputState>();
    final container = await _pumpComposer(
      tester,
      key,
      panelMode: InputPanelMode.attachment,
    );
    final gallery = tester
        .widget<AttachmentMediaFallback>(find.byType(AttachmentMediaFallback))
        .draft;
    final image = gallery.forFile(_image());
    gallery.toggle(image);
    await tester.pumpAndSettle();
    final pending = container.read(composerAttachmentDraftProvider(_key));
    expect(pending.selected, [image]);
    expect(
      find.byKey(const ValueKey('composer-attachment-strip')),
      findsOneWidget,
    );
    expect(find.byType(AttachmentMediaFallback), findsOneWidget);
    expect(api.images, isEmpty);
    gallery.toggle(image);
    await tester.pumpAndSettle();
    expect(pending.selected, isEmpty);
    expect(
      find.byKey(const ValueKey('composer-attachment-strip')),
      findsNothing,
    );
    expect(container.read(messageDraftProvider(_key)), 'A sunset');
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  testWidgets('composer clear and remove also deselect gallery images', (
    tester,
  ) async {
    final key = GlobalKey<MessageInputState>();
    final container = await _pumpComposer(
      tester,
      key,
      panelMode: InputPanelMode.attachment,
    );
    final gallery = tester
        .widget<AttachmentMediaFallback>(find.byType(AttachmentMediaFallback))
        .draft;
    final image = gallery.forFile(_image());
    gallery.toggle(image);
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(gallery.selected, isEmpty);
    expect(
      container.read(composerAttachmentDraftProvider(_key)).selected,
      isEmpty,
    );
    gallery.toggle(image);
    await tester.pumpAndSettle();
    expect(container.read(composerAttachmentDraftProvider(_key)).selected, [
      image,
    ]);
    await tester.tap(find.byTooltip('移除图片'));
    await tester.pumpAndSettle();
    expect(gallery.selected, isEmpty);
    expect(container.read(messageDraftProvider(_key)), 'A sunset');
    expect(api.images, isEmpty);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  testWidgets('gallery selection stages images without confirmation', (
    tester,
  ) async {
    final gallery = AttachmentMediaDraft();
    final image = gallery.forFile(_image());
    final text = TextEditingController(text: 'A sunset');
    List<AttachmentMediaItem>? staged;
    List<AttachmentMediaItem>? removed;
    var closed = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: AttachmentPicker(
                draft: gallery,
                composerController: text,
                onImagesSelected: (items) => staged = items,
                onImagesDeselected: (items) => removed = items,
                height: 300,
                maxHeight: 300,
                roomId: _key.roomId,
                accountUserId: _key.userId,
                totalMembers: 2,
                onRefresh: (_) async {},
                resolveSendPresentation: () => MessageSendPresentation.quiet,
                onMessageQueued: (_, _) {},
                onMessageSent: (_, _) {},
                onHeightChanged: (_) {},
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    gallery.toggle(image);
    await tester.pumpAndSettle();
    expect(staged, [image]);
    expect(
      find.byKey(const ValueKey('attachment-caption-input')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('attachment-original-toggle')),
      findsOneWidget,
    );
    text.text = 'Updated in main composer';
    expect(closed, isFalse);
    expect(api.images, isEmpty);
    expect(find.text('添加到输入框'), findsNothing);
    gallery.toggle(image);
    await tester.pumpAndSettle();
    expect(removed, [image]);
    gallery.toggle(image);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('attachment-send-button')));
    expect(staged, [image]);
    expect(closed, isTrue);
    expect(api.images, isEmpty);
    expect(text.text, 'Updated in main composer');
    await tester.pumpWidget(const SizedBox());
    gallery.dispose();
    text.dispose();
  });
}
