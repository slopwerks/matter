import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/file_download_saver.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/temp_path_provider.dart';

const _fileSelectorChannel = MethodChannel('plugins.flutter.io/file_selector');

class _DownloadPaths extends TempPathProvider {
  _DownloadPaths(super.root);

  @override
  Future<String?> getDownloadsPath() async => '${root.path}/Downloads';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late int dialogs;
  String? selectedPath;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('matter-save-test');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _DownloadPaths(directory);
    addTearDown(() => PathProviderPlatform.instance = previous);
    dialogs = 0;
    selectedPath = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, (call) async {
          dialogs++;
          return call.method == 'getSavePath' ? selectedPath : null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_fileSelectorChannel, null);
    await directory.delete(recursive: true);
  });

  test(
    'Save As cancellation creates no file and no Downloads folder',
    () async {
      expect(
        await saveDownloadedFile(
          filename: 'report.pdf',
          bytes: Uint8List.fromList([1]),
          chooseLocation: true,
        ),
        isFalse,
      );
      expect(dialogs, 1);
      expect(await directory.list().isEmpty, isTrue);
    },
  );

  test(
    'Save As writes exactly the chosen path, including confirmed overwrite',
    () async {
      selectedPath = '${directory.path}/renamed.pdf';
      await File(selectedPath!).writeAsBytes([9]);
      expect(
        await saveDownloadedFile(
          filename: 'report.pdf',
          bytes: Uint8List.fromList([1, 2]),
          chooseLocation: true,
        ),
        isTrue,
      );
      expect(await File(selectedPath!).readAsBytes(), [1, 2]);
      expect(await Directory('${directory.path}/Downloads').exists(), isFalse);
      expect(dialogs, 1);
    },
  );

  test(
    'Save As reports write errors without falling back to Downloads',
    () async {
      selectedPath = '${directory.path}/missing/renamed.pdf';
      await expectLater(
        saveDownloadedFile(
          filename: 'report.pdf',
          bytes: Uint8List.fromList([1]),
          chooseLocation: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await Directory('${directory.path}/Downloads').exists(), isFalse);
    },
  );

  test('saves straight to Downloads without a location picker', () async {
    expect(
      await saveDownloadedFile(
        filename: 'report.pdf',
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
      isTrue,
    );
    expect(await File('${directory.path}/Downloads/report.pdf').readAsBytes(), [
      1,
      2,
      3,
    ]);
    expect(dialogs, 0);
  });

  test('keeps existing files and names new copies with a suffix', () async {
    final downloads = Directory('${directory.path}/Downloads');
    await downloads.create();
    await File('${downloads.path}/report.pdf').writeAsBytes([9]);
    await saveDownloadedFile(
      filename: 'report.pdf',
      bytes: Uint8List.fromList([1]),
    );
    await saveDownloadedFile(
      filename: 'report.pdf',
      bytes: Uint8List.fromList([2]),
    );
    expect(await File('${downloads.path}/report.pdf').readAsBytes(), [9]);
    expect(await File('${downloads.path}/report (1).pdf').readAsBytes(), [1]);
    expect(await File('${downloads.path}/report (2).pdf').readAsBytes(), [2]);
    expect(dialogs, 0);
  });

  test('simultaneous downloads never overwrite one another', () async {
    await Future.wait([
      for (var i = 0; i < 3; i++)
        saveDownloadedFile(filename: 'README', bytes: Uint8List.fromList([i])),
    ]);
    final files = await Directory('${directory.path}/Downloads')
        .list()
        .toList();
    expect(files.length, 3);
    final contents = await Future.wait(
      files.map((file) => File(file.path).readAsBytes()),
    );
    expect(contents.map((bytes) => bytes.single).toSet(), {0, 1, 2});
  });
}
