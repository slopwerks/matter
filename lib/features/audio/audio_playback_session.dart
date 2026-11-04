import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../pages/chat/media_playback.dart';
import '../../pages/chat/media_preparation.dart';
import '../../pages/chat/prepared_media_source.dart';
import 'audio_track.dart';
import 'audio_waveform_loader.dart';
import 'audio_source_cache.dart';

typedef AudioSourceLoader = Future<PreparedMediaSource> Function(
  AudioTrack track,
  AudioAccount account,
  MediaPreparation preparation,
);

/// The sole owner of chat audio. Widgets and platform controls are clients;
/// disposing a message bubble must never dispose this playback session.
class AudioPlaybackSession extends ChangeNotifier {
  final AudioSourceLoader? _load;
  final AudioSourceCache _fileCache;
  final Set<Future<void>> _retiring = {};
  final MediaPlayback Function() _createPlayer;
  final Future<List<double>> Function(String, MediaPreparation)
  _extractWaveform;
  final Map<String, List<double>> _waveforms = {};
  Future<void> _waveformWork = Future.value();
  final List<AudioTrack> _tracks = [];
  final Set<Future<void>> _preparing = {};
  AudioAccount? _account;
  MediaPlayback? _player;
  PreparedMediaSource? _source;
  MediaPreparation? _preparation;
  Future<void> _releasing = Future.value();
  int _generation = 0;
  int _index = -1;
  bool _disposed = false;
  bool loading = false;
  bool _wantPlay = false;
  bool _speedEdited = false;
  int _nextTrackId = 0;
  String? error;
  double speed = 1;
  double volume = 1;
  static const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  AudioPlaybackSession({
    this._load,
    MediaPlayback Function()? createPlayer,
    Future<List<double>> Function(String, MediaPreparation)? waveformLoader,
    AudioSourceCache? sourceCache,
  }) : _fileCache = sourceCache ?? AudioSourceCache(),
       _createPlayer = createPlayer ?? MediaPlayback.new,
       _extractWaveform = waveformLoader ?? extractAudioWaveform;

  List<AudioTrack> get tracks => List.unmodifiable(_tracks);
  List<double>? waveformFor(String trackId) => _waveforms[trackId];
  int get index => _index;
  AudioTrack? get current =>
      _index >= 0 && _index < _tracks.length ? _tracks[_index] : null;
  MediaPlayback? get player => _player;
  bool get isPlaying => _player?.isPlaying ?? false;
  bool get isCompleted => _player?.isCompleted ?? false;
  Duration get position => _player?.position ?? Duration.zero;
  Duration get duration =>
      _player?.duration ??
      (current?.durationMs != null &&
              current!.durationMs! > 0 &&
              current!.durationMs! <= 0x7fffffff
          ? Duration(milliseconds: current!.durationMs!)
          : Duration.zero);
  int get revision => _generation;
  Future<void> get released async {
    await Future.wait<void>([_releasing, ..._preparing, ..._retiring]);
    if (_load == null) await _fileCache.released;
  }

  bool get hasPrevious => _index > 0;
  bool get hasNext => _index >= 0 && _index + 1 < _tracks.length;

  Future<void> restorePreferences() async {
    final preferences = await SharedPreferences.getInstance();
    if (_disposed || _speedEdited) return;
    final saved = preferences.getDouble('audio_playback_speed');
    if (speeds.contains(saved)) {
      speed = saved!;
      await _player?.setRate(speed);
    }
    _changed();
  }

  /// Called immediately on account/session changes, before any asynchronous
  /// teardown. Only token refreshes may keep the existing queue alive.
  void setAccount(AudioAccount? account) {
    if (_account?.sameSession(account) == true) {
      _account = account;
      return;
    }
    _account = account;
    _resetPlayer();
    if (_load == null) {
      _fileCache.selectAccount(account?.userId, account?.homeserver);
    }
    _waveforms.clear();
    _tracks.clear();
    _index = -1;
    error = null;
    _changed();
  }

  AudioTrack? findTrack(
    String filename,
    String? url,
    String? source, {
    String? roomId,
    String? messageId,
  }) {
    for (final track in _tracks) {
      if (track.filename == filename &&
          track.url == url &&
          track.mediaSourceJson == source &&
          track.roomId == roomId &&
          track.messageId == messageId) {
        return track;
      }
    }
    return null;
  }

