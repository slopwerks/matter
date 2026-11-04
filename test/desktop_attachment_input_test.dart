import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/attachment_image_resize.dart';
import 'package:matter/pages/chat/attachment_media_utils.dart';
import 'package:matter/pages/chat/desktop_clipboard.dart';
import 'package:matter/pages/chat/external_attachment_preview.dart';
import 'package:matter/pages/chat/composer_attachment_strip.dart';
import 'package:matter/pages/chat/attachment_image_preview_page.dart';
import 'package:matter/providers/composer_attachment_provider.dart';
import 'package:matter/providers/interaction_mode_provider.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

class _Api implements RustLibApi {
  final images =
      <
        ({
          String account,
          String room,
          String filename,
          String? caption,
          List<int> bytes,
        })
      >[];
  final polls = <String>[];
  final locations = <String>[];
  @override
  Future<void> crateApiMatrixSendPoll({
    required String accountUserId,
    required String roomId,
    required String question,
    required List<String> answers,
    required bool disclosed,
    required int maxSelections,
  }) async {
    polls.add('$accountUserId/$roomId/$question/${answers.join(",")}');
  }

  @override
  Future<void> crateApiMatrixSendLocation({
    required String accountUserId,
    required String roomId,
    required String body,
    required String geoUri,
  }) async {
    locations.add('$accountUserId/$roomId/$geoUri');
  }

  final files = <String>[];
  String? failFile;
  bool fail = false;
  Completer<String>? pendingImage;
  String? failImage;

