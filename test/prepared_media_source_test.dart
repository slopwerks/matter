import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matter/pages/chat/prepared_media_source.dart';

import 'support/temp_path_provider.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('matter-media-test-');
    installTempPathProvider(root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'decrypted audio and video have independent files and safe extensions',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final audio = await prepareDecryptedMediaSource(
        bytes,
        '../../voice.opus',
      );
      final video = await prepareDecryptedMediaSource(bytes, 'clip.mp4');
      final unsafe = await prepareDecryptedMediaSource(bytes, 'video.bad/path');
      final audioFile = File(audio.media.uri);
      final videoFile = File(video.media.uri);
      expect(audioFile.path, endsWith('.opus'));
      expect(File(unsafe.media.uri).path, endsWith('.bin'));
      expect(await audioFile.readAsBytes(), bytes);
      expect(await videoFile.readAsBytes(), bytes);
      await audio.cleanup();
      await audio.cleanup();
      expect(await audioFile.exists(), isFalse);
      expect(await videoFile.exists(), isTrue);
      await cleanupStaleMediaSources();
      expect(await videoFile.exists(), isFalse);
    },
  );

  test('streams authenticated media without Range support or a 16 MB cap', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const chunkSize = 1024 * 1024;
    const chunkCount = 17;
    final chunk = Uint8List(chunkSize)..fillRange(0, chunkSize, 7);
    String? authorization;
    String? range;
    server.listen((request) async {
      authorization = request.headers.value(HttpHeaders.authorizationHeader);
      range = request.headers.value(HttpHeaders.rangeHeader);
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.set('content-disposition', 'attachment');
      for (var i = 0; i < chunkCount; i++) {
        request.response.add(chunk);
        await request.response.flush();
      }
      await request.response.close();
    });
    final source = await HttpOverrides.runWithHttpOverrides(
      () => prepareRemoteMediaSource(
        Uri.parse(
          'http://127.0.0.1:${server.port}/_matrix/client/v1/media/download/example.org/clip',
        ),
        'clip.mp4',
        httpHeaders: {'Authorization': 'Bearer test-token'},
      ),
      _RealHttp(),
    );
    expect(authorization, 'Bearer test-token');
    expect(range, isNull);
    final file = File(source.media.uri);
    expect(await file.length(), chunkSize * chunkCount);
    final handle = await file.open();
    await handle.setPosition(chunkSize * (chunkCount - 1));
    expect(await handle.read(4), [7, 7, 7, 7]);
    await handle.close();
    await source.cleanup();
    expect(await file.exists(), isFalse);
  });

  test('failed HTTP responses leave no partial media files', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    });
    await expectLater(
      HttpOverrides.runWithHttpOverrides(
        () => prepareRemoteMediaSource(
          Uri.parse('http://127.0.0.1:${server.port}/media'),
          'video.mp4',
        ),
        _RealHttp(),
      ),
      throwsA(isA<http.ClientException>()),
    );
    final cache = Directory('${root.path}/matter_decrypted_media');
    expect(await cache.list().toList(), isEmpty);
  });
}
