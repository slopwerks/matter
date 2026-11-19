import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show Media, Playable, Player;
import 'package:matter/features/audio/audio_playback_provider.dart';
import 'package:matter/features/audio/audio_playback_session.dart';
import 'package:matter/features/audio/audio_player_panel.dart';
import 'package:matter/features/audio/audio_message_bar.dart';
import 'package:matter/features/audio/audio_system_controls.dart';
import 'package:matter/features/audio/audio_track.dart';
import 'package:matter/pages/chat/audio_attachment_player.dart';
import 'package:matter/pages/chat/media_playback.dart';
import 'package:matter/pages/chat/prepared_media_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';
import 'support/video_test_player.dart';

class _AudioPlayer extends VideoTestPlayer {
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    state = state.copyWith(playing: false, position: Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AudioPlaybackSession session;
  const account = AudioAccount(
    '@alice:example.org',
    'https://example.org',
    'private-token',
  );
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    session = AudioPlaybackSession(
      createPlayer: () =>
          MediaPlayback(player: Player(platformPlayer: _AudioPlayer())),
      load: (track, account, preparation) async => PreparedMediaSource(
        media: Media('file:///${track.id}.ogg'),
        cleanup: () async {},
      ),
    )..setAccount(account);
  });
  tearDown(() => session.close());

  Future<void> waitUntil(WidgetTester tester, bool Function() ready) async {
    final watch = Stopwatch()..start();
    while (!ready()) {
      if (watch.elapsed > const Duration(seconds: 5)) {
        fail('Audio state did not settle');
      }
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    await tester.pump();
  }

  // Close stream-backed mocks while the widget's fake clock can still advance.
  // A tearDown outside that clock cannot drain callbacks created inside it.
  void audioWidgetTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        final closing = session.close();
        var done = false;
        unawaited(
          closing.then(
            (_) => done = true,
            onError: (Object _, StackTrace _) => done = true,
          ),
        );
        await waitUntil(tester, () => done);
        await closing;
      }
    });
  }

  const track = AudioTrack(
    id: 'one',
    filename: 'voice.ogg',
    url: 'https://example.org/one',
    mediaSourceJson: null,
  );
  Widget host(Widget child, {bool dark = true, bool material = false}) =>
      ProviderScope(
        overrides: [audioPlaybackSessionProvider.overrideWithValue(session)],
        child: MaterialApp(
          theme: neuTestTheme(dark: dark, material: material),
          home: Scaffold(body: Center(child: child)),
        ),
      );
  const attachment = AudioAttachmentPlayer(
    url: 'https://example.org/one',
    mediaSourceJson: null,
    filename: 'voice.ogg',
    foreground: Colors.black,
  );

  audioWidgetTest(
    'audio metadata is shown before download and stays stable during playback',
    (tester) async {
      await tester.pumpWidget(
        host(
          const AudioAttachmentPlayer(
            url: 'https://example.org/one',
            mediaSourceJson: null,
            filename: 'voice.ogg',
            foreground: Colors.black,
            durationMs: 65000,
          ),
        ),
      );
      expect(find.text('1:05'), findsOneWidget);
      await tester.tap(find.byTooltip('播放音频'));
      await waitUntil(tester, () => session.isPlaying || session.error != null);
      expect(session.duration, const Duration(seconds: 65));
      expect(find.text('0:00 / 1:05'), findsOneWidget);
    },
  );

  audioWidgetTest(
    'missing metadata shows unknown instead of a zero total before playback',
    (tester) async {
      await tester.pumpWidget(host(attachment));
      expect(find.text('--:--'), findsOneWidget);
    },
  );

  test('system controls publish the same stable metadata total', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AudioSystemControls.channel, (call) async {
          calls.add(call);
          return null;
        });
    final controls = AudioSystemControls(session);
    try {
      await session.toggleAttachment(
        'voice.ogg',
        'https://example.org/one',
        null,
        durationMs: 65000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      final updates = calls
          .where(
            (call) =>
                call.method == 'update' &&
                (call.arguments as Map)['title'] == 'voice.ogg',
          )
          .toList();
      expect(updates, isNotEmpty);
      expect(
        updates.map((call) => (call.arguments as Map)['durationMs']),
        everyElement(65000),
      );
    } finally {
      controls.dispose();
      await Future<void>.delayed(Duration.zero);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AudioSystemControls.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  audioWidgetTest('disposing an attachment does not stop the global player', (
    tester,
  ) async {
    await tester.pumpWidget(host(attachment));
    await tester.tap(find.byTooltip('播放音频'));
    await waitUntil(tester, () => session.isPlaying || session.error != null);
    expect(session.isPlaying, isTrue);
    await tester.pumpWidget(host(const SizedBox.shrink()));
    await tester.pump();
    expect(session.isPlaying, isTrue);
    expect(session.current?.filename, 'voice.ogg');
  });

  audioWidgetTest('chat audio bar pauses and closes the same shared session', (
    tester,
  ) async {
    await tester.runAsync(() => session.playTrack(track));
    await tester.pumpWidget(
      host(
        ListenableBuilder(
          listenable: session,
          builder: (_, child) => session.current == null
              ? const SizedBox.shrink()
              : AudioMessageBar(
                  session: session,
                  onSourceTap: () {},
                  onQueueTap: () {},
                ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('暂停音频'));
    await tester.pump();
    expect(session.isPlaying, isFalse);
    await tester.tap(find.byTooltip('关闭音频播放器'));
    await tester.pump();
    expect(session.current, isNull);
  });

  audioWidgetTest(
    'chat audio bar taps the current source and keeps queue separate',
    (tester) async {
      await tester.runAsync(
        () => session.playTrack(
          const AudioTrack(
            id: 'source',
            filename: 'voice.ogg',
            url: null,
            mediaSourceJson: null,
            roomId: '!room:example.org',
            messageId: r'$audio-event',
          ),
        ),
      );
      var jumps = 0;
      var queues = 0;
      await tester.pumpWidget(
        host(
          AudioMessageBar(
            session: session,
            onSourceTap: () => jumps++,
            onQueueTap: () => queues++,
          ),
        ),
      );
      await tester.tap(find.byTooltip('回到音频消息'));
      await tester.pump();
      expect(jumps, 1);
      expect(session.current?.messageId, r'$audio-event');
      await tester.tap(find.byTooltip('播放队列'));
      await tester.pump();
      expect(queues, 1);
      expect(jumps, 1);
    },
  );

  audioWidgetTest('app audio owner no longer places a player below the input', (
    tester,
  ) async {
    await tester.runAsync(() => session.playTrack(track));
    await tester.pumpWidget(
      host(
        AudioPlaybackRoot(
          child: const SizedBox.expand(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                key: ValueKey('input-bottom'),
                height: 50,
                width: 100,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AudioMessageBar), findsNothing);
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('input-bottom'))).dy,
      tester.getBottomLeft(find.byType(Scaffold).first).dy,
    );
  });

  audioWidgetTest(
    'queue sheet selects and removes tracks without replacing the session',
    (tester) async {
      await tester.runAsync(() => session.playTrack(track));
      session.enqueueAttachment('two.ogg', 'https://example.org/two', null);
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAudioPlayerPanel(context, session),
              child: const Text('queue'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('queue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('two.ogg'));
      await waitUntil(
        tester,
        () => !session.loading && session.current?.filename == 'two.ogg',
      );
      expect(session.current?.filename, 'two.ogg');
      await tester.tap(find.byTooltip('从队列移除').first);
      await tester.pump();
      expect(session.tracks, hasLength(1));
      expect(session.current?.filename, 'two.ogg');
    },
  );

  audioWidgetTest('loading can be cancelled from the attachment', (
    tester,
  ) async {
    await tester.runAsync(session.close);
    final pending = Completer<PreparedMediaSource>();
    session = AudioPlaybackSession(
      load: (track, account, preparation) => pending.future,
    )..setAccount(account);
    await tester.pumpWidget(host(attachment));
    await tester.tap(find.byTooltip('播放音频'));
    await waitUntil(tester, () => session.loading);
    await tester.tap(find.byTooltip('取消音频加载'));
    await tester.pump();
    expect(session.loading, isFalse);
    var cleaned = false;
    pending.complete(
      PreparedMediaSource(
        media: Media('file:///late.ogg'),
        cleanup: () async => cleaned = true,
      ),
    );
    await waitUntil(tester, () => cleaned);
    expect(cleaned, isTrue);
    expect(session.isPlaying, isFalse);
  });

  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      audioWidgetTest(
        'compact audio controls fit 320dp material=$material dark=$dark',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(320, 640));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.runAsync(
            () => session.toggleAttachment(
              'voice.ogg',
              'https://example.org/one',
              null,
            ),
          );
          await tester.pumpWidget(
            host(
              const SizedBox(width: 260, child: attachment),
              material: material,
              dark: dark,
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byTooltip('音频倍速'), findsOneWidget);
          expect(find.byTooltip('音频附件更多'), findsOneWidget);
        },
      );
    }
  }

  test(
    'platform commands use the same player and reject old account commands',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AudioSystemControls.channel, (call) async {
            calls.add(call);
            return null;
          });
      final controls = AudioSystemControls(session);
      try {
        await session.playTrack(track);
        final revision = session.revision;
        await controls.handleCommand(
          MethodCall('pause', {'generation': revision}),
        );
        expect(session.isPlaying, isFalse);
        await controls.handleCommand(
          MethodCall('play', {'generation': revision}),
        );
        expect(session.isPlaying, isTrue);
        await controls.handleCommand(
          MethodCall('seek', {'generation': revision, 'positionMs': 15000}),
        );
        expect(session.position, const Duration(seconds: 15));
        session.setAccount(null);
        await controls.handleCommand(
          MethodCall('play', {'generation': revision}),
        );
        expect(session.isPlaying, isFalse);
        expect(session.tracks, isEmpty);
        await Future<void>.delayed(Duration.zero);
        for (final call in calls.where((call) => call.method == 'update')) {
          final map = call.arguments as Map;
          expect(map.keys, isNot(contains('url')));
          expect(map.keys, isNot(contains('mediaSourceJson')));
          expect(map.toString(), isNot(contains('private-token')));
        }
      } finally {
        controls.dispose();
        await Future<void>.delayed(Duration.zero);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AudioSystemControls.channel, null);
      }
    },
  );
}
