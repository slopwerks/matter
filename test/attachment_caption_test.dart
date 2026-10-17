import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_caption_composer.dart';
import 'package:matter/pages/chat/attachment_image_preview_page.dart';
import 'package:matter/pages/chat/attachment_media_draft.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/chat_image_editor_page.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/src/rust/api/matrix.dart' show ImageMessageMetadata;

import 'helpers/neu_test_theme.dart';

late Uint8List _pixel;

class _CloudAsset implements AssetEntity {
  final reads = <String>[];
  @override
  String get id => 'cloud-image';
  @override
  Future<File?> get originFile async {
    reads.add(id);
    if (reads.length == 1) throw StateError('cloud unavailable');
    return File('/cache/temporary-image');
  }

  @override
  Future<String> get titleAsync async => 'holiday.jpg';
  @override
  Future<String?> get mimeTypeAsync async => 'image/jpeg';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageApi implements RustLibApi {
  final calls =
      <
        ({
          String filename,
          String account,
          String? caption,
          String? sharedCaption,
          ImageMessageMetadata? metadata,
          List<int> bytes,
        })
      >[];
  String? failFilename;
  Completer<void>? pendingUpload;

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
    ImageMessageMetadata? metadata,
  }) async {
    calls.add((
      filename: filename,
      account: accountUserId,
      caption: caption,
      sharedCaption: sharedCaption,
      metadata: metadata,
      bytes: List.of(imageData),
    ));
    await pendingUpload?.future;
    if (filename == failFilename) throw StateError('upload failed');
    return '\$image-${calls.length}:example.org';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff4488cc), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 8);
    _pixel = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });
  late _ImageApi api;
  late Directory temp;
  late List<String> files;
  const channel = MethodChannel('plugins.flutter.io/file_selector');

  setUp(() async {
    api = _ImageApi();
    RustLib.initMock(api: api);
    temp = await Directory.systemTemp.createTemp('matter-image-caption-');
    files = [
      for (final name in ['one.png', 'two.png']) '${temp.path}/$name',
    ];
    for (final path in files) {
      await File(path).writeAsBytes(_pixel);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => files);
  });
  tearDown(() async {
    RustLib.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  Future<void> pick(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          localizationsDelegates: const [
            ...material_ui.GlobalMaterialLocalizations.delegates,
          ],
          home: const _PickerHarness(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片 / 视频'));
    await tester.pumpAndSettle();
  }

  Future<void> settleMedia(WidgetTester tester) async {
    for (var index = 0; index < 20; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, int expected) async {
    await tester.tap(find.byKey(const ValueKey('attachment-send-button')));
    for (var index = 0; index < 100 && api.calls.length < expected; index++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(api.calls.length, expected);
    await settleMedia(tester);
  }

  test('cloud originals can retry and keep the album filename instead of the cache filename', () async {
    final asset = _CloudAsset();
    final item = AttachmentMediaItem.asset(asset);
    await expectLater(item.original, throwsStateError);
    final original = await item.original;
    expect(original.filename, 'holiday.jpg');
    expect(original.file.path, '/cache/temporary-image');
    expect(original.file.mimeType, 'image/jpeg');
    expect((await item.original).filename, 'holiday.jpg');
    expect(asset.reads, hasLength(2));
  });

  test(
    'draft keeps selection order, description and edited format together',
    () {
      final draft = AttachmentMediaDraft();
      final one = draft.forFile(
        XFile.fromData(
          _pixel,
          path: 'one.jpg',
          name: 'one.jpg',
          mimeType: 'image/jpeg',
        ),
      );
      final two = draft.forFile(
        XFile.fromData(
          _pixel,
          path: 'two.png',
          name: 'two.png',
          mimeType: 'image/png',
        ),
      );
      draft.toggle(two);
      draft.toggle(one);
      draft.description.text = '共同描述';
      draft.applyEdit(one, _pixel, 'one.jpg');
      draft.toggleCompression(one);
      expect(draft.selected, [two, one]);
      expect(draft.order(two), 1);
      expect(draft.order(one), 2);
      expect(one.editedFilename, 'one.png');
      expect(one.editedMimeType, 'image/png');
      expect(one.compress, isFalse);
      expect(draft.description.text, '共同描述');
      draft.toggle(two);
      expect(draft.order(one), 1);
      draft.dispose();
    },
  );

  testWidgets('GIF preview exposes only Raw and sends the original bytes', (
    tester,
  ) async {
    final gif = base64Decode(
      'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
    );
    files = ['${temp.path}/animation.gif'];
    await tester.runAsync(() => File(files.single).writeAsBytes(gif));
    await pick(tester);
    await tester.tap(find.text('animation.gif'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final preview = tester.widget<AttachmentImagePreviewPage>(
      find.byType(AttachmentImagePreviewPage),
    );
    await tester.runAsync(() => preview.initialImage.readImageBytes());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.sd_outlined), findsNothing);
    final raw = find.ancestor(
      of: find.byIcon(Icons.raw_on_outlined),
      matching: find.byType(IconButton),
    );
    expect(raw, findsOneWidget);
    expect(tester.widget<IconButton>(raw).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('attachment-spoiler-toggle')));
    await tester.pump();
    expect(preview.initialImage.spoiler, isTrue);
    await send(tester, 1);
    expect(api.calls.single.metadata?.spoiler, isTrue);
    expect(api.calls.single.metadata?.blurhash, isNotEmpty);
    expect(api.calls.single.bytes, gif);
    expect(api.calls.single.filename, 'animation.gif');
  });

  testWidgets(
    'selected images replace the category dock and caption only the final image',
    (tester) async {
      await pick(tester);
      expect(find.byKey(const ValueKey('attachment-tab-bar')), findsNothing);
      final input = find.byKey(const ValueKey('attachment-caption-input'));
      expect(input, findsOneWidget);
      expect(find.byTooltip('发送 2 项'), findsOneWidget);
      await tester.enterText(input, '  旅途中的两张照片  ');
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(AttachmentPicker)).height, 500);
      await send(tester, 2);
      expect(api.calls.map((call) => call.filename), ['one.png', 'two.png']);
      expect(api.calls.map((call) => call.caption), [null, '旅途中的两张照片']);
      expect(api.calls.map((call) => call.sharedCaption), [null, null]);
      expect(api.calls.map((call) => call.metadata?.albumRoot), [
        null,
        '\$image-1:example.org',
      ]);
      expect(
        api.calls.every((call) => call.metadata?.blurhash?.isNotEmpty == true),
        isTrue,
      );
      expect(
        api.calls.every((call) => call.account == '@alice:example.org'),
        isTrue,
      );
      expect(find.text('closed'), findsOneWidget);
    },
  );

  testWidgets(
    'preview shares the draft and sends the current image when nothing is selected',
    (tester) async {
      await pick(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(AttachmentCaptionComposer),
          matching: find.byTooltip('取消选择'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('attachment-tab-bar')), findsOneWidget);
      await tester.ensureVisible(find.text('one.png'));
      await tester.tap(find.text('one.png'));
      await settleMedia(tester);
      final preview = tester.widget<AttachmentImagePreviewPage>(
        find.byType(AttachmentImagePreviewPage),
      );
      await tester.runAsync(() => preview.initialImage.readImageBytes());
      await tester.pumpAndSettle();
      expect(find.byType(ChatImageEditorPage), findsNothing);
      expect(find.byTooltip('发送 1 项'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('attachment-caption-input')),
        '当前这一张',
      );
      await send(tester, 1);
      expect(api.calls.single.filename, 'one.png');
      expect(api.calls.single.caption, '当前这一张');
      expect(api.calls.single.sharedCaption, isNull);
      expect(api.calls.single.metadata?.albumRoot, isNull);
      expect(find.byType(AttachmentImagePreviewPage), findsNothing);
      expect(find.text('closed'), findsOneWidget);
    },
  );

  testWidgets(
    'returning from editing keeps the preview, order and caption without sending',
    (tester) async {
      await pick(tester);
      await tester.enterText(
        find.byKey(const ValueKey('attachment-caption-input')),
        '保留描述',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('one.png'));
      await tester.tap(find.text('one.png'));
      await settleMedia(tester);
      final preview = tester.widget<AttachmentImagePreviewPage>(
        find.byType(AttachmentImagePreviewPage),
      );
      await tester.runAsync(() => preview.initialImage.readImageBytes());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多调整'));
      await settleMedia(tester);
      final editor = find.byType(ChatImageEditorPage);
      expect(editor, findsOneWidget);
      expect(tester.widget<ChatImageEditorPage>(editor).imageBytes, _pixel);
      Navigator.of(tester.element(editor)).pop(_pixel);
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentImagePreviewPage), findsOneWidget);
      expect(preview.draft.description.text, '保留描述');
      expect(preview.draft.order(preview.initialImage), 1);
      expect(preview.initialImage.editedBytes, _pixel);
      expect(api.calls, isEmpty);
      await tester.tap(find.byTooltip('返回选图'));
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentImagePreviewPage), findsNothing);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('attachment-caption-input')),
            )
            .controller!
            .text,
        '保留描述',
      );
      expect(find.byTooltip('发送 2 项'), findsOneWidget);
    },
  );

  testWidgets(
    'preview sends all selected images after changing the displayed image',
    (tester) async {
      await pick(tester);
      await tester.tap(find.text('one.png'));
      await settleMedia(tester);
      await tester.drag(find.byType(PageView), const Offset(-650, 0));
      await settleMedia(tester);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.byTooltip('发送 2 项'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('attachment-caption-input')),
        '整组发送',
      );
      await send(tester, 2);
      expect(api.calls.map((call) => call.filename), ['one.png', 'two.png']);
      expect(api.calls.map((call) => call.caption), [null, '整组发送']);
      expect(api.calls.map((call) => call.sharedCaption), [null, null]);
      expect(api.calls.map((call) => call.metadata?.albumRoot), [
        null,
        '\$image-1:example.org',
      ]);
      expect(find.text('closed'), findsOneWidget);
    },
  );

  for (final tool in ['裁剪', '笔刷']) {
    testWidgets(
      '$tool opens its editor and cancellation returns to the same draft',
      (tester) async {
        await pick(tester);
        await tester.tap(find.text('one.png'));
        await settleMedia(tester);
        final preview = tester.widget<AttachmentImagePreviewPage>(
          find.byType(AttachmentImagePreviewPage),
        );
        preview.draft.description.text = '保留选中与描述';
        await tester.tap(find.byTooltip(tool));
        await settleMedia(tester);
        final editor = tool == '裁剪'
            ? find.byType(CropRotateEditor)
            : find.byType(PaintEditor);
        expect(editor, findsOneWidget);
        Navigator.of(tester.element(editor)).pop();
        await settleMedia(tester);
        expect(find.byType(ChatImageEditorPage), findsNothing);
        expect(find.byType(AttachmentImagePreviewPage), findsOneWidget);
        expect(preview.draft.description.text, '保留选中与描述');
        expect(preview.draft.selected.length, 2);
        expect(api.calls, isEmpty);
      },
    );
  }

  testWidgets(
    'keyboard resize keeps the attachment draft and leaves the caption visible',
    (tester) async {
      final host = GlobalKey<_KeyboardHarnessState>();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: _KeyboardHarness(key: host),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择图片 / 视频'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('attachment-caption-input'));
      await tester.enterText(input, '键盘前后的描述');
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(AttachmentPicker));
      host.currentState!.setKeyboard(500);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(AttachmentPicker)), same(state));
      expect(
        tester.getSize(find.byType(AttachmentPicker)).height,
        attachmentCaptionClearance,
      );
      final captionBounds = tester.getRect(input);
      final pickerBounds = tester.getRect(find.byType(AttachmentPicker));
      expect(captionBounds.top, greaterThanOrEqualTo(pickerBounds.top));
      expect(captionBounds.bottom, lessThanOrEqualTo(pickerBounds.bottom));
      expect(tester.widget<TextField>(input).controller!.text, '键盘前后的描述');
      host.currentState!.setKeyboard(0);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '键盘前后的描述');
      expect(find.byTooltip('发送 2 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview remains closable if the picker is removed during upload',
    (tester) async {
      await pick(tester);
      await tester.tap(find.text('one.png'));
      await settleMedia(tester);
      final preview = tester.widget<AttachmentImagePreviewPage>(
        find.byType(AttachmentImagePreviewPage),
      );
      api.pendingUpload = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('attachment-send-button')));
      for (var index = 0; index < 100 && api.calls.isEmpty; index++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(api.calls, hasLength(1));
      final host = tester.state<_PickerHarnessState>(
        find.byType(_PickerHarness, skipOffstage: false),
      );
      host.close();
      await tester.pump();
      api.pendingUpload!.complete();
      await tester.pump();
      await tester.pump();
      expect(preview.draft.isSending, isFalse);
      expect(preview.draft.selected, hasLength(1));
      await tester.tap(find.byTooltip('返回选图'));
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentImagePreviewPage), findsNothing);
      expect(api.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial failure retains the remaining image and description for retry',
    (tester) async {
      await pick(tester);
      await tester.enterText(
        find.byKey(const ValueKey('attachment-caption-input')),
        '仍然保留',
      );
      api.failFilename = 'two.png';
      await send(tester, 2);
      expect(find.byTooltip('发送 1 项'), findsOneWidget);
      expect(find.textContaining('随后失败'), findsOneWidget);
      expect(find.text('closed'), findsNothing);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('attachment-caption-input')),
            )
            .controller!
            .text,
        '仍然保留',
      );
      api.failFilename = null;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await send(tester, 3);
      expect(api.calls.map((call) => call.filename), [
        'one.png',
        'two.png',
        'two.png',
      ]);
      expect(api.calls.last.caption, '仍然保留');
      expect(find.text('closed'), findsOneWidget);
    },
  );
}

