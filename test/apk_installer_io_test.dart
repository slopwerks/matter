import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/app_update/apk_installer_io.dart';
import 'package:matter/features/app_update/update_exception.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final previousHttpOverrides = HttpOverrides.current;
  late Directory temporaryDirectory;
  late HttpServer server;
  var requests = 0;
  List<int>? servedBytes;
  var stallBody = false;

  setUp(() async {
    HttpOverrides.global = null;
    requests = 0;
    stallBody = false;
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'matter_update_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getTemporaryDirectory') {
            return temporaryDirectory.path;
          }
          return null;
        });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests++;
      final bytes = servedBytes;
      if (bytes == null) {
        request.response.statusCode = HttpStatus.internalServerError;
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..bufferOutput = false
          ..contentLength = stallBody ? bytes.length * 2 : bytes.length
          ..add(bytes);
      }
      if (stallBody) {
        unawaited(request.response.flush());
        return;
      }
      request.response.close();
    });
  });

  tearDown(() async {
    HttpOverrides.global = previousHttpOverrides;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await server.close(force: true);
    await temporaryDirectory.delete(recursive: true);
    servedBytes = null;
  });

  test('reuses a verified cached APK without downloading it again', () async {
    final bytes = <int>[1, 2, 3, 4, 5];
    final updateDirectory = Directory('${temporaryDirectory.path}/updates');
    await updateDirectory.create();
    final cachedApk = File('${updateDirectory.path}/matter.apk');
    await cachedApk.writeAsBytes(bytes);

    final path = await downloadAndroidApk(
      uri: Uri.parse(
        'http://${server.address.address}:${server.port}/matter.apk',
      ),
      fileName: 'matter.apk',
      expectedSize: bytes.length,
      digest: 'sha256:${sha256.convert(bytes)}',
      onProgress: (_, _) {},
    );

    expect(path, cachedApk.path);
    expect(requests, 0);
  });

  test('redownloads when the cached APK size does not match', () async {
    final updateDirectory = Directory('${temporaryDirectory.path}/updates');
    await updateDirectory.create();
    final cachedApk = File('${updateDirectory.path}/matter.apk');
    await cachedApk.writeAsBytes(<int>[1, 2, 3]);

    final bytes = <int>[1, 2, 3, 4, 5];
    servedBytes = bytes;

    final path = await downloadAndroidApk(
      uri: Uri.parse(
        'http://${server.address.address}:${server.port}/matter.apk',
      ),
      fileName: 'matter.apk',
      expectedSize: bytes.length,
      digest: 'sha256:${sha256.convert(bytes)}',
      onProgress: (_, _) {},
    );

    expect(requests, 1);
    expect(path, cachedApk.path);
    expect(await cachedApk.readAsBytes(), bytes);
  });

  test('redownloads when the cached APK digest does not match', () async {
    final updateDirectory = Directory('${temporaryDirectory.path}/updates');
    await updateDirectory.create();
    final cachedApk = File('${updateDirectory.path}/matter.apk');
    await cachedApk.writeAsBytes(<int>[9, 9, 9, 9, 9]);

    final bytes = <int>[1, 2, 3, 4, 5];
    servedBytes = bytes;

    final path = await downloadAndroidApk(
      uri: Uri.parse(
        'http://${server.address.address}:${server.port}/matter.apk',
      ),
      fileName: 'matter.apk',
      expectedSize: bytes.length,
      digest: 'sha256:${sha256.convert(bytes)}',
      onProgress: (_, _) {},
    );

    expect(requests, 1);
    expect(path, cachedApk.path);
    expect(await cachedApk.readAsBytes(), bytes);
  });

  test(
    'a stalled response body times out and removes the partial APK',
    () async {
      servedBytes = List.filled(32768, 1);
      stallBody = true;
      final started = Completer<void>();
      final download = downloadAndroidApk(
        uri: Uri.parse('http://127.0.0.1:${server.port}/matter.apk'),
        fileName: 'matter.apk',
        expectedSize: 65536,
        digest: null,
        onProgress: (_, _) {
          if (!started.isCompleted) started.complete();
        },
      );
      final expectation = expectLater(
        download,
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            contains('下载超时'),
          ),
        ),
      );
      await started.future.timeout(const Duration(seconds: 5));
      await expectation;
      expect(
        await File(
          '${temporaryDirectory.path}/updates/matter.apk.download',
        ).exists(),
        isFalse,
      );
      expect(
        await File('${temporaryDirectory.path}/updates/matter.apk').exists(),
        isFalse,
      );
    },
  );

  test(
    'cancelling a response body cleans up and permits a fresh download',
    () async {
      servedBytes = List.filled(32768, 1);
      stallBody = true;
      final cancel = Completer<void>();
      final started = Completer<void>();
      final uri = Uri.parse('http://127.0.0.1:${server.port}/matter.apk');
      final download = downloadAndroidApk(
        uri: uri,
        fileName: 'matter.apk',
        expectedSize: 65536,
        digest: null,
        cancel: cancel.future,
        onProgress: (_, _) {
          if (!started.isCompleted) started.complete();
        },
      );
      final expectation = expectLater(
        download,
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.message,
            'message',
            '下载已取消',
          ),
        ),
      );
      await started.future.timeout(const Duration(seconds: 5));
      cancel.complete();
      await expectation;
      expect(
        await File(
          '${temporaryDirectory.path}/updates/matter.apk.download',
        ).exists(),
        isFalse,
      );
      stallBody = false;
      final path = await downloadAndroidApk(
        uri: uri,
        fileName: 'matter.apk',
        expectedSize: servedBytes!.length,
        digest: null,
        onProgress: (_, _) {},
      );
      expect(await File(path).readAsBytes(), servedBytes);
    },
  );
}
