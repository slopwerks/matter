import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show Media, Playable, Player;
import 'package:matter/features/audio/audio_playback_session.dart';
import 'package:matter/features/audio/audio_track.dart';
import 'package:matter/pages/chat/media_playback.dart';
import 'package:matter/pages/chat/media_preparation.dart';
import 'package:matter/pages/chat/prepared_media_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/video_test_player.dart';

class _AudioPlayer extends VideoTestPlayer {
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    state = state.copyWith(playing: false, position: Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const alice = AudioAccount(
    '@alice:example.org',
    'https://example.org',
    'token',
  );
  const bob = AudioAccount('@bob:example.org', 'https://example.org', 'other');
  AudioTrack track(String id) => AudioTrack(
    id: id,
    filename: '$id.ogg',
    url: 'https://example.org/$id',
    mediaSourceJson: null,
  );

  late AudioPlaybackSession session;
  late List<MediaPlayback> players;
  late List<String> cleaned;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    players = [];
    cleaned = [];
    session = AudioPlaybackSession(
      createPlayer: () {
        final player = MediaPlayback(
          player: Player(platformPlayer: _AudioPlayer()),
        );
        players.add(player);
        return player;
      },
      load: (track, account, preparation) async => PreparedMediaSource(
        media: Media('file:///${track.id}.ogg'),
        cleanup: () async => cleaned.add(track.id),
      ),
    );
    session.setAccount(alice);
  });
  tearDown(() => session.close());

  test('attachment metadata is retained through queue navigation and used for seek', () async {
    await session.toggleAttachment(
      'one.ogg',
      'https://example.org/one',
      null,
      durationMs: 65000,
    );
    expect(session.duration, const Duration(seconds: 65));
    expect(session.tracks.single.durationMs, 65000);
    await session.seek(const Duration(minutes: 5));
    expect(session.position, const Duration(seconds: 65));
    session.enqueueAttachment(
      'two.ogg',
      'https://example.org/two',
      null,
      durationMs: 42000,
    );
    await session.next();
    expect(session.duration, const Duration(seconds: 42));
    await session.previous();
    expect(session.duration, const Duration(seconds: 65));
    session.setAccount(bob);
    expect(session.duration, Duration.zero);
  });

  test(
    'message duration is visible even before preparation completes',
    () async {
      await session.close();
      final ready = Completer<PreparedMediaSource>();
      session = AudioPlaybackSession(
        load: (_, account, preparation) => ready.future,
      )..setAccount(alice);
      final pending = session.playTrack(
        const AudioTrack(
          id: 'pending',
          filename: 'one.ogg',
          url: null,
          mediaSourceJson: null,
          durationMs: 123456,
        ),
      );
      expect(session.loading, isTrue);
      expect(session.duration, const Duration(milliseconds: 123456));
      session.setAccount(null);
      ready.complete(
        PreparedMediaSource(
          media: Media('file:///one.ogg'),
          cleanup: () async {},
        ),
      );
      await pending;
      expect(session.duration, Duration.zero);
    },
  );

  test(
    'another attachment pauses/releases the previous player and keeps a queue',
    () async {
      await session.playTrack(track('one'));
      expect(session.isPlaying, isTrue);
      await session.playTrack(track('two'));
      expect(players.first.isClosed, isTrue);
      await session.released;
      expect(cleaned, ['one']);
      expect(session.tracks.map((track) => track.id), ['one', 'two']);
      expect(session.current?.id, 'two');
      expect(session.isPlaying, isTrue);
    },
  );

  test(
    'queue navigation and removal keep the correct active identity',
    () async {
      await session.playTrack(track('one'));
      await session.playTrack(track('two'));
      await session.previous();
      expect(session.current?.id, 'one');
      await session.next();
      expect(session.current?.id, 'two');
      await session.remove(0);
      expect(session.current?.id, 'two');
      expect(session.index, 0);
      await session.remove(0);
      expect(session.current, isNull);
      expect(session.tracks, isEmpty);
    },
  );

  test(
    'account change stops audio and immediately clears metadata and queue',
    () async {
      await session.playTrack(track('one'));
      session.setAccount(bob);
      expect(session.current, isNull);
      expect(session.isPlaying, isFalse);
      expect(session.tracks, isEmpty);
      await session.stop();
      expect(cleaned, ['one']);
      expect(players.single.isClosed, isTrue);
    },
  );

  test(
    'token refresh preserves playback but logout destroys the queue',
    () async {
      await session.playTrack(track('one'));
      session.setAccount(
        const AudioAccount(
          '@alice:example.org',
          'https://example.org',
          'refreshed',
        ),
      );
      expect(session.isPlaying, isTrue);
      expect(session.current?.id, 'one');
      session.setAccount(null);
      await session.stop();
      expect(session.tracks, isEmpty);
      expect(players.single.isClosed, isTrue);
    },
  );

  test(
    'cancelling preparation rejects a late result and allows retry',
    () async {
      await session.close();
      var requests = 0;
      final lateSource = Completer<PreparedMediaSource>();
      MediaPreparation? cancellation;
      session = AudioPlaybackSession(
        createPlayer: () =>
            MediaPlayback(player: Player(platformPlayer: _AudioPlayer())),
        load: (track, account, preparation) {
          cancellation = preparation;
          if (requests++ == 0) return lateSource.future;
          return Future.value(
            PreparedMediaSource(
              media: Media('file:///retry.ogg'),
              cleanup: () async {},
            ),
          );
        },
      )..setAccount(alice);
      final pending = session.playTrack(track('one'));
      await Future<void>.delayed(Duration.zero);
      session.cancelLoading();
      expect(cancellation!.isCancelled, isTrue);
      var removedLate = false;
      lateSource.complete(
        PreparedMediaSource(
          media: Media('file:///late.ogg'),
          cleanup: () async => removedLate = true,
        ),
      );
      await pending;
      expect(removedLate, isTrue);
      expect(session.isPlaying, isFalse);
      await session.toggle();
      expect(session.isPlaying, isTrue);
    },
  );

  test(
    'an obsolete waveform cannot block the next track or lose file protection',
    () async {
      await session.close();
      final waveform = Completer<List<double>>();
      final deleted = <String>[];
      session = AudioPlaybackSession(
        createPlayer: () =>
            MediaPlayback(player: Player(platformPlayer: _AudioPlayer())),
        load: (track, account, preparation) async => PreparedMediaSource(
          media: Media('file:///${track.id}.ogg'),
          cleanup: () async => deleted.add(track.id),
        ),
        waveformLoader: (uri, preparation) =>
            uri.endsWith('one.ogg') ? waveform.future : Future.value(const []),
      )..setAccount(alice);
      await session.playTrack(track('one'));
      var switched = false;
      final pending = session
          .playTrack(track('two'))
          .then((_) => switched = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final secondStartedWhileOldWaveformPending =
          switched && session.isPlaying && session.current?.id == 'two';
      expect(deleted, isNot(contains('one')));
      waveform.complete(const []);
      await pending;
      await session.released;
      expect(secondStartedWhileOldWaveformPending, isTrue);
      expect(deleted, contains('one'));
    },
  );

  test('a pause command during loading prevents late autoplay', () async {
    await session.close();
    final loaded = Completer<PreparedMediaSource>();
    session = AudioPlaybackSession(
      createPlayer: () =>
          MediaPlayback(player: Player(platformPlayer: _AudioPlayer())),
      load: (_, account, preparation) => loaded.future,
    )..setAccount(alice);
    final pending = session.playTrack(track('one'));
    await Future<void>.delayed(Duration.zero);
    await session.pause();
    loaded.complete(
      PreparedMediaSource(
        media: Media('file:///one.ogg'),
        cleanup: () async {},
      ),
    );
    await pending;
    expect(session.isPlaying, isFalse);
    await session.play();
    expect(session.isPlaying, isTrue);
  });

  test(
    'stop waits for cancelled preparation cleanup before engine release',
    () async {
      await session.close();
      final loaded = Completer<PreparedMediaSource>();
      session = AudioPlaybackSession(
        load: (_, account, preparation) => loaded.future,
      )..setAccount(alice);
      final pending = session.playTrack(track('one'));
      await Future<void>.delayed(Duration.zero);
      var finished = false;
      final stopping = session.stop().then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      var cleaned = false;
      loaded.complete(
        PreparedMediaSource(
          media: Media('file:///one.ogg'),
          cleanup: () async => cleaned = true,
        ),
      );
      await pending;
      await stopping;
      expect(cleaned, isTrue);
      expect(finished, isTrue);
    },
  );

  test(
    'identical media in different messages keeps distinct source locations',
    () async {
      await session.toggleAttachment(
        'voice.ogg',
        'https://example.org/shared',
        null,
        roomId: '!one:example.org',
        messageId: r'$first',
      );
      await session.toggleAttachment(
        'voice.ogg',
        'https://example.org/shared',
        null,
        roomId: '!one:example.org',
        messageId: r'$second',
      );
      expect(session.tracks, hasLength(2));
      expect(session.current?.messageId, r'$second');
      final first = session.findTrack(
        'voice.ogg',
        'https://example.org/shared',
        null,
        roomId: '!one:example.org',
        messageId: r'$first',
      );
      expect(first?.messageId, r'$first');
      await session.toggleAttachment(
        'voice.ogg',
        'https://example.org/shared',
        null,
        roomId: '!two:example.org',
        messageId: r'$first',
      );
      expect(session.tracks, hasLength(3));
      expect(session.current?.roomId, '!two:example.org');
    },
  );

  test(
    'account switch cancels waveform and waits before deleting its file',
    () async {
      await session.close();
      final envelope = Completer<List<double>>();
      MediaPreparation? extraction;
      var deleted = false;
      session = AudioPlaybackSession(
        createPlayer: () =>
            MediaPlayback(player: Player(platformPlayer: _AudioPlayer())),
        load: (_, account, preparation) async => PreparedMediaSource(
          media: Media('file:///decoded.ogg'),
          cleanup: () async => deleted = true,
        ),
        waveformLoader: (_, preparation) {
          extraction = preparation;
          return envelope.future;
        },
      )..setAccount(alice);
      await session.playTrack(track('one'));
      session.setAccount(bob);
      expect(extraction?.isCancelled, isTrue);
      expect(deleted, isFalse);
      envelope.complete([0.1, 0.8]);
      await session.released;
      expect(deleted, isTrue);
      expect(session.waveformFor('one'), isNull);
      expect(session.current, isNull);
    },
  );

  test(
    'unavailable waveform decoding keeps audio playable without fake data',
    () async {
      await session.close();
      session = AudioPlaybackSession(
        createPlayer: () =>
            MediaPlayback(player: Player(platformPlayer: _AudioPlayer())),
        load: (_, account, preparation) async => PreparedMediaSource(
          media: Media('file:///unsupported.ogg'),
          cleanup: () async {},
        ),
        waveformLoader: (_, preparation) async =>
            throw UnsupportedError('codec'),
      )..setAccount(alice);
      await session.playTrack(track('one'));
      await Future<void>.delayed(Duration.zero);
      expect(session.isPlaying, isTrue);
      expect(session.error, isNull);
      expect(session.waveformFor('one'), isNull);
    },
  );

  test(
    'speed is independent of video and relative seek clamps to duration',
    () async {
      await session.playTrack(track('one'));
      await session.setSpeed(1.5);
      expect(session.player?.rate, 1.5);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getDouble('audio_playback_speed'), 1.5);
      expect(preferences.getDouble('video_playback_speed'), isNull);
      await session.seekRelative(-10);
      expect(session.position, Duration.zero);
      await session.seekRelative(1000);
      expect(session.position, session.duration);
    },
  );
}
