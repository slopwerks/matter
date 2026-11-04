import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../pages/chat/media_preparation.dart';

const _channel = MethodChannel('moe.aks.matter/audio');
int _nextWaveformJob = 0;

/// Real PCM RMS envelopes. Memory use is fixed by the requested bar count, not
/// the attachment's length. An unavailable decoder is an error, never fake bars.
Future<List<double>> extractAudioWaveform(
  String uri,
  MediaPreparation preparation, {
  int sampleCount = 160,
}) async {
  preparation.throwIfCancelled();
  if (sampleCount < 1 || sampleCount > 512) {
    throw ArgumentError.value(sampleCount);
  }
  final parsed = Uri.tryParse(uri);
  final path = parsed?.scheme == 'file' ? parsed!.toFilePath() : uri;
  if (!await File(path).exists()) {
    throw StateError('Waveform requires a local audio file');
  }
  preparation.throwIfCancelled();
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    final job = 'waveform-${_nextWaveformJob++}';
    final detach = preparation.onCancel(() {
      unawaited(
        _channel
            .invokeMethod<void>('cancelWaveform', {'jobId': job})
            .catchError((Object _) {}),
      );
    });
    try {
      final values = await _channel.invokeListMethod<num>('waveform', {
        'jobId': job,
        'path': path,
        'sampleCount': sampleCount,
      });
      preparation.throwIfCancelled();
      if (values == null ||
          values.isEmpty ||
          values.length > sampleCount ||
          values.any(
            (value) => !value.toDouble().isFinite || value < 0 || value > 1,
          )) {
        throw StateError('Invalid waveform data');
      }
      return values.map((value) => value.toDouble()).toList(growable: false);
    } finally {
      detach();
    }
  }

  final probe = await Process.start('ffprobe', [
    '-v',
    'error',
    '-show_entries',
    'format=duration',
    '-of',
    'default=noprint_wrappers=1:nokey=1',
    path,
  ]);
  var detach = preparation.onCancel(() => probe.kill(ProcessSignal.sigkill));
  double duration;
  try {
    final output = probe.stdout.transform(utf8.decoder).join();
    unawaited(probe.stderr.drain<void>());
    final result = await probe.exitCode.timeout(const Duration(seconds: 5));
    duration = double.tryParse((await output).trim()) ?? 0;
    if (result != 0 || !duration.isFinite || duration <= 0) {
      throw StateError('Missing audio duration');
    }
  } finally {
    detach();
    probe.kill(ProcessSignal.sigkill);
    await probe.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
  }
  preparation.throwIfCancelled();
  final process = await Process.start('ffmpeg', [
    '-nostdin',
    '-v',
    'error',
    '-threads',
    '1',
    '-i',
    path,
    '-vn',
    '-ac',
    '1',
    '-ar',
    '8000',
    '-f',
    's16le',
    'pipe:1',
  ]);
  detach = preparation.onCancel(() => process.kill(ProcessSignal.sigkill));
  final deadline = Timer(
    const Duration(seconds: 45),
    () => process.kill(ProcessSignal.sigkill),
  );
  final envelope = PcmWaveformEnvelope(sampleCount, (duration * 8000).round());
  try {
    unawaited(process.stderr.drain<void>());
    await for (final chunk in process.stdout) {
      preparation.throwIfCancelled();
      envelope.add(chunk);
    }
    if (await process.exitCode != 0) throw StateError('Audio decoding failed');
    preparation.throwIfCancelled();
    return envelope.finish();
  } finally {
    deadline.cancel();
    detach();
    process.kill(ProcessSignal.sigkill);
    await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
  }
}

/// Incremental signed little-endian PCM16 aggregator, including split samples.
class PcmWaveformEnvelope {
  final int totalFrames;
  final List<double> _energy;
  final List<int> _counts;
  int _frame = 0;
  int? _lowByte;

  PcmWaveformEnvelope(int samples, this.totalFrames)
    : _energy = List.filled(samples, 0),
      _counts = List.filled(samples, 0) {
    if (samples < 1 || totalFrames < 1) {
      throw ArgumentError('Invalid PCM shape');
    }
  }

  void add(List<int> chunk) {
    for (final byte in chunk) {
      if (_lowByte == null) {
        _lowByte = byte;
      } else {
        var value = _lowByte! | (byte << 8);
        if (value >= 32768) value -= 65536;
        final bucket = math.min(
          _energy.length - 1,
          _frame * _energy.length ~/ totalFrames,
        );
        _energy[bucket] += (value / 32768) * (value / 32768);
        _counts[bucket]++;
        _frame++;
        _lowByte = null;
      }
    }
  }

  List<double> finish() {
    if (_frame == 0) throw StateError('No decoded audio samples');
    final rms = List.generate(
      _energy.length,
      (i) => _counts[i] == 0 ? 0.0 : math.sqrt(_energy[i] / _counts[i]),
    );
    final maximum = rms.reduce(math.max);
    return maximum == 0
        ? rms
        : rms.map((value) => value / maximum).toList(growable: false);
  }
}
