import 'dart:async';

import 'package:flutter/material.dart';

import 'audio_playback_session.dart';

class AudioPlayButton extends StatelessWidget {
  final AudioPlaybackSession session;
  final Color? color;
  const AudioPlayButton({super.key, required this.session, this.color});

  @override
  Widget build(BuildContext context) => session.loading
      ? IconButton(
          tooltip: '取消音频加载',
          onPressed: session.cancelLoading,
          icon: const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      : IconButton(
          color: color,
          tooltip: session.error != null
              ? '重试播放'
              : session.isPlaying
              ? '暂停音频'
              : session.isCompleted
              ? '重播音频'
              : '播放音频',
          onPressed: session.toggle,
          icon: Icon(
            session.error != null
                ? Icons.refresh_rounded
                : session.isPlaying
                ? Icons.pause_rounded
                : session.isCompleted
                ? Icons.replay_rounded
                : Icons.play_arrow_rounded,
          ),
        );
}

class AudioSpeedButton extends StatelessWidget {
  final AudioPlaybackSession session;
  final Color? color;
  const AudioSpeedButton({super.key, required this.session, this.color});

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
    tooltip: '音频倍速',
    initialValue: session.speed,
    onSelected: session.setSpeed,
    itemBuilder: (context) => AudioPlaybackSession.speeds
        .map(
          (speed) =>
              PopupMenuItem(value: speed, child: Text('${audioSpeed(speed)}×')),
        )
        .toList(),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Text(
        '${audioSpeed(session.speed)}×',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
      ),
    ),
  );
}

class AudioMoreButton extends StatelessWidget {
  final AudioPlaybackSession session;
  final Color? color;
  const AudioMoreButton({super.key, required this.session, this.color});

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: '音频更多',
    icon: Icon(Icons.more_horiz_rounded, color: color),
    onSelected: (action) {
      switch (action) {
        case 'back':
          unawaited(session.seekRelative(-10));
        case 'forward':
          unawaited(session.seekRelative(10));
        case 'volume':
          unawaited(
            showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('音量'),
                content: ListenableBuilder(
                  listenable: session,
                  builder: (context, child) => Slider(
                    value: session.volume,
                    onChanged: session.setVolume,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
          );
      }
    },
    itemBuilder: (context) => const [
      PopupMenuItem(value: 'back', child: Text('快退 10 秒')),
      PopupMenuItem(value: 'forward', child: Text('快进 10 秒')),
      PopupMenuItem(value: 'volume', child: Text('音量')),
    ],
  );
}

Future<void> showAudioPlayerPanel(
  BuildContext context,
  AudioPlaybackSession session,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => FractionallySizedBox(
    heightFactor: 0.7,
    child: ListenableBuilder(
      listenable: session,
      builder: (context, child) => Column(
        children: [
          ListTile(
            title: const Text('音频播放'),
            subtitle: Text(
              session.current?.filename ?? '队列为空',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '收起播放器',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.expand_more_rounded),
            ),
          ),
          Slider(
            value: session.position.inMilliseconds
                .clamp(0, session.duration.inMilliseconds)
                .toDouble(),
            max: session.duration > Duration.zero
                ? session.duration.inMilliseconds.toDouble()
                : 1,
            onChanged: session.duration > Duration.zero
                ? (value) => session.seek(Duration(milliseconds: value.round()))
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Text(audioTime(session.position)),
                const Spacer(),
                Text(audioTime(session.duration, unknownWhenZero: true)),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一首',
                onPressed:
                    session.hasPrevious || session.position > Duration.zero
                    ? session.previous
                    : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              AudioPlayButton(session: session),
              IconButton(
                tooltip: '下一首',
                onPressed: session.hasNext ? session.next : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
              AudioSpeedButton(session: session),
              AudioMoreButton(session: session),
            ],
          ),
          if (session.error != null)
            Text(
              session.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: session.tracks.length,
              itemBuilder: (context, index) {
                final track = session.tracks[index];
                return ListTile(
                  selected: session.index == index,
                  leading: Icon(
                    session.index == index
                        ? Icons.audiotrack_rounded
                        : Icons.music_note_rounded,
                  ),
                  title: Text(
                    track.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => session.index == index
                      ? session.toggle()
                      : session.playAt(index),
                  trailing: IconButton(
                    tooltip: '从队列移除',
                    onPressed: () => session.remove(index),
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  ),
);

String audioSpeed(double speed) =>
    speed.toString().replaceFirst(RegExp(r'\.0$'), '');
String audioTime(Duration value, {bool unknownWhenZero = false}) {
  if (unknownWhenZero && value <= Duration.zero) return '--:--';
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (value.inHours == 0) return '${value.inMinutes}:$seconds';
  return '${value.inHours}:${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:$seconds';
}
