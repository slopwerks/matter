import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import 'audio_playback_session.dart';
import 'audio_player_panel.dart';

/// The chat reserves this height below pinned messages, never below the input.
const audioMessageBarHeight = 52.0;

class AudioMessageBar extends StatelessWidget {
  final AudioPlaybackSession session;
  final VoidCallback onSourceTap;
  final VoidCallback onQueueTap;

  const AudioMessageBar({
    super.key,
    required this.session,
    required this.onSourceTap,
    required this.onQueueTap,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, child) {
      final canJump =
          session.current?.roomId != null && session.current?.messageId != null;
      return GlassPanel(
        radius: context.isMaterial ? 0 : NeuRadius.surface,
        child: SizedBox(
          key: const ValueKey('audio-message-bar'),
          height: audioMessageBarHeight,
          child: Row(
            children: [
              AudioPlayButton(session: session, color: context.neu.accent),
              Expanded(
                child: InkWell(
                  onTap: canJump ? onSourceTap : null,
                  child: Tooltip(
                    message: canJump ? '回到音频消息' : '音频队列',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session.current?.filename ??
                              '播放队列（${session.tracks.length}）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        Text(
                          session.error ??
                              (session.loading
                                  ? '正在加载…'
                                  : session.current == null
                                  ? '待播放'
                                  : '${audioTime(session.position)} / ${audioTime(session.duration, unknownWhenZero: true)}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '播放队列',
                onPressed: onQueueTap,
                icon: const Icon(Icons.queue_music_rounded),
              ),
              IconButton(
                tooltip: '关闭音频播放器',
                onPressed: session.stop,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      );
    },
  );
}
