import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:matter/pages/chat/media_playback.dart';

// Opt in on hosts with libmpv and a local video fixture; ordinary widget-test
// runs remain independent of native playback libraries and audio devices.
void main() {
  const fixture = String.fromEnvironment('MATTER_MEDIA_FIXTURE');
  test(
    'native backend decodes video and supports playback and seeking',
    () async {
      MediaKit.ensureInitialized();
      final player = Player();
      final playback = MediaPlayback(player: player);
      addTearDown(playback.close);
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await native.setProperty('vo', 'null');
      // A real VideoController enables this when it attaches its texture.
      await native.setProperty('vid', 'auto');
      final durationReady = player.stream.duration.firstWhere(
        (value) => value > Duration.zero,
      );
      final videoReady = player.stream.width.firstWhere(
        (value) => value != null && value > 0,
      );
      await playback.open(Media(fixture));
      await durationReady.timeout(const Duration(seconds: 10));
      await videoReady.timeout(const Duration(seconds: 10));
      expect(playback.aspectRatio, closeTo(16 / 9, 0.01));
      expect(playback.duration.inSeconds, greaterThanOrEqualTo(2));
      expect(playback.isPlaying, isFalse);
      final playing = player.stream.playing.firstWhere((value) => value);
      await playback.play();
      await playing.timeout(const Duration(seconds: 5));
      final seeked = player.stream.position.firstWhere(
        (value) => value >= const Duration(seconds: 1),
      );
      await playback.seek(const Duration(seconds: 1));
      await seeked.timeout(const Duration(seconds: 5));
      final paused = player.stream.playing.firstWhere((value) => !value);
      await playback.pause();
      await paused.timeout(const Duration(seconds: 5));
      expect(playback.error, isNull);
    },
    skip: fixture.isEmpty,
  );
}
