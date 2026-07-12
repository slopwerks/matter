import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/chat_image_editor_page.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/theme/app_theme.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

const _pmChannel = 'com.fluttercandies/photo_manager';
const _locationChannel = MethodChannel('flutter.baseflow.com/geolocator');
const _fileSelectorChannel = MethodChannel('plugins.flutter.io/file_selector');

Future<void> _mockPhotoManagerEmpty() async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_pmChannel), (call) async {
        switch (call.method) {
          case 'requestPermissionExtend':
            return 3; // PermissionState.authorized
          case 'getAssetPathList':
            return <String, dynamic>{'data': <Map<String, dynamic>>[]};
          case 'getAssetCountFromPath':
            return 0;
          default:
            return null;
        }
      });
}

void _mockCurrentLocation({
  bool serviceEnabled = true,
  int permission = 2,
  double latitude = 39.9,
  double longitude = 116.4,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_locationChannel, (call) async {
        return switch (call.method) {
          'isLocationServiceEnabled' => serviceEnabled,
          'checkPermission' => permission,
          'requestPermission' => permission,
          'getCurrentPosition' => <String, dynamic>{
            'latitude': latitude,
            'longitude': longitude,
          },
          _ => null,
        };
      });
}

void main() {
  test('gallery requests newest assets first', () {
    expect(attachmentMediaOrder, hasLength(1));
    expect(attachmentMediaOrder.single.type, OrderOptionType.createDate);
    expect(attachmentMediaOrder.single.asc, isFalse);
  });

  test('location sharing resolves the current device position', () async {
    _mockCurrentLocation();
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_locationChannel, null),
    );

    final point = await currentAttachmentLocation();

    expect(point.latitude, 39.9);
    expect(point.longitude, 116.4);
  });

  test('location sharing reports disabled system location', () async {
    _mockCurrentLocation(serviceEnabled: false);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_locationChannel, null),
    );

    await expectLater(
      currentAttachmentLocation(),
      throwsA(predicate<Object>((error) => error.toString() == '请先开启系统定位服务')),
    );
  });

  test('attachment MIME fallback classifies common image and video files', () {
    final movMime = resolveAttachmentMime(
      'clip.MOV',
      'application/octet-stream',
    );
    final heicMime = resolveAttachmentMime('photo.HEIC', null);

    expect(movMime, 'video/quicktime');
    expect(classifyAttachmentMime(movMime), AttachmentMediaKind.video);
    expect(heicMime, 'image/heic');
    expect(classifyAttachmentMime(heicMime), AttachmentMediaKind.image);
    expect(classifyAttachmentMime('application/pdf'), AttachmentMediaKind.file);
  });

  test('edited image bytes determine their actual MIME type', () {
    expect(
      detectImageMime(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0])),
      'image/jpeg',
    );
    expect(
      detectImageMime(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      ),
      'image/png',
    );
    expect(
      detectImageMime(Uint8List.fromList('GIF89a'.codeUnits)),
      'image/gif',
    );
  });

  test('image editor keeps the original file and unbounded output config', () {
    const page = ChatImageEditorPage(
      imagePath: '/original/photo.png',
      mimeType: 'image/png',
    );
    final config = page.imageGenerationConfigs;

    expect(page.imagePath, '/original/photo.png');
    expect(config.enableUseOriginalBytes, isTrue);
    expect(config.maxOutputSize, Size.infinite);
    expect(config.outputFormat, OutputFormat.png);
    expect(config.jpegQuality, 100);
  });

  test(
    'coordinates are validated and normalized without exponent notation',
    () {
      expect(canonicalGeoUri('39.9000', '+116.400000'), 'geo:39.9,116.4');
      expect(canonicalGeoUri('-0', '.5'), 'geo:0,0.5');
      expect(canonicalGeoUri('NaN', '116.4'), isNull);
      expect(canonicalGeoUri('1e-7', '116.4'), isNull);
    },
  );

  testWidgets('plus button opens the rounded inline attachment panel', (
    tester,
  ) async {
    await _mockPhotoManagerEmpty();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _MessageInputHarness())),
    );
    await tester.pump();

    // The attachment affordance is now a plus icon, not a paperclip.
    expect(find.byIcon(Icons.attach_file_rounded), findsNothing);
    final plus = find.byIcon(Icons.add_rounded);
    expect(plus, findsOneWidget);

    await tester.tap(plus);
    await tester.pumpAndSettle();

    expect(find.byType(AttachmentPicker), findsOneWidget);
    expect(tester.getSize(find.byType(AttachmentPicker)).height, 300);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('投票'), findsOneWidget);
    expect(find.text('地址'), findsOneWidget);
    expect(find.text('图片 / 视频'), findsNothing);
    expect(find.byIcon(Icons.close_rounded), findsNothing);

    final outerSurface = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(AttachmentPicker),
            matching: find.byType(Material),
          ),
        )
        .singleWhere(
          (material) =>
              material.color == AppColors.surface &&
              material.clipBehavior == Clip.antiAlias,
        );
    final shape = outerSurface.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(AppRadii.surface));
  });

  testWidgets('attachment panel expands after an upward drag', (tester) async {
    await _mockPhotoManagerEmpty();
    await tester.pumpWidget(
      const MaterialApp(home: _AttachmentPickerHarness()),
    );
    await tester.pumpAndSettle();

    final picker = find.byType(AttachmentPicker);
    expect(tester.getSize(picker).height, 300);

    await tester.drag(
      find.byKey(const ValueKey('attachment-panel-drag-handle')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(picker).height, 500);
  });

  testWidgets('location map uses the panel resize handle', (tester) async {
    await _mockPhotoManagerEmpty();
    _mockCurrentLocation();
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_locationChannel, null),
    );
    await tester.pumpWidget(
      const MaterialApp(home: _AttachmentPickerHarness()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('地址'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('attachment-map-drag-handle')),
      findsNothing,
    );
    final markerLayer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
    expect(markerLayer.markers, hasLength(1));
    expect(find.text('发送'), findsOneWidget);

    final picker = find.byType(AttachmentPicker);
    await tester.drag(
      find.byKey(const ValueKey('attachment-panel-drag-handle')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(picker).height, 500);
  });

  testWidgets('file action opens the system file selector directly', (
    tester,
  ) async {
    await _mockPhotoManagerEmpty();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, (call) async {
          calls.add(call);
          return <String>[];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_fileSelectorChannel, null),
    );
    await tester.pumpWidget(
      const MaterialApp(home: _AttachmentPickerHarness()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'openFile');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['multiple'],
      isTrue,
    );
  });

  testWidgets('poll starts with two answers and preserves tab state', (
    tester,
  ) async {
    await _mockPhotoManagerEmpty();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _MessageInputHarness())),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('投票'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '选项 2'), findsOneWidget);
    expect(find.byTooltip('删除选项'), findsNothing);
    expect(find.text('发送'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '问题'), '午饭吃什么？');
    await tester.enterText(find.widgetWithText(TextField, '选项 1'), '面条');
    await tester.pump();
    final sendButtonFinder = find.byKey(
      const ValueKey('attachment-send-button'),
    );
    var sendButton = tester.widget<FilledButton>(sendButtonFinder);
    expect(sendButton.onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, '选项 2'), '米饭');
    await tester.pump();
    sendButton = tester.widget<FilledButton>(sendButtonFinder);
    expect(sendButton.onPressed, isNotNull);
    expect(tester.getSize(sendButtonFinder).height, 44);
    final tabBarTop = tester
        .getTopLeft(find.byKey(const ValueKey('attachment-tab-bar')))
        .dy;
    final sendButtonBottom = tester.getBottomLeft(sendButtonFinder).dy;
    expect(tabBarTop - sendButtonBottom, greaterThanOrEqualTo(8));

    await tester.tap(find.text('图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('投票'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '问题'))
          .controller
          ?.text,
      '午饭吃什么？',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '选项 1'))
          .controller
          ?.text,
      '面条',
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '选项 2'))
          .controller
          ?.text,
      '米饭',
    );
  });

  testWidgets('removing an option expands the remaining input smoothly', (
    tester,
  ) async {
    await _mockPhotoManagerEmpty();
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _MessageInputHarness())),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('投票'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('attachment-panel-drag-handle')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();

    final firstOption = find.byKey(const ValueKey('poll-option-input-0'));
    final fullWidth = tester.getSize(firstOption).width;

    await tester.tap(find.text('添加选项'));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    final compactWidth = tester.getSize(firstOption).width;
    expect(compactWidth, lessThan(fullWidth));

    final removeButton = find.byTooltip('删除选项').last;
    await tester.tap(removeButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getSize(firstOption).width, greaterThan(compactWidth));
    await tester.pumpAndSettle();

    expect(tester.getSize(firstOption).width, fullWidth);
    expect(find.widgetWithText(TextField, '选项 3'), findsNothing);

    final addButton = find.text('添加选项');
    await tester.tap(addButton);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getSize(firstOption).width, lessThan(fullWidth));
    await tester.pumpAndSettle();

    expect(tester.getSize(firstOption).width, compactWidth);
    expect(find.widgetWithText(TextField, '选项 2'), findsOneWidget);
  });
}

