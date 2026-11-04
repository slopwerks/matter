import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show Media, Playable, Player;
import 'package:matter/features/audio/audio_playback_session.dart';
import 'package:matter/features/audio/audio_track.dart';
import 'package:matter/pages/chat/media_playback.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_path_provider.dart';
import 'support/video_test_player.dart';

class _RealHttp extends HttpOverrides {}

class _ReadablePlayer extends VideoTestPlayer {
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final uri = (playable as Media).uri;
    if (uri.startsWith('http://') || uri.startsWith('https://')) {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(uri));
        final response = await request.close();
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw HttpException('Playback HTTP ${response.statusCode}');
        }
        final first = await response.first;
        if (first.isEmpty) throw StateError('No playable bytes');
      } finally {
        client.close(force: true);
      }
    } else {
      final file = File(
        uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : uri,
      );
      final handle = await file.open();
      try {
        if ((await handle.read(4)).isEmpty) {
          throw StateError('No playable bytes');
        }
      } finally {
        await handle.close();
      }
    }
    state = state.copyWith(playing: false, position: Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer upstream;
  late AudioPlaybackSession session;
  late Completer<void> cacheReady;
  setUp(() async {
    cacheReady = Completer<void>();
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('matter-audio-latency-');
    installTempPathProvider(root);
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    session =
        AudioPlaybackSession(
          createPlayer: () =>
              MediaPlayback(player: Player(platformPlayer: _ReadablePlayer())),
          waveformLoader: (_, preparation) async {
            // The session awaits waveformFile (including cache finalization)
            // before invoking this loader, even while playback starts early.
            if (!cacheReady.isCompleted) cacheReady.complete();
            return const [];
          },
        )..setAccount(
          AudioAccount(
            '@alice:example.org',
            'http://127.0.0.1:${upstream.port}',
            'test-token',
          ),
        );
  });
  tearDown(() async {
    await session.close();
    await upstream.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });
  AudioTrack track(String id) => AudioTrack(
    id: id,
    filename: '$id.ogg',
    url:
        'http://127.0.0.1:${upstream.port}/_matrix/client/v1/media/download/example.org/$id',
    mediaSourceJson: null,
  );

  test('plain audio opens with readable bytes before upstream EOF', () async {
    final firstBytes = Completer<void>();
    final tail = Completer<void>();
    addTearDown(() {
      if (!tail.isCompleted) tail.complete();
    });
    upstream.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 8192;
      request.response.headers.contentType = ContentType('audio', 'ogg');
      request.response.add(Uint8List(4096)..setAll(0, [79, 103, 103, 83]));
      await request.response.flush();
      firstBytes.complete();
      await tail.future;
      request.response.add(Uint8List(4096));
      await request.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      final pending = session.playTrack(track('one'));
      await firstBytes.future.timeout(const Duration(seconds: 5));
      final elapsed = Stopwatch()..start();
      while (!session.isPlaying &&
          elapsed.elapsed < const Duration(milliseconds: 500)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final startedBeforeEof = session.isPlaying;
      tail.complete();
      await pending.timeout(const Duration(seconds: 5));
      expect(
        startedBeforeEof,
        isTrue,
        reason: 'Readable audio must reach the player before the entire download ends',
      );
    }, _RealHttp());
  });

  test(
    'failed HTTP downloads are not cached and retry fetches fresh data',
    () async {
      var downloads = 0;
      upstream.listen((request) async {
        downloads++;
        if (downloads == 1) {
          request.response.statusCode = 503;
        } else {
          request.response.contentLength = 4096;
          request.response.add(Uint8List(4096));
        }
        await request.response.close();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        await session.playTrack(track('one'));
        expect(session.error, isNotNull);
        await session.playTrack(track('one'));
        expect(session.isPlaying, isTrue);
        expect(downloads, 2);
      }, _RealHttp());
    },
  );

  test(
    'chunked origins can play before EOF without a fabricated Content-Length',
    () async {
      final tail = Completer<void>();
      upstream.listen((request) async {
        request.response.bufferOutput = false;
        request.response.add(Uint8List(4096));
        await request.response.flush();
        await tail.future;
        try {
          request.response.add(Uint8List(4096));
          await request.response.close();
        } catch (_) {}
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        var opened = false;
        final pending = session
            .playTrack(track('one'))
            .then((_) => opened = session.isPlaying);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final beforeEof = opened;
        tail.complete();
        await pending;
        expect(beforeEof, isTrue);
      }, _RealHttp());
    },
  );

  for (final tailDelay in [Duration.zero, const Duration(milliseconds: 250)]) {
    test(
      'switching A to B to A reuses A instead of downloading it twice tailDelay=$tailDelay',
      () async {
        final counts = <String, int>{};
        upstream.listen((request) async {
          final path = request.uri.path;
          counts[path] = (counts[path] ?? 0) + 1;
          request.response.bufferOutput = false;
          request.response.contentLength = 8192;
          request.response.headers.contentType = ContentType('audio', 'ogg');
          request.response.add(Uint8List(4096)..setAll(0, [79, 103, 103, 83]));
          await request.response.flush();
          await Future<void>.delayed(tailDelay);
          try {
            request.response.add(Uint8List(4096));
            await request.response.close();
          } catch (_) {
            // Switching before completion may cancel this response.
          }
        });
        await HttpOverrides.runWithHttpOverrides(() async {
          final a = track('one');
          await session.playTrack(a);
          await cacheReady.future.timeout(const Duration(seconds: 5));
          await session.playTrack(track('two'));
          await session.playTrack(a);
          expect(
            counts[Uri.parse(a.url!).path],
            1,
            reason:
                'A completed account-scoped file must survive switching away',
          );
        }, _RealHttp());
      },
    );
  }
}
