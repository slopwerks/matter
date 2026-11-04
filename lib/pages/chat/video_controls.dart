import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show defaultEnterNativeFullscreen, defaultExitNativeFullscreen;

import 'media_playback.dart';
import 'media_progress_bar.dart';
import 'video_preferences.dart';

/// Controls only: the caller supplies the video surface and owns its lifetime.
/// This also lets interaction tests run without loading native video textures.
class VideoControls extends StatefulWidget {
  final MediaPlayback playback;
  final Widget Function(BuildContext, BoxFit) videoBuilder;
  final VoidCallback onClose;

  const VideoControls({
    super.key,
    required this.playback,
    required this.videoBuilder,
    required this.onClose,
  });

  @override
  State<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<VideoControls>
    with WidgetsBindingObserver {
  final _preferences = VideoPreferences();
  final _focus = FocusNode();
  Future<void> _rateChanges = Future.value();
  Timer? _hideTimer;
  Timer? _feedbackTimer;
  bool _visible = true;
  bool _volumeVisible = false;
  bool _holding = false;
  bool _fullscreen = false;
  bool _changingFullscreen = false;
  bool _cover = false;
  bool _menuOpen = false;
  bool _wasPlaying = false;
  Duration? _seekPreview;
  Duration _dragPosition = Duration.zero;
  double _dragDistance = 0;
  double _dragVolume = 0;
  double _doubleTapX = 0;
  String? _feedback;

  MediaPlayback get _playback => widget.playback;
  bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wasPlaying = _playback.isPlaying;
    _playback.addListener(_playbackChanged);
    _preferences.addListener(_preferencesChanged);
    unawaited(_preferences.load().catchError((Object _) {}));
    _scheduleHide();
  }

  void _preferencesChanged() {
    if (!mounted) return;
    _applyRate();
    setState(() {});
  }

  void _applyRate() {
    final rate = _holding ? _preferences.heldSpeed : _preferences.speed;
    // Native calls must retain order when a quick release follows long press.
    _rateChanges = _rateChanges
        .then((_) async {
          if (!_playback.isClosed) await _playback.setRate(rate);
        })
        .catchError((Object _) {});
  }

