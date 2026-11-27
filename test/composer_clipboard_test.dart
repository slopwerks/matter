import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_media_utils.dart';
import 'package:matter/pages/chat/composer_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pasteboard = MethodChannel('pasteboard');
  const native = MethodChannel('moe.aks.matter/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    directory = await Directory.systemTemp.createTemp('matter-clipboard-');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(pasteboard, null);
    messenger.setMockMethodCallHandler(native, null);
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  test('text clipboard falls through without attachments', () async {
    messenger.setMockMethodCallHandler(
      pasteboard,
      (call) async => call.method == 'files' ? <String>[] : null,
    );
    expect(await readClipboardAttachments(), isEmpty);
  });

  test(
    'file MIME uses signatures and preserves multiple copied files',
    () async {
      final image = File('${directory.path}/renamed.txt');
      await image.writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10]);
      final pdf = File('${directory.path}/document');
      await pdf.writeAsString('%PDF-1.7');
      messenger.setMockMethodCallHandler(pasteboard, (call) async {
        expect(call.method, 'files');
        return [image.uri.toString(), pdf.path, image.uri.toString()];
      });
      final files = await readClipboardAttachments();
      expect(files.map((file) => file.mimeType), [
        'image/png',
        'application/pdf',
      ]);
      expect(files.first.path, image.path);
    },
  );

  test('copied text file remains an attachment', () async {
    final text = File('${directory.path}/notes.txt');
    await text.writeAsString('notes');
    messenger.setMockMethodCallHandler(pasteboard, (_) async => [text.path]);
    final files = await readClipboardAttachments();
    expect(files.single.mimeType, 'text/plain');
  });

  test('directories are rejected instead of pasted as text', () async {
    messenger.setMockMethodCallHandler(
      pasteboard,
      (_) async => [directory.path],
    );
    expect(readClipboardAttachments(), throwsStateError);
  });

  test('oversized copied files are rejected before buffering', () async {
    final file = File('${directory.path}/large.bin');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(attachmentMaxBufferedBytes + 1);
    await handle.close();
    messenger.setMockMethodCallHandler(pasteboard, (_) async => [file.path]);
    expect(readClipboardAttachments(), throwsStateError);
  });

  test(
    'native read failures are surfaced rather than falling back to text',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(native, (_) async {
        throw PlatformException(code: 'clipboard_read_failed');
      });
      expect(readClipboardAttachments(), throwsA(isA<PlatformException>()));
    },
  );

  test(
    'native MIME is preserved ahead of a misleading filename extension',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(
        native,
        (_) async => [
          {
            'name': 'recording.txt',
            'mime': 'video/mp4',
            'bytes': Uint8List.fromList([1, 2, 3]),
          },
        ],
      );
      final files = await readClipboardAttachments();
      expect(files.single.mimeType, 'video/mp4');
    },
  );

  test('image clipboard still produces an image attachment', () async {
    messenger.setMockMethodCallHandler(
      pasteboard,
      (call) async => call.method == 'files'
          ? <String>[]
          : Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
    );
    final files = await readClipboardAttachments();
    expect(files.single.mimeType, 'image/png');
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      'native $platform payload preserves video MIME and file bytes',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        messenger.setMockMethodCallHandler(
          native,
          (call) async => [
            {
              'name': 'recording.mp4',
              'mime': 'video/mp4',
              'bytes': Uint8List.fromList([1, 2, 3]),
            },
            {
              'name': 'data.bin',
              'mime': 'application/octet-stream',
              'bytes': Uint8List.fromList([4]),
            },
          ],
        );
        final files = await readClipboardAttachments();
        expect(
          classifyAttachmentMime(files.first.mimeType),
          AttachmentMediaKind.video,
        );
        expect(await files.first.readAsBytes(), [1, 2, 3]);
        expect(
          classifyAttachmentMime(files.last.mimeType),
          AttachmentMediaKind.file,
        );
      },
    );
  }
}
