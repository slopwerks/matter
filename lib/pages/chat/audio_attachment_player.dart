import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/audio/audio_playback_provider.dart';
import '../../features/audio/audio_player_panel.dart';
import '../../features/audio/audio_waveform.dart';

/// A view onto the app-owned audio session. Removing a bubble no longer stops
/// playback; the mini player, queue and system notification keep controlling it.
class AudioAttachmentPlayer extends ConsumerWidget {
  final String? url;
  final String? mediaSourceJson;
  final String filename;
  final String? roomId;
  final String? messageId;
  final int? durationMs;
  final Color foreground;

  const AudioAttachmentPlayer({
    super.key,
    required this.url,
    required this.mediaSourceJson,
    required this.filename,
    this.roomId,
    this.messageId,
    this.durationMs,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(audioPlaybackSessionProvider);
    return ListenableBuilder(
      listenable: session,
      builder: (context, child) {
        final item = session.findTrack(
          filename,
          url,
          mediaSourceJson,
          roomId: roomId,
          messageId: messageId,
        );
        final active = item != null && item.id == session.current?.id;
        final duration = active ? session.duration.inMilliseconds : 0;
        final position = active
            ? session.position.inMilliseconds.clamp(0, duration)
            : 0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (active)
                  AudioPlayButton(session: session, color: foreground)
                else
                  IconButton(
                    tooltip: '播放音频',
                    color: foreground,
                    onPressed: () => session.toggleAttachment(
                      filename,
                      url,
                      mediaSourceJson,
                      roomId: roomId,
                      messageId: messageId,
                      durationMs: durationMs,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AudioWaveform(
                        samples: item == null
                            ? null
                            : session.waveformFor(item.id),
                        progress: duration > 0 ? position / duration : 0,
                        color: foreground,
                        onSeek: active && duration > 0 && session.error == null
                            ? (fraction) => session.seek(
                                Duration(
                                  milliseconds: (fraction * duration).round(),
                                ),
                              )
                            : null,
                      ),
                      Text(
                        active
                            ? '${audioTime(session.position)} / ${audioTime(session.duration, unknownWhenZero: true)}'
                            : audioTime(
                                Duration(milliseconds: durationMs ?? 0),
                                unknownWhenZero: true,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: foreground),
                      ),
                    ],
                  ),
                ),
                if (active)
                  AudioSpeedButton(session: session, color: foreground),
                PopupMenuButton<String>(
                  tooltip: '音频附件更多',
                  icon: Icon(Icons.more_horiz_rounded, color: foreground),
                  onSelected: (action) {
                    if (action == 'queue') {
                      session.enqueueAttachment(
                        filename,
                        url,
                        mediaSourceJson,
                        roomId: roomId,
                        messageId: messageId,
                        durationMs: durationMs,
                      );
                      ScaffoldMessenger.maybeOf(
                        context,
                      )?.showSnackBar(const SnackBar(content: Text('已加入音频队列')));
                    } else {
                      unawaited(showAudioPlayerPanel(context, session));
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'queue', child: Text('加入队列')),
                    if (session.tracks.isNotEmpty)
                      const PopupMenuItem(
                        value: 'player',
                        child: Text('打开播放器'),
                      ),
                  ],
                ),
              ],
            ),
            if (active && session.error != null)
              Text(
                session.error!,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: foreground),
              ),
          ],
        );
      },
    );
  }
}
