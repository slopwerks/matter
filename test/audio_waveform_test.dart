import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/audio/audio_waveform.dart';
import 'package:matter/features/audio/audio_waveform_loader.dart';
import 'package:matter/pages/chat/media_preparation.dart';

Future<File> writeWaveformFixture(Directory root) async {
  const frames = 16000;
  final data = ByteData(44 + frames * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames * 2, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    final amplitude = frame < 8000 ? 0.1 : 0.8;
    data.setInt16(
      44 + frame * 2,
      (32767 * amplitude * math.sin(2 * math.pi * 125 * frame / 8000)).round(),
      Endian.little,
    );
  }
  return File('${root.path}/two-level.wav')
      .writeAsBytes(data.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PCM aggregation uses real samples across split-byte chunks', () {
    final data = ByteData(8)..setInt16(2, 32767, Endian.little);
    final bytes = data.buffer.asUint8List();
    final envelope = PcmWaveformEnvelope(2, 4);
    envelope.add(bytes.sublist(0, 3));
    envelope.add(bytes.sublist(3));
    expect(envelope.finish(), [1, 0]);
    final silent = PcmWaveformEnvelope(4, 8)..add(List.filled(16, 0));
    expect(silent.finish(), [0, 0, 0, 0]);
  });

  test(
    'desktop decoder extracts the amplitude change from an actual WAV file',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final root = await Directory.systemTemp.createTemp('matter-waveform-');
      addTearDown(() => root.delete(recursive: true));
      final file = await writeWaveformFixture(root);
      final points = await extractAudioWaveform(
        file.path,
        MediaPreparation(),
        sampleCount: 16,
      );
      expect(points, hasLength(16));
      expect(points.take(8).every((value) => value > 0 && value < 0.2), isTrue);
      expect(
        points.skip(8).every((value) => value > 0.9 && value <= 1),
        isTrue,
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'native extraction validates real envelopes and propagates cancellation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final root = await Directory.systemTemp.createTemp(
        'matter-waveform-native-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = await writeWaveformFixture(root);
      const channel = MethodChannel('moe.aks.matter/audio');
      final waiting = Completer<List<double>>();
      final started = Completer<void>();
      var cancelled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'waveform') {
              started.complete();
              return waiting.future;
            }
            if (call.method == 'cancelWaveform') {
              cancelled = true;
              waiting.complete([0.2, 1]);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final preparation = MediaPreparation();
      final pending = extractAudioWaveform(
        file.path,
        preparation,
        sampleCount: 2,
      );
      final failure = expectLater(pending, throwsStateError);
      await started.future;
      preparation.cancel();
      await failure;
      expect(cancelled, isTrue);
    },
  );

  testWidgets(
    'waveform seeks only on confirmed drag and cancels without seeking',
    (tester) async {
      final seeks = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: AudioWaveform(
                  samples: const [0, 0.1, 0.8, 1],
                  progress: 0.25,
                  color: Colors.blue,
                  onSeek: seeks.add,
                ),
              ),
            ),
          ),
        ),
      );
      final wave = find.byKey(const ValueKey('audio-waveform'));
      final origin = tester.getTopLeft(wave);
      await tester.tapAt(origin + const Offset(150, 16));
      await tester.pump();
      expect(seeks.single, closeTo(0.75, 0.01));
      seeks.clear();
      var gesture = await tester.startGesture(origin + const Offset(30, 16));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(70, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();
      expect(seeks, isEmpty);
      gesture = await tester.startGesture(origin + const Offset(30, 16));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(70, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(seeks.single, greaterThan(0.5));
      final painter =
          tester.widget<CustomPaint>(wave).painter! as AudioWaveformPainter;
      expect(painter.samples, [0, 0.1, 0.8, 1]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    },
  );
}
