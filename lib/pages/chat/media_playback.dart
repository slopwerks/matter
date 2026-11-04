import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Shared playback state for the bubble and its fullscreen preview.
class MediaPlayback extends ChangeNotifier {
  final Player player;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  String? error;
  bool _closed = false;
  Future<void>? _closing;
  Duration? _declaredDuration;
  Duration? _confirmedDuration;
  bool _progressive = false;

  MediaPlayback({Player? player}) : player = player ?? Player() {
    for (final stream in <Stream<dynamic>>[
      this.player.stream.playing,
      this.player.stream.position,
      this.player.stream.duration,
      this.player.stream.buffer,
      this.player.stream.volume,
      this.player.stream.rate,
      this.player.stream.width,
      this.player.stream.height,
    ]) {
      _subscriptions.add(stream.listen((_) => _changed()));
    }
    _subscriptions.add(
      this.player.stream.completed.listen((completed) {
        if (completed &&
            _progressive &&
            error == null &&
            this.player.state.duration > Duration.zero) {
          _confirmedDuration = this.player.state.duration;
        }
        _changed();
      }),
    );
    _subscriptions.add(
      this.player.stream.error.listen((message) {
        error = message;
        _changed();
      }),
    );
  }

  bool get isPlaying => player.state.playing;
  bool get isCompleted => player.state.completed;
  bool get isClosed => _closed;
  double get rate => player.state.rate;
  Duration get position => player.state.position;
  Duration get duration {
    final value =
        _declaredDuration ??
        (_progressive
            ? _confirmedDuration ?? Duration.zero
            : player.state.duration);
    return value > Duration.zero ? value : Duration.zero;
  }

  void setDurationMetadata(int? milliseconds) {
    _declaredDuration =
        milliseconds != null && milliseconds > 0 && milliseconds <= 0x7fffffff
        ? Duration(milliseconds: milliseconds)
        : null;
    _changed();
  }

  Duration get buffer => player.state.buffer;
  double get volume => (player.state.volume / 100).clamp(0, 1);
  double get aspectRatio {
    final width = player.state.width ?? 0;
    final height = player.state.height ?? 0;
    return width > 0 && height > 0 ? width / height : 16 / 9;
  }

  Future<void> open(Media media, {int? durationMs}) {
    _progressive = ['http', 'https'].contains(Uri.tryParse(media.uri)?.scheme);
    _confirmedDuration = null;
    setDurationMetadata(durationMs);
    return player.open(media, play: false);
  }

  Future<void> play() async {
    if (player.state.completed) await player.seek(Duration.zero);
    await player.play();
  }

  Future<void> pause() => player.pause();
  Future<void> seek(Duration position) => player.seek(position);
  Future<void> setVolume(double volume) =>
      player.setVolume(volume.clamp(0, 1) * 100);
  Future<void> setRate(double rate) => player.setRate(rate);

  Future<void> seekRelative(Duration offset) {
    if (duration <= Duration.zero) return Future.value();
    final target = (position.inMilliseconds + offset.inMilliseconds).clamp(
      0,
      duration.inMilliseconds,
    );
    return seek(Duration(milliseconds: target));
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  /// Finish native teardown before the owner removes its temporary media file.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await player.dispose();
    } finally {
      super.dispose();
    }
  }
}
