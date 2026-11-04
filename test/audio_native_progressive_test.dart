import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:matter/features/audio/audio_source_cache.dart';
import 'package:matter/pages/chat/media_playback.dart';
import 'package:matter/pages/chat/media_preparation.dart';

import 'support/temp_path_provider.dart';

class _RealHttp extends HttpOverrides {}

Uint8List _wave() {
  const sampleRate = 16000;
  const samples = sampleRate * 20;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  bytes.setAll(0, 'RIFF'.codeUnits);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setAll(8, 'WAVEfmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setAll(36, 'data'.codeUnits);
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(44 + i * 2, i % 160 < 80 ? 8000 : -8000, Endian.little);
  }
  return bytes;
}

void main() {
  const enabled = bool.fromEnvironment('MATTER_NATIVE_AUDIO');
  test(
    'libmpv decodes progressive audio while the upstream tail is withheld',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'matter-native-audio-',
      );
      installTempPathProvider(root);
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final tail = Completer<void>();
      var eof = false;
      final bytes = _wave();
      upstream.listen((request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = bytes.length;
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(bytes.sublist(0, 44 + 16000 * 12 * 2));
        await request.response.flush();
        await tail.future;
        try {
          request.response.add(bytes.sublist(44 + 16000 * 12 * 2));
          await request.response.close();
          eof = true;
        } catch (_) {
          // The test may stop playback before the producer finishes.
        }
      });
      final cache = AudioSourceCache()
        ..selectAccount('alice', 'https://example.org');
      MediaKit.ensureInitialized();
      final player = Player();
      final playback = MediaPlayback(player: player);
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await native.setProperty('vo', 'null');
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          final source = await cache.prepare(
            key: 'native-wave',
            filename: 'voice.wav',
            preparation: MediaPreparation(),
            url: Uri.parse('http://127.0.0.1:${upstream.port}/voice.wav'),
          );
          try {
            final progressed = player.stream.position.firstWhere(
              (position) => position >= const Duration(milliseconds: 500),
            );
            await playback
                .open(source.media)
                .timeout(const Duration(seconds: 10));
            await playback.play();
            await progressed.timeout(const Duration(seconds: 10));
            expect(eof, isFalse);
            expect(playback.error, isNull);
          } finally {
            if (!tail.isCompleted) tail.complete();
            await playback.close();
            await source.cleanup();
          }
        }, _RealHttp());
      } finally {
        if (!tail.isCompleted) tail.complete();
        await playback.close();
        await cache.close();
        await upstream.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: !enabled,
  );
}