  void _playbackChanged() {
    if (!mounted) return;
    if (_holding && (!_playback.isPlaying || _playback.isCompleted)) _endHold();
    if (_wasPlaying != _playback.isPlaying) {
      _wasPlaying = _playback.isPlaying;
      if (!_wasPlaying) setState(() => _visible = true);
      _scheduleHide();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _cancelGesture();
      unawaited(_playback.pause());
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!mounted ||
        !_playback.isPlaying ||
        _volumeVisible ||
        _menuOpen ||
        _holding ||
        _seekPreview != null) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _showFeedback(String text) {
    if (!mounted) return;
    _feedbackTimer?.cancel();
    setState(() => _feedback = text);
    _feedbackTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  void _toggleControls() {
    setState(() {
      _visible = !_visible;
      if (!_visible) _volumeVisible = false;
    });
    _scheduleHide();
  }

  Future<void> _togglePlayback() async {
    _endHold();
    await (_playback.isPlaying ? _playback.pause() : _playback.play());
    if (!mounted) return;
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _skip(int seconds) {
    unawaited(_playback.seekRelative(Duration(seconds: seconds)));
    _showFeedback(seconds < 0 ? '快退 10 秒' : '快进 10 秒');
    _scheduleHide();
  }

  void _startHold() {
    if (!_playback.isPlaying || _holding) return;
    _hideTimer?.cancel();
    _feedbackTimer?.cancel();
    setState(() {
      _holding = true;
      _feedback = null;
    });
    _applyRate();
  }

  void _endHold() {
    if (!_holding) return;
    _holding = false;
    _applyRate();
    if (mounted) setState(() {});
    _scheduleHide();
  }

  void _startSeek(DragStartDetails details) {
    _endHold();
    _hideTimer?.cancel();
    _dragPosition = _playback.position;
    _dragDistance = 0;
    setState(() => _seekPreview = _dragPosition);
  }

  void _updateSeek(DragUpdateDetails details, double width) {
    _dragDistance += details.delta.dx;
    // One full-width swipe spans at most two minutes for predictable seeking.
    final span = _playback.duration.inMilliseconds.clamp(0, 120000);
    final milliseconds =
        (_dragPosition.inMilliseconds + _dragDistance / width * span)
            .round()
            .clamp(0, _playback.duration.inMilliseconds);
    setState(() => _seekPreview = Duration(milliseconds: milliseconds));
  }

  void _finishSeek() {
    if (!mounted) return;
    final position = _seekPreview;
    setState(() => _seekPreview = null);
    if (position != null) {
      unawaited(_playback.seek(position));
      _showFeedback('跳转到 ${_time(position)}');
    }
    _scheduleHide();
  }

  void _startVolume(DragStartDetails details) {
    _endHold();
    _hideTimer?.cancel();
    _dragVolume = _playback.volume;
    _dragDistance = 0;
  }

  void _updateVolume(DragUpdateDetails details, double height) {
    _dragDistance -= details.delta.dy;
    final volume = (_dragVolume + _dragDistance / height * 2).clamp(0.0, 1.0);
    unawaited(_playback.setVolume(volume));
    _showFeedback('音量 ${(volume * 100).round()}%');
  }

  void _cancelGesture() {
    if (!mounted) return;
    _endHold();
    setState(() => _seekPreview = null);
    _scheduleHide();
  }

  Future<void> _restoreScreen() async {
    if (_mobile) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (!_mobile && !kIsWeb) await defaultExitNativeFullscreen();
  }

  Future<void> _toggleFullscreen() async {
    if (_changingFullscreen) return;
    _changingFullscreen = true;
    final entering = !_fullscreen;
    try {
      if (entering) {
        if (_mobile) {
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        }
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        if (!_mobile && !kIsWeb) await defaultEnterNativeFullscreen();
      } else {
        await _restoreScreen();
      }
      if (!mounted) {
        if (entering) await _restoreScreen();
        return;
      }
      setState(() => _fullscreen = entering);
      _scheduleHide();
    } finally {
      _changingFullscreen = false;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_menuOpen || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) unawaited(_togglePlayback());
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _skip(-10);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _skip(10);
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final volume =
          (_playback.volume +
                  (key == LogicalKeyboardKey.arrowUp ? 0.05 : -0.05))
              .clamp(0.0, 1.0);
      unawaited(_playback.setVolume(volume));
      _showFeedback('音量 ${(volume * 100).round()}%');
    } else if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) {
        _cancelGesture();
        if (_fullscreen) {
          unawaited(_toggleFullscreen());
        } else {
          widget.onClose();
        }
      }
    } else if (key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) unawaited(_toggleFullscreen());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playback.removeListener(_playbackChanged);
    _hideTimer?.cancel();
    _feedbackTimer?.cancel();
    _holding = false;
    _applyRate();
    _preferences.removeListener(_preferencesChanged);
    _preferences.dispose();
    _focus.dispose();
    if (_fullscreen) unawaited(_restoreScreen());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    onFocusChange: (focused) {
      if (!focused) _cancelGesture();
    },
    child: ListenableBuilder(
      listenable: _playback,
      builder: (context, child) => LayoutBuilder(
        builder: (context, constraints) => Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: (_) => _focus.requestFocus(),
                // Accepted drag recognizers report PointerCancel as drag end.
                // Clear the preview before that callback can commit a seek.
                onPointerCancel: (_) => _cancelGesture(),
                child: GestureDetector(
                  key: const ValueKey('video-gestures'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onDoubleTapDown: (details) =>
                      _doubleTapX = details.localPosition.dx,
                  onDoubleTap: () =>
                      _skip(_doubleTapX < constraints.maxWidth / 2 ? -10 : 10),
                  onLongPressStart: (_) => _startHold(),
                  onLongPressEnd: (_) => _endHold(),
                  onLongPressCancel: _endHold,
                  onHorizontalDragStart: _playback.duration > Duration.zero
                      ? _startSeek
                      : null,
                  onHorizontalDragUpdate: (details) =>
                      _updateSeek(details, constraints.maxWidth),
                  onHorizontalDragEnd: (_) => _finishSeek(),
                  onHorizontalDragCancel: _cancelGesture,
                  onVerticalDragStart: _startVolume,
                  onVerticalDragUpdate: (details) =>
                      _updateVolume(details, constraints.maxHeight),
                  onVerticalDragEnd: (_) => _scheduleHide(),
                  onVerticalDragCancel: _cancelGesture,
                  child: widget.videoBuilder(
                    context,
                    _cover ? BoxFit.cover : BoxFit.contain,
                  ),
                ),
              ),
            ),
            if (_holding || _seekPreview != null || _feedback != null)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 60,
                child: IgnorePointer(
                  child: _feedbackLabel(
                    _holding
                        ? '${_speed(_preferences.heldSpeed)}× 临时倍速 · 松手恢复'
                        : _seekPreview != null
                        ? '${_time(_seekPreview!)} / ${_time(_playback.duration, unknownWhenZero: true)}'
                        : _feedback!,
                  ),
                ),
              ),
            if (_visible)
              Positioned(
                top: MediaQuery.paddingOf(context).top,
                left: 4,
                child: IconButton(
                  tooltip: '关闭视频',
                  color: Colors.white,
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            if (!_playback.isPlaying)
              Center(
                child: IconButton.filledTonal(
                  tooltip: _playback.isCompleted ? '重播' : '播放',
                  iconSize: 40,
                  onPressed: _togglePlayback,
                  icon: Icon(
                    _playback.isCompleted
                        ? Icons.replay_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
              ),
            if (_visible && _volumeVisible)
              Positioned(
                right: 16,
                bottom: MediaQuery.paddingOf(context).bottom + 96,
                child: Container(
                  width: 240,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: _playback.volume == 0 ? '恢复声音' : '静音',
                        color: Colors.white,
                        onPressed: () =>
                            _playback.setVolume(_playback.volume == 0 ? 1 : 0),
                        icon: Icon(
                          _playback.volume == 0
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _playback.volume,
                          onChanged: (value) => _playback.setVolume(value),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_visible)
              Positioned(
                left: 12,
                right: 12,
                bottom: MediaQuery.paddingOf(context).bottom + 12,
                child: _toolbar(context),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _feedbackLabel(String text) => Container(
    constraints: BoxConstraints(
      maxWidth: MediaQuery.sizeOf(context).width - 32,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.black87,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(text, style: const TextStyle(color: Colors.white)),
  );

  Widget _toolbar(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: MediaProgressBar(controller: _playback, allowScrubbing: true),
        ),
        Row(
          key: const ValueKey('video-toolbar-actions'),
          children: [
            _toolbarButton(
              tooltip: _playback.isPlaying
                  ? '暂停'
                  : _playback.isCompleted
                  ? '重播'
                  : '播放',
              onPressed: _togglePlayback,
              icon: _playback.isPlaying
                  ? Icons.pause_rounded
                  : _playback.isCompleted
                  ? Icons.replay_rounded
                  : Icons.play_arrow_rounded,
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${_time(_playback.position)} / ${_time(_playback.duration, unknownWhenZero: true)}',
                    maxLines: 1,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
            _toolbarButton(
              tooltip: '音量',
              onPressed: () {
                setState(() => _volumeVisible = !_volumeVisible);
                _scheduleHide();
              },
              icon: _playback.volume == 0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
            ),
            _speedMenu(),
            _toolbarButton(
              tooltip: _fullscreen ? '退出全屏' : '横屏全屏',
              onPressed: _toggleFullscreen,
              icon: _fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: EdgeInsets.zero,
              onOpened: _openMenu,
              onCanceled: _closeMenu,
              onSelected: (action) {
                if (action == 'held') {
                  unawaited(_chooseHeldSpeed());
                } else {
                  setState(() => _cover = !_cover);
                  _closeMenu();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'held',
                  child: Text('长按倍速 · ${_speed(_preferences.heldSpeed)}×'),
                ),
                PopupMenuItem(
                  value: 'fit',
                  child: Text(_cover ? '适应画面' : '铺满画面'),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  );

  Widget _toolbarButton({
    required String tooltip,
    required VoidCallback onPressed,
    required IconData icon,
  }) => IconButton(
    tooltip: tooltip,
    color: Colors.white,
    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
    icon: Icon(icon),
  );

  void _openMenu() {
    _menuOpen = true;
    _hideTimer?.cancel();
    setState(() => _volumeVisible = false);
  }

  void _closeMenu() {
    _menuOpen = false;
    if (!mounted) return;
    _focus.requestFocus();
    _scheduleHide();
  }

  Future<void> _chooseHeldSpeed() async {
    try {
      final selected = await showDialog<double>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('长按倍速'),
          children: VideoPreferences.heldSpeeds
              .map(
                (speed) => SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(speed),
                  child: Row(
                    children: [
                      Expanded(child: Text('${_speed(speed)}×')),
                      if (speed == _preferences.heldSpeed)
                        const Icon(Icons.check_rounded),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      );
      if (mounted && selected != null) {
        await _preferences.setHeldSpeed(selected);
      }
    } finally {
      _closeMenu();
    }
  }

  Widget _speedMenu() {
    final value = _preferences.speed;
    return PopupMenuButton<double>(
      tooltip: '设置播放速度',
      initialValue: value,
      onOpened: _openMenu,
      onCanceled: _closeMenu,
      onSelected: (speed) {
        unawaited(_preferences.setSpeed(speed));
        _closeMenu();
      },
      itemBuilder: (context) => VideoPreferences.speeds
          .map(
            (speed) =>
                PopupMenuItem(value: speed, child: Text('${_speed(speed)}×')),
          )
          .toList(),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: Text(
            '${_speed(value)}×',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

String _speed(double value) =>
    value.toString().replaceFirst(RegExp(r'\.0$'), '');

String _time(Duration value, {bool unknownWhenZero = false}) {
  if (unknownWhenZero && value <= Duration.zero) return '--:--';
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (value.inHours == 0) return '${value.inMinutes}:$seconds';
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  return '${value.inHours}:$minutes:$seconds';
}
