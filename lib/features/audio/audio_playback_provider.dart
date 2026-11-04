import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import 'audio_playback_session.dart';
import 'audio_system_controls.dart';
import 'audio_track.dart';

final audioPlaybackSessionProvider = Provider<AudioPlaybackSession>((ref) {
  final session = AudioPlaybackSession();
  void syncAccount() {
    final user = ref.read(currentUserProvider);
    session.setAccount(
      user == null || !ref.read(sessionReadyProvider)
          ? null
          : AudioAccount(
              user.id,
              user.homeserver,
              ref.read(currentAccessTokenProvider),
            ),
    );
  }

  ref.listen(currentUserProvider, (previous, next) => syncAccount());
  ref.listen(currentAccessTokenProvider, (previous, next) => syncAccount());
  ref.listen(sessionReadyProvider, (previous, next) => syncAccount());
  syncAccount();
  ref.onDispose(() => unawaited(session.close()));
  return session;
});

final audioPlayerVisibleProvider =
    NotifierProvider<_AudioPlayerVisibility, bool>(_AudioPlayerVisibility.new);

class _AudioPlayerVisibility extends Notifier<bool> {
  @override
  bool build() {
    final session = ref.watch(audioPlaybackSessionProvider);
    void update() {
      final visible = session.current != null || session.tracks.isNotEmpty;
      if (state != visible) state = visible;
    }

    session.addListener(update);
    ref.onDispose(() => session.removeListener(update));
    return session.current != null || session.tracks.isNotEmpty;
  }
}

/// Lives above routes: navigation and recycled message bubbles cannot tear down
/// playback. Authentication, not the visible page, defines its lifetime.
class AudioPlaybackRoot extends ConsumerStatefulWidget {
  final Widget child;
  const AudioPlaybackRoot({super.key, required this.child});

  @override
  ConsumerState<AudioPlaybackRoot> createState() => _AudioPlaybackRootState();
}

class _AudioPlaybackRootState extends ConsumerState<AudioPlaybackRoot> {
  late final AudioPlaybackSession _session;
  late final AudioSystemControls _system;

  @override
  void initState() {
    super.initState();
    _session = ref.read(audioPlaybackSessionProvider);
    _system = AudioSystemControls(_session);
    unawaited(_session.restorePreferences());
  }

  @override
  void dispose() {
    _system.dispose();
    unawaited(_session.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