  Future<void> toggleAttachment(
    String filename,
    String? url,
    String? source, {
    String? roomId,
    String? messageId,
    int? durationMs,
  }) {
    final existing = findTrack(
      filename,
      url,
      source,
      roomId: roomId,
      messageId: messageId,
    );
    return playTrack(
      AudioTrack(
        id: existing?.id ?? 'audio-${_nextTrackId++}',
        filename: filename,
        url: url,
        mediaSourceJson: source,
        roomId: roomId,
        messageId: messageId,
        durationMs: durationMs ?? existing?.durationMs,
      ),
    );
  }

  Future<void> playTrack(AudioTrack track) async {
    if (_account == null || _disposed) return;
    var target = _tracks.indexWhere((item) => item.id == track.id);
    if (target < 0) {
      _tracks.add(track);
      target = _tracks.length - 1;
    } else {
      _tracks[target] = track;
      if (target == _index) _player?.setDurationMetadata(track.durationMs);
    }
    if (target == _index && _player != null && error == null && !loading) {
      await toggle();
      return;
    }
    await playAt(target);
  }

  void enqueueAttachment(
    String filename,
    String? url,
    String? source, {
    String? roomId,
    String? messageId,
    int? durationMs,
  }) {
    if (_account == null || _disposed) return;
    if (findTrack(
          filename,
          url,
          source,
          roomId: roomId,
          messageId: messageId,
        ) !=
        null) {
      return;
    }
    _tracks.add(
      AudioTrack(
        id: 'audio-${_nextTrackId++}',
        filename: filename,
        url: url,
        mediaSourceJson: source,
        roomId: roomId,
        messageId: messageId,
        durationMs: durationMs,
      ),
    );
    _changed();
  }

  Future<void> playAt(int index) {
    late final Future<void> pending;
    pending = _playAt(index).whenComplete(() => _preparing.remove(pending));
    _preparing.add(pending);
    return pending;
  }

  Future<void> _playAt(int index) async {
    final account = _account;
    if (_disposed || account == null || index < 0 || index >= _tracks.length) {
      return;
    }
    _resetPlayer();
    _wantPlay = true;
    final generation = _generation;
    final preparation = _preparation = MediaPreparation();
    final track = _tracks[index];
    _index = index;
    loading = true;
    error = null;
    _changed();
    MediaPlayback? player;
    PreparedMediaSource? source;
    try {
      await _releasing;
      preparation.throwIfCancelled();
      source =
          await (_load?.call(track, account, preparation) ??
              prepareAudioTrack(
                track,
                account,
                preparation,
                cache: _fileCache,
              ));
      if (!_isCurrent(generation)) {
        await source.cleanup();
        return;
      }
      player = _createPlayer();
      await player.open(source.media, durationMs: track.durationMs);
      if (!_isCurrent(generation)) {
        await _release(player, source);
        return;
      }
      await player.setRate(speed);
      await player.setVolume(volume);
      if (!_isCurrent(generation)) {
        await _release(player, source);
        return;
      }
      _player = player;
      _source = source;
      player.addListener(_playerChanged);
      loading = false;
      await (_wantPlay ? player.play() : player.pause());
      if (_isCurrent(generation)) {
        _waveformWork = _prepareWaveform(
          track,
          source,
          preparation,
          generation,
        );
        _changed();
      }
    } catch (_) {
      if (identical(_player, player)) {
        _player?.removeListener(_playerChanged);
        _player = null;
        _source = null;
      }
      await _release(player, source);
      if (_isCurrent(generation)) {
        loading = false;
        error = '无法播放此音频';
        _changed();
      }
    }
  }

