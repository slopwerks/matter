import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show Media;
import 'package:matter/features/audio/audio_source_cache.dart';
import 'package:matter/pages/chat/media_preparation.dart';
import 'package:matter/pages/chat/prepared_media_source.dart';

import 'support/temp_path_provider.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer upstream;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('matter-audio-cache-');
    installTempPathProvider(root);
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
  tearDown(() async {
    await upstream.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });
  String sourceUrl(String id) =>
      'http://127.0.0.1:${upstream.port}/_matrix/client/v1/media/download/example.org/$id';

  Future<List<int>> readSource(PreparedMediaSource source) async {
    final uri = source.media.uri;
    if (!uri.startsWith('http')) {
      return File(uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : uri)
          .readAsBytes();
    }
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(uri))).close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return await response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
    } finally {
      client.close(force: true);
    }
  }

  test('cache survives player disposal and a new cache instance for the same account', () async {
    var downloads = 0;
    upstream.listen((request) async {
      downloads++;
      request.response.contentLength = 4096;
      request.response.add(Uint8List(4096)..fillRange(0, 4096, 7));
      await request.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      final first = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      final a = await first.prepare(
        key: 'one',
        filename: 'one.ogg',
        preparation: MediaPreparation(),
        url: Uri.parse(sourceUrl('one')),
      );
      expect((await readSource(a)).length, 4096);
      expect(await a.waveformFile!(), isNotNull);
      await a.cleanup();
      await first.close();
      final second = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      final b = await second.prepare(
        key: 'one',
        filename: 'one.ogg',
        preparation: MediaPreparation(),
        url: Uri.parse(sourceUrl('one')),
      );
      expect((await readSource(b)).first, 7);
      expect(downloads, 1);
      await b.cleanup();
      await second.close();
    }, _RealHttp());
  });

  test(
    'capacity eviction never deletes a file with an active playback lease',
    () async {
      var downloads = 0;
      upstream.listen((request) async {
        downloads++;
        request.response.contentLength = 4096;
        request.response.add(Uint8List(4096));
        await request.response.close();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        final cache = AudioSourceCache(maxBytes: 1024)
          ..selectAccount('alice', 'https://example.org');
        final a = await cache.prepare(
          key: 'one',
          filename: 'one.ogg',
          preparation: MediaPreparation(),
          url: Uri.parse(sourceUrl('one')),
        );
        await readSource(a);
        final path = (await a.waveformFile!())!;
        final b = await cache.prepare(
          key: 'one',
          filename: 'one.ogg',
          preparation: MediaPreparation(),
          url: Uri.parse(sourceUrl('one')),
        );
        await a.cleanup();
        await cache.released;
        expect(await File(path).exists(), isTrue);
        expect(downloads, 1);
        await b.cleanup();
        await cache.released;
        expect(await File(path).exists(), isFalse);
        await cache.close();
      }, _RealHttp());
    },
  );

  test('account switches cannot reuse another account file and purge it after release', () async {
    var downloads = 0;
    upstream.listen((request) async {
      downloads++;
      request.response.contentLength = 4096;
      request.response.add(Uint8List(4096));
      await request.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      final cache = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      final a = await cache.prepare(
        key: 'shared',
        filename: 'one.ogg',
        preparation: MediaPreparation(),
        url: Uri.parse(sourceUrl('one')),
      );
      await readSource(a);
      final oldPath = (await a.waveformFile!())!;
      cache.selectAccount('bob', 'https://example.org');
      final b = await cache.prepare(
        key: 'shared',
        filename: 'one.ogg',
        preparation: MediaPreparation(),
        url: Uri.parse(sourceUrl('one')),
      );
      await readSource(b);
      await b.waveformFile!();
      expect(downloads, 2);
      expect(
        await File(oldPath).exists(),
        isTrue,
        reason: 'An old decoder lease must keep its file until it exits',
      );
      await a.cleanup();
      await cache.released;
      expect(await File(oldPath).exists(), isFalse);
      await b.cleanup();
      cache.selectAccount(null, null);
      await cache.released;
      await cache.close();
    }, _RealHttp());
  });

  test(
    'loopback serves ranges without forwarding bearer or Range to origin',
    () async {
      String? authorization;
      String? upstreamRange;
      upstream.listen((request) async {
        authorization = request.headers.value('authorization');
        upstreamRange = request.headers.value('range');
        request.response.contentLength = 4096;
        request.response.add(
          Uint8List.fromList(List.generate(4096, (i) => i % 256)),
        );
        await request.response.close();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        final cache = AudioSourceCache()
          ..selectAccount('alice', 'https://example.org');
        final source = await cache.prepare(
          key: 'one',
          filename: 'one.ogg',
          preparation: MediaPreparation(),
          url: Uri.parse(sourceUrl('one')),
          headers: {'Authorization': 'Bearer test-token'},
        );
        expect(source.media.uri, startsWith('http://127.0.0.1:'));
        expect(source.media.uri, isNot(contains('test-token')));
        expect(await source.waveformFile!(), isNotNull);
        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(source.media.uri));
          request.headers.set('Range', 'bytes=1024-1535');
          final response = await request.close();
          expect(response.statusCode, 206);
          expect(
            response.headers.value('content-range'),
            'bytes 1024-1535/4096',
          );
          final bytes = await response.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          );
          expect(bytes.length, 512);
          expect(bytes.first, 0);
          expect(bytes.last, 255);
        } finally {
          client.close(force: true);
        }
        expect(authorization, 'Bearer test-token');
        expect(upstreamRange, isNull);
        await source.cleanup();
        await cache.close();
      }, _RealHttp());
    },
  );

  test(
    'encrypted content is reusable only after the verified loader succeeds',
    () async {
      final cache = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      final verification = Completer<PreparedMediaSource>();
      var returned = false;
      var calls = 0;
      Future<PreparedMediaSource> verified(MediaPreparation preparation) {
        calls++;
        return verification.future;
      }

      final pending = cache
          .prepare(
            key: 'encrypted',
            filename: 'voice.ogg',
            preparation: MediaPreparation(),
            verifiedLoader: verified,
          )
          .then((value) {
            returned = true;
            return value;
          });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(returned, isFalse);
      final file = File('${root.path}/verified.ogg');
      await file.writeAsBytes([1, 2, 3]);
      verification.complete(
        PreparedMediaSource(
          media: Media(file.uri.toString()),
          cleanup: () async {},
        ),
      );
      final a = await pending;
      expect(await readSource(a), [1, 2, 3]);
      await a.cleanup();
      final b = await cache.prepare(
        key: 'encrypted',
        filename: 'voice.ogg',
        preparation: MediaPreparation(),
        verifiedLoader: verified,
      );
      expect(calls, 1);
      expect(await readSource(b), [1, 2, 3]);
      await b.cleanup();
      cache.selectAccount(null, null);
      await cache.released;
      await cache.close();
    },
  );

  test('corrupt persisted files are rejected and downloaded again', () async {
    var downloads = 0;
    upstream.listen((request) async {
      downloads++;
      request.response.contentLength = 4096;
      request.response.add(Uint8List(4096)..fillRange(0, 4096, 9));
      await request.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      final first = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      final a = await first.prepare(
        key: 'one',
        filename: 'one.ogg',
        preparation: MediaPreparation(),
        url: Uri.parse(sourceUrl('one')),
      );
      await readSource(a);
      final path = (await a.waveformFile!())!;
      await a.cleanup();
      await first.close();
      await File(path).writeAsBytes(Uint8List(4096)..fillRange(0, 4096, 3));
      final second = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      final b = await second.prepare(
        key: 'one',
        filename: 'one.ogg',
        preparation: MediaPreparation(),
        url: Uri.parse(sourceUrl('one')),
      );
      expect((await readSource(b)).first, 9);
      expect(downloads, 2);
      await b.cleanup();
      await second.close();
    }, _RealHttp());
  });

  test(
    'a failed encrypted verification is never published or reused',
    () async {
      final cache = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      var attempts = 0;
      Future<PreparedMediaSource> verified(MediaPreparation preparation) async {
        if (attempts++ == 0) throw StateError('Integrity check failed');
        final file = File('${root.path}/verified-retry.ogg');
        await file.writeAsBytes([4, 5, 6]);
        return PreparedMediaSource(
          media: Media(file.uri.toString()),
          cleanup: () async {},
        );
      }

      await expectLater(
        cache.prepare(
          key: 'encrypted',
          filename: 'voice.ogg',
          preparation: MediaPreparation(),
          verifiedLoader: verified,
        ),
        throwsStateError,
      );
      final source = await cache.prepare(
        key: 'encrypted',
        filename: 'voice.ogg',
        preparation: MediaPreparation(),
        verifiedLoader: verified,
      );
      expect(attempts, 2);
      expect(await readSource(source), [4, 5, 6]);
      await source.cleanup();
      cache.selectAccount(null, null);
      await cache.released;
      await cache.close();
    },
  );

  test(
    'one cancelled lease cannot abort another lease sharing a download',
    () async {
      final tail = Completer<void>();
      var downloads = 0;
      upstream.listen((request) async {
        downloads++;
        request.response.bufferOutput = false;
        request.response.contentLength = 8192;
        request.response.add(Uint8List(4096));
        await request.response.flush();
        await tail.future;
        try {
          request.response.add(Uint8List(4096));
          await request.response.close();
        } catch (_) {}
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        final cache = AudioSourceCache()
          ..selectAccount('alice', 'https://example.org');
        final p1 = MediaPreparation();
        final p2 = MediaPreparation();
        final sources = await Future.wait(
          [p1, p2].map(
            (p) => cache.prepare(
              key: 'shared',
              filename: 'voice.ogg',
              preparation: p,
              url: Uri.parse(sourceUrl('one')),
            ),
          ),
        );
        p1.cancel();
        await sources.first.cleanup();
        final reading = readSource(sources.last);
        tail.complete();
        try {
          expect((await reading).length, 8192);
          expect(downloads, 1);
        } finally {
          await sources.last.cleanup();
          await cache.close();
        }
      }, _RealHttp());
    },
  );

  test(
    'public CDN redirects work without leaking credentials to redirect targets',
    () async {
      final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final targets = <String?>[];
      cdn.listen((request) async {
        targets.add(request.headers.value('authorization'));
        request.response.contentLength = 4096;
        request.response.add(Uint8List(4096));
        await request.response.close();
      });
      upstream.listen((request) async {
        if (request.uri.path == '/public') {
          targets.add(request.headers.value('authorization'));
          await request.response.redirect(
            Uri.parse('http://127.0.0.1:${cdn.port}/audio.ogg'),
          );
        } else {
          await request.response.redirect(Uri.parse('/public'));
        }
      });
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          final cache = AudioSourceCache()
            ..selectAccount('alice', 'https://example.org');
          final source = await cache.prepare(
            key: 'one',
            filename: 'voice.ogg',
            preparation: MediaPreparation(),
            url: Uri.parse(sourceUrl('one')),
            headers: {'Authorization': 'Bearer test-token'},
          );
          try {
            expect((await readSource(source)).length, 4096);
            expect(targets, [null, null]);
          } finally {
            await source.cleanup();
            await cache.close();
          }
        }, _RealHttp());
      } finally {
        await cdn.close(force: true);
      }
    },
  );

  test('an account switch while preparation is queued cannot initialise a stale account', () async {
    var downloads = 0;
    upstream.listen((request) async {
      downloads++;
      request.response.contentLength = 4096;
      request.response.add(Uint8List(4096));
      await request.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      final cache = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      final rejected = expectLater(
        cache.prepare(
          key: 'one',
          filename: 'one.ogg',
          preparation: MediaPreparation(),
          url: Uri.parse(sourceUrl('one')),
        ),
        throwsStateError,
      );
      cache.selectAccount('bob', 'https://example.org');
      final source = await cache.prepare(
        key: 'one',
        filename: 'one.ogg',
        preparation: MediaPreparation(),
        url: Uri.parse(sourceUrl('one')),
      );
      try {
        await rejected;
        expect((await readSource(source)).length, 4096);
        expect(downloads, 1);
      } finally {
        await source.cleanup();
        cache.selectAccount(null, null);
        await cache.released;
        await cache.close();
      }
    }, _RealHttp());
  });

  test(
    'relogin never revives a file still retiring from the previous login',
    () async {
      var downloads = 0;
      upstream.listen((request) async {
        downloads++;
        request.response.contentLength = 4096;
        request.response.add(Uint8List(4096));
        await request.response.close();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        final cache = AudioSourceCache()
          ..selectAccount('alice', 'https://example.org');
        final old = await cache.prepare(
          key: 'one',
          filename: 'one.ogg',
          preparation: MediaPreparation(),
          url: Uri.parse(sourceUrl('one')),
        );
        await readSource(old);
        final oldPath = (await old.waveformFile!())!;
        cache.selectAccount(null, null);
        cache.selectAccount('alice', 'https://example.org');
        final fresh = await cache.prepare(
          key: 'one',
          filename: 'one.ogg',
          preparation: MediaPreparation(),
          url: Uri.parse(sourceUrl('one')),
        );
        await readSource(fresh);
        final newPath = (await fresh.waveformFile!())!;
        expect(downloads, 2);
        expect(newPath, isNot(oldPath));
        await old.cleanup();
        await cache.released;
        expect(await File(oldPath).exists(), isFalse);
        expect(await File(newPath).exists(), isTrue);
        await fresh.cleanup();
        cache.selectAccount(null, null);
        await cache.released;
        await cache.close();
      }, _RealHttp());
    },
  );
}