  @override
  Future<void> crateApiMatrixSendFileMessage({
    required String accountUserId,
    required String roomId,
    required List<int> fileData,
    required String filename,
    String? mimeType,
    int? size,
  }) async {
    files.add(filename);
    if (filename == failFile) throw StateError('file upload failed');
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {}
  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async =>
      false;
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
    images.add((
      account: accountUserId,
      room: roomId,
      filename: filename,
      caption: caption,
      bytes: imageData,
    ));
    if (fail || filename == failImage) throw StateError('upload failed');
    if (pendingImage case final pending?) return pending.future;
    return r'$image:example.org';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

Widget _input(
  ProviderContainer container, {
  bool material = false,
  bool dark = false,
  TargetPlatform platform = TargetPlatform.linux,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: neuTestTheme(
      material: material,
      dark: dark,
    ).copyWith(platform: platform),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MessageInput(
          roomId: '!paste:example.org',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('pasteboard');
  final api = _Api();
  late Uint8List png;
  Uint8List? clipboard;
  String? text;
  late ProviderContainer container;

  setUpAll(() async {
    RustLib.initMock(api: api);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff88aabb), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(16, 8);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    api.images.clear();
    api.polls.clear();
    api.locations.clear();
    api.files.clear();
    api.failFile = null;
    api.fail = false;
    api.pendingImage = null;
    api.failImage = null;
    clipboard = png;
    text = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        native,
        (call) async => call.method == 'image' ? clipboard : null,
      )
      ..setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => switch (call.method) {
          'Clipboard.getData' => text == null ? null : {'text': text},
          'Clipboard.hasStrings' => {'value': text != null},
          _ => null,
        },
      );
  });
  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(native, null)
      ..setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> paste(WidgetTester tester, {bool mac = false}) async {
    final modifier = mac
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  Future<void> disposeInput(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.read(activeUserIdProvider.notifier).value = null;
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  Future<void> finishUpload(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  test('clipboard keeps detected image type and no-image leaves text paste available', () async {
    final image = await readClipboardImage();
    expect(image!.mimeType, 'image/png');
    expect(image.name, endsWith('.png'));
    expect(await image.readAsBytes(), png);
    clipboard = null;
    expect(await readClipboardImage(), isNull);
    clipboard = Uint8List(attachmentMaxBufferedBytes + 1);
    await expectLater(readClipboardImage(), throwsStateError);
    clipboard = Uint8List.fromList([1, 2, 3]);
    await expectLater(readClipboardImage(), throwsStateError);
  });

  test(
    'desktop resizing produces a bounded JPEG without a native compressor',
    () async {
      final resized = await resizeAttachmentJpeg(
        png,
        width: 8,
        height: 4,
        quality: 92,
      );
      expect(detectImageMime(resized), 'image/jpeg');
      expect(await decodeAttachmentImageSize(resized), const Size(8, 4));
    },
  );

  test(
    'pending image access lasts through staging and releases on removal',
    () async {
      final draft = ComposerAttachmentDraft();
      final file = XFile.fromData(
        png,
        path: 'pending.png',
        name: 'pending.png',
      );
      var released = false;
      final staged = draft.stage([file]).then((_) => released = true);
      expect(draft.selected, hasLength(1));
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse);
      draft.toggle(draft.selected.single);
      await staged;
      expect(released, isTrue);
      draft.dispose();
    },
  );

  test('disposing the pending draft releases dropped file access', () async {
    final draft = ComposerAttachmentDraft();
    final staged = draft.stage([
      XFile.fromData(png, path: 'pending.png', name: 'pending.png'),
    ]);
    draft.dispose();
    await staged;
  });

  testWidgets(
    'pending images survive input remount and remain account isolated',
    (tester) async {
      await tester.pumpWidget(_input(container));
      await tester.tap(find.byType(TextField));
      await paste(tester);
      final key = (roomId: '!paste:example.org', userId: '@alice:example.org');
      expect(
        container.read(composerAttachmentDraftProvider(key)).selected,
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_input(container));
      await tester.pumpAndSettle();
      expect(find.byType(ComposerAttachmentStrip), findsOneWidget);
      expect(find.byTooltip('移除图片'), findsOneWidget);
      expect(
        container
            .read(
              composerAttachmentDraftProvider((
                roomId: key.roomId,
                userId: '@bob:example.org',
              )),
            )
            .selected,
        isEmpty,
      );
      await disposeInput(tester);
    },
  );

  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
        'image paste previews without sending; cancel keeps text and focus ($material/$dark)',
        (tester) async {
          await tester.pumpWidget(
            _input(container, material: material, dark: dark),
          );
          await tester.enterText(find.byType(TextField), '保留这份文字草稿');
          final controller = tester
              .widget<TextField>(find.byType(TextField))
              .controller!;
          await paste(tester);
          expect(find.byType(ComposerAttachmentStrip), findsOneWidget);
          expect(find.byType(ExternalAttachmentPreview), findsNothing);
          expect(find.byType(Dialog), findsNothing);
          expect(api.images, isEmpty);
          expect(controller.text, '保留这份文字草稿');
          expect(
            tester
                .getTopLeft(
                  find.byKey(const ValueKey('composer-attachment-strip')),
                )
                .dy,
            lessThan(tester.getTopLeft(find.byType(TextField)).dy),
          );
          await tester.tap(find.byTooltip('移除图片'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('composer-attachment-strip')),
            findsNothing,
          );
          final input = tester.widget<TextField>(find.byType(TextField));
          expect(input.controller!.text, '保留这份文字草稿');
          expect(input.focusNode!.hasFocus, isTrue);
          expect(tester.takeException(), isNull);
          await disposeInput(tester);
        },
      );
    }
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    testWidgets('text-only paste preserves selection on $platform', (
      tester,
    ) async {
      clipboard = null;
      text = '替换';
      await tester.pumpWidget(_input(container, platform: platform));
      await tester.enterText(find.byType(TextField), 'abcd');
      final input = tester.widget<TextField>(find.byType(TextField));
      input.controller!.selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 3,
      );
      await paste(tester, mac: platform == TargetPlatform.macOS);
      expect(input.controller!.text, 'a替换d');
      expect(find.byType(ExternalAttachmentPreview), findsNothing);
      await disposeInput(tester);
    });
  }

  testWidgets(
    'right-click Paste accepts an image even without clipboard text',
    (tester) async {
      await tester.pumpWidget(_input(container));
      await tester.enterText(find.byType(TextField), '草稿');
      await tester.tap(find.byType(TextField), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除图片'), findsOneWidget);
      expect(api.images, isEmpty);
      await tester.tap(find.byTooltip('移除图片'));
      await tester.pumpAndSettle();
      await disposeInput(tester);
    },
  );

  testWidgets(
    'only confirmation sends, retry keeps failed image and original draft',
    (tester) async {
      await tester.pumpWidget(_input(container));
      await tester.enterText(find.byType(TextField), '继续输入');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller!;
      await paste(tester);
      await tester.enterText(find.byType(TextField), '图片说明');
      api.fail = true;
      await tester.tap(find.byKey(const ValueKey('send_only')));
      await finishUpload(tester);
      expect(api.images, hasLength(1));
      expect(find.byTooltip('移除图片'), findsOneWidget);
      expect(controller.text, '图片说明');
      api.fail = false;
      await tester.tap(find.byKey(const ValueKey('send_only')));
      await finishUpload(tester);
      expect(api.images, hasLength(2));
      expect(api.images.last.account, '@alice:example.org');
      expect(api.images.last.room, '!paste:example.org');
      expect(api.images.last.bytes, png);
      expect(api.images.last.caption, '图片说明');
      expect(find.byTooltip('移除图片'), findsNothing);
      expect(controller.text, isEmpty);
      await disposeInput(tester);
    },
  );

  testWidgets('desktop image button stages selected files above the editor', (
    tester,
  ) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('matter-inline-images-'),
    ))!;
    final file = File('${dir.path}/selected.png');
    await tester.runAsync(() => file.writeAsBytes(png));
    const selector = MethodChannel('plugins.flutter.io/file_selector');
    var requests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(selector, (call) async {
          if (call.method == 'openFile') {
            requests++;
            return [file.path];
          }
          return null;
        });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(selector, null);
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(_input(container));
    await tester.tap(find.byIcon(Icons.image_outlined));
    await finishUpload(tester);
    expect(requests, 1);
    expect(find.byTooltip('移除图片'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(api.images, isEmpty);
    await disposeInput(tester);
  });

  testWidgets('Enter sends image-only drafts through the normal send action', (
    tester,
  ) async {
    await tester.pumpWidget(_input(container));
    await tester.tap(find.byType(TextField));
    await paste(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await finishUpload(tester);
    expect(api.images, hasLength(1));
    expect(api.images.single.caption, isNull);
    expect(find.byTooltip('移除图片'), findsNothing);
    await disposeInput(tester);
  });

  testWidgets('image editing is optional and cancel keeps staged images', (
    tester,
  ) async {
    await tester.pumpWidget(_input(container));
    await tester.enterText(find.byType(TextField), '图片文字');
    await paste(tester);
    await tester.tap(
      find
          .descendant(
            of: find.byType(ComposerAttachmentStrip),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentImagePreviewPage), findsOneWidget);
    expect(api.images, isEmpty);
    final previewContext = tester.element(
      find.byType(AttachmentImagePreviewPage),
    );
    Navigator.of(previewContext).pop();
    await tester.pumpAndSettle();
    expect(find.byTooltip('移除图片'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '图片文字',
    );
    await disposeInput(tester);
  });

  testWidgets('repeated paste appends images instead of replacing the draft', (
    tester,
  ) async {
    await tester.pumpWidget(_input(container));
    await tester.tap(find.byType(TextField));
    await paste(tester);
    await paste(tester);
    expect(find.byTooltip('移除图片'), findsNWidgets(2));
    expect(api.images, isEmpty);
    await disposeInput(tester);
  });

  testWidgets('typing during an image upload keeps the next text draft', (
    tester,
  ) async {
    await tester.pumpWidget(_input(container));
    await tester.enterText(find.byType(TextField), '本次说明');
    await paste(tester);
    api.pendingImage = Completer<String>();
    await tester.tap(find.byKey(const ValueKey('send_only')));
    for (var i = 0; i < 20 && api.images.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(api.images, hasLength(1));
    await tester.enterText(find.byType(TextField), '下一份草稿');
    api.pendingImage!.complete(r'$accepted');
    await finishUpload(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '下一份草稿',
    );
    expect(api.images.single.caption, '本次说明');
    expect(find.byTooltip('移除图片'), findsNothing);
    await disposeInput(tester);
  });

  testWidgets(
    'an accepted image is removed when the input remounts during upload',
    (tester) async {
      await tester.pumpWidget(_input(container));
      await tester.enterText(find.byType(TextField), '本次说明');
      await paste(tester);
      api.pendingImage = Completer<String>();
      await tester.tap(find.byKey(const ValueKey('send_only')));
      for (var i = 0; i < 20 && api.images.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(api.images, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(_input(container));
      api.pendingImage!.complete(r'$accepted');
      await finishUpload(tester);
      expect(api.images, hasLength(1));
      expect(find.byTooltip('移除图片'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await disposeInput(tester);
    },
  );

  testWidgets('multi-image retry only sends the remaining image and caption', (
    tester,
  ) async {
    await tester.pumpWidget(_input(container));
    await tester.enterText(find.byType(TextField), '图片组说明');
    final input = tester.state<MessageInputState>(find.byType(MessageInput));
    unawaited(
      input.previewExternalFiles([
        XFile.fromData(
          png,
          path: 'one.png',
          name: 'one.png',
          mimeType: 'image/png',
        ),
        XFile.fromData(
          png,
          path: 'two.png',
          name: 'two.png',
          mimeType: 'image/png',
        ),
      ]),
    );
    await tester.pumpAndSettle();
    api.failImage = 'two.png';
    await tester.tap(find.byKey(const ValueKey('send_only')));
    await finishUpload(tester);
    expect(api.images.map((image) => image.filename), ['one.png', 'two.png']);
    expect(find.byTooltip('移除图片'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '图片组说明',
    );
    api.failImage = null;
    await tester.tap(find.byKey(const ValueKey('send_only')));
    await finishUpload(tester);
    expect(api.images.map((image) => image.filename), [
      'one.png',
      'two.png',
      'two.png',
    ]);
    expect(api.images.last.caption, '图片组说明');
    expect(find.byTooltip('移除图片'), findsNothing);
    await disposeInput(tester);
  });

  testWidgets(
    'pending images remain visible after keyboard-to-touch mode switch',
    (tester) async {
      await container
          .read(interactionModeProvider.notifier)
          .setMode(InteractionMode.keyboardMouse);
      await tester.pumpWidget(
        _input(container, platform: TargetPlatform.android),
      );
      await tester.enterText(find.byType(TextField), '保留说明');
      final input = tester.state<MessageInputState>(find.byType(MessageInput));
      unawaited(
        input.previewExternalFiles([
          XFile.fromData(
            png,
            path: 'touch.png',
            name: 'touch.png',
            mimeType: 'image/png',
          ),
        ]),
      );
      await tester.pumpAndSettle();
      await container
          .read(interactionModeProvider.notifier)
          .setMode(InteractionMode.touch);
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除图片'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留说明',
      );
      await tester.tap(find.byTooltip('移除图片'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除图片'), findsNothing);
      await disposeInput(tester);
    },
  );

  testWidgets(
    'desktop more opens poll directly and sends through the room pipeline',
    (tester) async {
      await tester.pumpWidget(_input(container));
      await tester.enterText(find.byType(TextField), '保留草稿');
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('发送文件'), findsOneWidget);
      expect(find.text('发送位置'), findsOneWidget);
      expect(find.text('其他附件'), findsNothing);
      await tester.tap(find.text('发起投票'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AttachmentPicker>(find.byType(AttachmentPicker))
            .initialTab,
        AttachmentTab.poll,
      );
      final fields = find.descendant(
        of: find.byType(AttachmentPicker),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '午饭吃什么');
      await tester.enterText(fields.at(1), '面条');
      await tester.enterText(fields.at(2), '米饭');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('attachment-send-button')));
      await finishUpload(tester);
      expect(api.polls, hasLength(1));
      expect(api.polls.single, contains('午饭吃什么/面条,米饭'));
      expect(find.byType(Dialog), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留草稿',
      );
      await disposeInput(tester);
    },
  );

  testWidgets(
    'desktop location entry opens location and blocks a stale account',
    (tester) async {
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final cache = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('matter-map-test-'),
      ))!;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => cache.path);
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null);
        await cache.delete(recursive: true);
      });
      const location = MethodChannel('flutter.baseflow.com/geolocator');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            location,
            (call) async => switch (call.method) {
              'isLocationServiceEnabled' => true,
              'checkPermission' => 2,
              'getCurrentPosition' => <String, dynamic>{
                'latitude': 39.9,
                'longitude': 116.4,
              },
              _ => null,
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(location, null),
      );
      await tester.pumpWidget(_input(container));
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送位置'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AttachmentPicker>(find.byType(AttachmentPicker))
            .initialTab,
        AttachmentTab.location,
      );
      expect(find.text('正在获取当前位置'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('attachment-send-button')));
      await finishUpload(tester);
      expect(api.locations, hasLength(1));
      expect(api.locations.single, contains('geo:39.9,116.4'));
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送位置'));
      await tester.pumpAndSettle();
      container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      await tester.tap(find.byKey(const ValueKey('attachment-send-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.locations, hasLength(1));
      expect(find.textContaining('账号已切换'), findsOneWidget);
      Navigator.of(
        tester.element(find.byType(AttachmentPicker)),
        rootNavigator: true,
      ).pop();
      await tester.pumpAndSettle();
      await disposeInput(tester);
    },
  );

  testWidgets('mixed dropped batch retries only the unsent files', (
    tester,
  ) async {
    await tester.pumpWidget(_input(container));
    await tester.enterText(find.byType(TextField), '保留文字');
    final input = tester.state<MessageInputState>(find.byType(MessageInput));
    final preview = input.previewExternalFiles([
      XFile.fromData(
        png,
        path: 'picture.png',
        name: 'picture.png',
        mimeType: 'image/png',
      ),
      XFile.fromData(Uint8List.fromList([1]), path: 'one.pdf', name: 'one.pdf'),
      XFile.fromData(Uint8List.fromList([2]), path: 'two.pdf', name: 'two.pdf'),
    ]);
    unawaited(preview);
    await tester.pumpAndSettle();
    expect(find.text('发送 3 项'), findsOneWidget);
    expect(api.files, isEmpty);
    api.failFile = 'two.pdf';
    await tester.tap(find.byKey(const ValueKey('external-attachment-send')));
    await finishUpload(tester);
    expect(api.images, hasLength(1));
    expect(api.files, ['one.pdf', 'two.pdf']);
    expect(find.text('发送 1 项'), findsOneWidget);
    api.failFile = null;
    await tester.tap(find.byKey(const ValueKey('external-attachment-send')));
    await finishUpload(tester);
    await preview;
    expect(api.images, hasLength(1));
    expect(api.files, ['one.pdf', 'two.pdf', 'two.pdf']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '保留文字',
    );
    await disposeInput(tester);
  });

  testWidgets(
    'switching accounts blocks a preview from uploading as the previous account',
    (tester) async {
      await tester.pumpWidget(_input(container));
      await tester.enterText(find.byType(TextField), '草稿');
      await paste(tester);
      container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      await tester.tap(find.byKey(const ValueKey('send_only')));
      await tester.pumpAndSettle();
      expect(api.images, isEmpty);
      expect(find.textContaining('账号已切换'), findsOneWidget);
      await disposeInput(tester);
    },
  );
}
