import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_playback_session.dart';

/// Native notifications receive display metadata only, never media URLs, keys
/// or access tokens. All commands route back to the same Dart playback owner.
class AudioSystemControls {
  static const channel = MethodChannel('moe.aks.matter/audio');
  final AudioPlaybackSession session;
  Timer? _timer;
  bool _disposed = false;
  (int, bool, bool, String?)? _lastState;

  AudioSystemControls(this.session) {
    channel.setMethodCallHandler(handleCommand);
    session.addListener(_changed);
    _changed();
  }

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _changed() {
    if (_disposed || !supported) return;
    // Position events may arrive at frame rate. Native sessions extrapolate
    // between these bounded metadata updates.
    final state = (
      session.revision,
      session.isPlaying,
      session.loading,
      session.current?.id,
    );
    if (state != _lastState) {
      _lastState = state;
      _timer?.cancel();
      _timer = null;
      unawaited(_publish());
    } else {
      _timer ??= Timer(const Duration(milliseconds: 150), () {
        _timer = null;
        unawaited(_publish());
      });
    }
  }

  Future<void> _publish() async {
    if (_disposed) return;
    final current = session.current;
    try {
      await channel.invokeMethod<void>('update', {
        'generation': session.revision,
        'title': current?.filename,
        'playing': session.isPlaying,
        'loading': session.loading,
        'positionMs': session.position.inMilliseconds,
        'durationMs': session.duration.inMilliseconds,
        'speed': session.speed,
        'hasNext': session.hasNext,
        'hasPrevious': session.hasPrevious,
      });
      if (current == null) {
        final revision = session.revision;
        await session.released;
        if (!_disposed &&
            session.current == null &&
            session.revision == revision) {
          await channel.invokeMethod<void>('release', {'generation': revision});
        }
      }
    } on MissingPluginException {
      // Desktop and widget tests use the same session without native controls.
    } on PlatformException {
      // Playback remains usable; the failure is visible via app diagnostics.
      debugPrint('System audio controls unavailable');
    }
  }

  Future<void> handleCommand(MethodCall call) async {
    final arguments = call.arguments;
    if (_disposed ||
        arguments is! Map ||
        arguments['generation'] != session.revision) {
      return;
    }
    switch (call.method) {
      case 'play':
        await session.play();
      case 'pause':
        await session.pause();
      case 'stop':
        await session.stop();
      case 'next':
        await session.next();
      case 'previous':
        await session.previous();
      case 'seek':
        final position = arguments['positionMs'];
        if (position is num) {
          await session.seek(Duration(milliseconds: position.toInt()));
        }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    session.removeListener(_changed);
    channel.setMethodCallHandler(null);
    if (supported) {
      unawaited(channel.invokeMethod<void>('stop').catchError((Object _) {}));
    }
  }
}
