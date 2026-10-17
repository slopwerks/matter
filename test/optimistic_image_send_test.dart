import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' show ImageMessageMetadata;
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';

late Uint8List _pixel;

class _ImageApi implements RustLibApi {
  final calls = <({String filename, List<int> bytes})>[];
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
    calls.add((filename: filename, bytes: List.of(imageData)));
    await pendingUpload?.future;
    return '\$image-${calls.length}:example.org';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Renders the room's optimistic rows above the picker, so a queued image is
/// observable while its upload is still in flight.
class _Harness extends StatelessWidget {
  const _Harness();

  @override
  Widget build(BuildContext context) => ProviderScope(
    child: MaterialApp(
      theme: neuTestTheme(),
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Consumer(
                builder: (context, ref, _) => _LocalOutgoingRows(
                  rows: ref.watch(
                    localOutgoingMessagesProvider((
                      roomId: '!room:example.org',
                      userId: '@alice:example.org',
                    )),
                  ),
                ),
              ),
            ),
            AttachmentPicker(
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
              onClose: () {},
            ),
          ],
        ),
      ),
    ),
  );
}

class _LocalOutgoingRows extends StatelessWidget {
  final List<LocalOutgoingMessage> rows;

  const _LocalOutgoingRows({required this.rows});

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      for (final row in rows)
        Text(
          '${row.message.id}|${row.message.filename}'
          '|${row.localImageBytes?.length}',
        ),
    ],
  );
}

/// Returns everything the optimistic rows currently render, joined.
String _rowsText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((widget) => widget.data)
    .whereType<String>()
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ImageApi api;
  late Directory temp;
  const channel = MethodChannel('plugins.flutter.io/file_selector');

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

  setUp(() async {
    api = _ImageApi();
    RustLib.initMock(api: api);
    temp = await Directory.systemTemp.createTemp('matter-optimistic-image-');
    final path = '${temp.path}/holiday.png';
    await File(path).writeAsBytes(_pixel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => [path]);
  });

  tearDown(() async {
    RustLib.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  /// Picks the single prepared image into the draft and waits for the send
  /// button to appear. `photo_manager` is unavailable on the test host, so the
  /// picker takes its `file_selector` fallback path.
  Future<void> pickImage(WidgetTester tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片 / 视频'));
    await tester.pumpAndSettle();
    for (var index = 0; index < 40; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byTooltip('发送 1 项').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(find.byTooltip('发送 1 项'), findsOneWidget);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var index = 0; index < 40; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pressSend(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('attachment-send-button')));
    for (var index = 0; index < 100 && api.calls.isEmpty; index++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(api.calls, hasLength(1));
  }

  testWidgets('paints the image bubble before the upload finishes', (
    tester,
  ) async {
    await pickImage(tester);
    // Hold the upload open: no server event exists yet at any point below.
    api.pendingUpload = Completer<void>();
    await pressSend(tester);
    await settle(tester);

    expect(api.pendingUpload!.isCompleted, isFalse);
    expect(api.calls.single.bytes, hasLength(_pixel.length));

    final pending = _rowsText(tester);
    expect(pending, contains('local_outgoing_pending:'));
    // The bubble has the picked file's bytes and declared metadata, so it can
    // render before any `mxc://` source exists.
    expect(pending, contains('|holiday.png|${_pixel.length}'));

    api.pendingUpload!.complete();
    await settle(tester);

    // The accepted row is renamed to `sent:` and keeps its preview bytes, so
    // the bubble does not flash while the echo is fetched.
    final sent = _rowsText(tester);
    expect(sent, contains('local_outgoing_sent:'));
    expect(sent, contains('|holiday.png|${_pixel.length}'));
  });
}