class _AttachmentPickerHarness extends StatelessWidget {
  const _AttachmentPickerHarness();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: AttachmentPicker(
          height: 300,
          maxHeight: 500,
          roomId: '!room:example.org',
          onRefresh: (_) async {},
          resolveSendPresentation: () => MessageSendPresentation.quiet,
          onMessageSent: (_, _) {},
          onHeightChanged: (_) {},
          onClose: () {},
        ),
      ),
    );
  }
}

class _MessageInputHarness extends StatefulWidget {
  const _MessageInputHarness();

  @override
  State<_MessageInputHarness> createState() => _MessageInputHarnessState();
}

class _MessageInputHarnessState extends State<_MessageInputHarness> {
  InputPanelMode _panelMode = InputPanelMode.keyboard;

  @override
  Widget build(BuildContext context) {
    final pickerOpen =
        _panelMode == InputPanelMode.emoji ||
        _panelMode == InputPanelMode.attachment;
    return Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: double.infinity,
          child: MessageInput(
            roomId: '!room:example.org',
            totalMembers: 2,
            panelMode: _panelMode,
            pickerHeight: pickerOpen ? 300 : 0,
            pickerFullHeight: 300,
            pickerBaseHeight: 300,
            pickerMaxHeight: 500,
            animatePickerHeight: false,
            onPanelModeChanged: (mode) => setState(() => _panelMode = mode),
            onPickerHeightChanged: (_) {},
            resolveSendPresentation: () => MessageSendPresentation.quiet,
            onMessageQueued: (_, _) {},
            onMessageSent: (_, _) {},
          ),
        ),
      ),
    );
  }
}
