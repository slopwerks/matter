import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/file_download_saver.dart';

const _fileSelectorChannel = MethodChannel('plugins.flutter.io/file_selector');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saves downloaded bytes to the selected desktop path', () async {
    final directory = await Directory.systemTemp.createTemp('matter-save-test');
    final destination = File('${directory.path}/report.pdf');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, (call) async {
          if (call.method == 'getSavePath') return destination.path;
          return null;
        });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_fileSelectorChannel, null);
      await directory.delete(recursive: true);
    });

    final saved = await saveDownloadedFile(
      filename: 'report.pdf',
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );

    expect(saved, isTrue);
    expect(await destination.readAsBytes(), <int>[1, 2, 3]);
  });

  test('does not write a file when the save dialog is cancelled', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, (call) async {
          if (call.method == 'getSavePath') return null;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_fileSelectorChannel, null),
    );

    expect(
      await saveDownloadedFile(
        filename: 'report.pdf',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      ),
      isFalse,
    );
  });
}