class _KeyboardHarness extends StatefulWidget {
  const _KeyboardHarness({super.key});
  @override
  State<_KeyboardHarness> createState() => _KeyboardHarnessState();
}

class _KeyboardHarnessState extends State<_KeyboardHarness> {
  double keyboard = 0;
  double fullHeight = 300;
  void setKeyboard(double height) => setState(() => keyboard = height);
  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
    child: Scaffold(
      resizeToAvoidBottomInset: false,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MessageInput(
          roomId: '!room:example.org',
          totalMembers: 2,
          panelMode: InputPanelMode.attachment,
          pickerHeight: keyboard > 0 ? attachmentCaptionClearance : fullHeight,
          pickerFullHeight: fullHeight,
          pickerBaseHeight: 300,
          pickerMaxHeight: 500,
          animatePickerHeight: false,
          onPanelModeChanged: (_) {},
          onPickerHeightChanged: (height) =>
              setState(() => fullHeight = height),
          resolveSendPresentation: () => MessageSendPresentation.quiet,
          onMessageQueued: (_, _) {},
          onMessageSent: (_, _) {},
        ),
      ),
    ),
  );
}

class _PickerHarness extends StatefulWidget {
  const _PickerHarness();
  @override
  State<_PickerHarness> createState() => _PickerHarnessState();
}

class _PickerHarnessState extends State<_PickerHarness> {
  bool closed = false;
  void close() => setState(() => closed = true);
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: closed
          ? const Text('closed')
          : AttachmentPicker(
              height: 300,
              maxHeight: 500,
              roomId: '!room:example.org',
              accountUserId: '@alice:example.org',
              onRefresh: (_) async {},
              resolveSendPresentation: () => MessageSendPresentation.insert,
              onMessageSent: (_, _) {},
              onMessageQueued: (_, _) {},
              totalMembers: 2,
              onHeightChanged: (_) {},
              onClose: close,
            ),
    ),
  );
}