  Future<void> _prepareWaveform(
    AudioTrack track,
    PreparedMediaSource source,
    MediaPreparation preparation,
    int generation,
  ) async {
    if (_waveforms.containsKey(track.id)) return;
    try {
      final path = source.waveformFile == null
          ? source.media.uri
          : await source.waveformFile!();
      if (path == null || !_isCurrent(generation) || preparation.isCancelled) {
        return;
      }
      final values = await _extractWaveform(path, preparation);
      if (!_isCurrent(generation) ||
          preparation.isCancelled ||
          values.isEmpty) {
        return;
      }
      if (values.length > 512 ||
          values.any((value) => !value.isFinite || value < 0 || value > 1)) {
        return;
      }
      if (_waveforms.length >= 64) _waveforms.remove(_waveforms.keys.first);
      _waveforms[track.id] = List.unmodifiable(values);
      _changed();
    } catch (_) {
      // A codec can play while envelope extraction is unavailable. Keep the
      // neutral seek line in that case rather than fabricating amplitudes.
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _playerChanged() {
    if (_disposed) return;
    if (_player?.error != null) error = '无法播放此音频';
    if (isCompleted && hasNext && error == null) {
      unawaited(playAt(_index + 1));
    } else {
      _changed();
    }
  }

  Future<void> toggle() async {
    if (loading) return;
    if (_player == null || error != null) {
      if (_index >= 0) {
        await playAt(_index);
      } else if (_tracks.isNotEmpty) {
        await playAt(0);
      }
    } else if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    _wantPlay = true;
    if (loading || _disposed) return;
    final player = _player;
    if (player == null || error != null) {
      if (_index >= 0) {
        await playAt(_index);
      } else if (_tracks.isNotEmpty) {
        await playAt(0);
      }
      return;
    }
    await player.play();
    _changed();
  }

  Future<void> pause() async {
    _wantPlay = false;
    await _player?.pause();
    _changed();
  }

  Future<void> seek(Duration position) async {
    if (duration <= Duration.zero) return;
    final target = position.inMilliseconds.clamp(0, duration.inMilliseconds);
    await _player?.seek(Duration(milliseconds: target));
    _changed();
  }

  Future<void> seekRelative(int seconds) =>
      seek(position + Duration(seconds: seconds));
  Future<void> next() async {
    if (hasNext) await playAt(_index + 1);
  }

  Future<void> previous() async {
    if (position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
    } else if (hasPrevious) {
      await playAt(_index - 1);
    }
  }

  Future<void> setSpeed(double value) async {
    if (!speeds.contains(value)) throw ArgumentError.value(value);
    speed = value;
    _speedEdited = true;
    await _player?.setRate(value);
    _changed();
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setDouble('audio_playback_speed', value);
    } catch (_) {
      /* Playback remains usable if preferences cannot be saved. */
    }
  }

  Future<void> setVolume(double value) async {
    volume = value.clamp(0, 1);
    await _player?.setVolume(volume);
    _changed();
  }

  Future<void> remove(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    _waveforms.remove(_tracks[index].id);
    if (index == _index) {
      _resetPlayer();
      _tracks.removeAt(index);
      _index = -1;
      if (_tracks.isNotEmpty) {
        await playAt(index.clamp(0, _tracks.length - 1));
      } else {
        _changed();
      }
    } else {
      _tracks.removeAt(index);
      if (index < _index) _index--;
      _changed();
    }
  }

  Future<void> stop() async {
    _resetPlayer();
    _waveforms.clear();
    _tracks.clear();
    _index = -1;
    error = null;
    _changed();
    await released;
  }

  void cancelLoading() {
    if (!loading) return;
    _resetPlayer();
    error = null;
    _changed();
  }

  void _resetPlayer() {
    _generation++;
    _preparation?.cancel();
    _preparation = null;
    final player = _player;
    final source = _source;
    final waveformWork = _waveformWork;
    _waveformWork = Future.value();
    player?.removeListener(_playerChanged);
    _player = null;
    _source = null;
    loading = false;
    _wantPlay = false;
    final closePlayer = player?.close() ?? Future<void>.value();
    _releasing = Future.wait<void>([_releasing, closePlayer]);
    // Only native player teardown gates the next track. The old waveform and
    // its file lease retire separately, while stop/logout still await both.
    late final Future<void> retiring;
    retiring = () async {
      try {
        await closePlayer;
        await waveformWork;
      } finally {
        await source?.cleanup();
      }
    }().whenComplete(() => _retiring.remove(retiring));
    _retiring.add(retiring);
  }

  Future<void> _release(
    MediaPlayback? player,
    PreparedMediaSource? source,
  ) async {
    try {
      await player?.close();
    } finally {
      await source?.cleanup();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _resetPlayer();
    _waveforms.clear();
    _tracks.clear();
    await released;
    await _fileCache.close();
    super.dispose();
  }
}
