import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/pages/chat/file_message_bubble.dart';
import 'package:matter/pages/chat/video_message_bubble.dart';
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';
import 'support/media_transfer_api.dart';
import 'support/temp_path_provider.dart';

void main() {
  late MediaTransferApi api;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('matter-chat-playback-');
    installTempPathProvider(root);
    api = MediaTransferApi();
    RustLib.initMock(api: api);
  });
  tearDown(() async {
    RustLib.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  // Preparation crosses real filesystem callbacks and Flutter's fake clock.
  // Pump both until the observable condition holds, with a bounded timeout.
  Future<void> pumpUntil(
    WidgetTester tester,
    Future<bool> Function() ready,
  ) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      await tester.pump();
      if (await tester.runAsync(ready) == true) break;
      if (elapsed.elapsed > const Duration(seconds: 5)) {
        fail('Media preparation did not reach the expected state');
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
    }
    await tester.pump();
  }

  Future<void> waitForRequest(WidgetTester tester, int count) =>
      pumpUntil(tester, () async => api.requests.length >= count);

  Future<void> waitForCleanup(
    WidgetTester tester,
    MediaFileRequest request,
  ) async {
    await pumpUntil(
      tester,
      () async => !await File(request.destination).parent.exists(),
    );
    // Another media source may intentionally still be animating its loader.
    await tester.pump();
  }

  Widget host(Widget child) => ProviderScope(
    overrides: [
      sessionReadyProvider.overrideWith(() => MutableState(true)),
      currentUserProvider.overrideWith(
        () => MutableState(
          const CurrentUser(
            id: '@alice:example.org',
            displayName: 'Alice',
            homeserver: 'https://example.org',
          ),
        ),
      ),
    ],
    child: MaterialApp(
      theme: neuTestTheme(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  Widget video(String source) => VideoMessageBubble(
    mediaSourceJson: jsonEncode({'file': jsonDecode(source)}),
    filename: 'clip.mp4',
    isMe: false,
    heroTag: 'video',
    metadata: const SizedBox.shrink(),
  );

  testWidgets('audio attachments load on play and offer retry after failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const FileMessageBubble(
          filename: 'voice.ogg',
          mimeType: 'audio/ogg',
          mediaSourceJson:
              '{"file":{"url":"mxc://example.org/audio","key":{}}}',
          isMe: false,
          metadata: SizedBox.shrink(),
        ),
      ),
    );
    expect(api.requests, isEmpty);
    expect(find.byTooltip('播放音频'), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('播放音频'));
    await tester.pump();
    await waitForRequest(tester, 1);
    expect(api.requests, hasLength(1));
    api.requests.single.fail();
    await waitForCleanup(tester, api.requests.single);
    // Cache cleanup and UI error publication finish on separate async turns.
    await pumpUntil(
      tester,
      () async => find.text('无法播放此音频').evaluate().isNotEmpty,
    );
    expect(find.text('无法播放此音频'), findsOneWidget);
    await tester.tap(find.byTooltip('重试播放'));
    await tester.pump();
    await waitForRequest(tester, 2);
    expect(api.requests, hasLength(2));
    api.requests.last.fail();
    await waitForCleanup(tester, api.requests.last);
    await pumpUntil(
      tester,
      () async => find.text('无法播放此音频').evaluate().isNotEmpty,
    );
    expect(find.text('无法播放此音频'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'generic file attachments keep their download-only presentation',
    (tester) async {
      await tester.pumpWidget(
        host(
          const FileMessageBubble(
            filename: 'document.pdf',
            mimeType: 'application/pdf',
            imageUrl: 'mxc://example.org/pdf',
            isMe: false,
            metadata: SizedBox.shrink(),
          ),
        ),
      );
      expect(find.byTooltip('播放音频'), findsNothing);
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      expect(api.requests, isEmpty);
    },
  );

  testWidgets('old video load failures do not replace a newer source', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(video('{"url":"mxc://example.org/old","key":{}}')),
    );
    await tester.pump();
    await waitForRequest(tester, 1);
    await tester.pumpWidget(
      host(video('{"url":"mxc://example.org/new","key":{}}')),
    );
    await tester.pump();
    await waitForRequest(tester, 2);
    expect(api.requests, hasLength(2));
    expect(api.requests.first.transfer.cancelled, isTrue);
    api.requests.first.fail();
    await waitForCleanup(tester, api.requests.first);
    expect(find.text('无法播放此视频'), findsNothing);
    expect(find.text('正在加载视频…'), findsOneWidget);
    api.requests.last.fail();
    await waitForCleanup(tester, api.requests.last);
    expect(find.text('无法播放此视频'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video download failure can retry with a fresh transfer', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(video('{"url":"mxc://example.org/video","key":{}}')),
    );
    await waitForRequest(tester, 1);
    api.requests.single.fail();
    await waitForCleanup(tester, api.requests.single);
    await tester.tap(find.text('无法播放此视频'));
    await tester.pump();
    await waitForRequest(tester, 2);
    expect(
      api.requests.last.transfer,
      isNot(same(api.requests.first.transfer)),
    );
    api.requests.last.fail();
    await waitForCleanup(tester, api.requests.last);
    expect(tester.takeException(), isNull);
  });

  for (final audio in [false, true]) {
    testWidgets(
      '${audio ? 'audio' : 'video'} account switch cancels pending media',
      (tester) async {
        await tester.pumpWidget(
          host(
            audio
                ? const FileMessageBubble(
                    filename: 'voice.ogg',
                    mimeType: 'audio/ogg',
                    mediaSourceJson:
                        '{"file":{"url":"mxc://example.org/audio","key":{}}}',
                    isMe: false,
                    metadata: SizedBox.shrink(),
                  )
                : video('{"url":"mxc://example.org/video","key":{}}'),
          ),
        );
        if (audio) await tester.tap(find.byTooltip('播放音频'));
        await tester.pump();
        await waitForRequest(tester, 1);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold)),
        );
        container.read(currentUserProvider.notifier).value = const CurrentUser(
          id: '@bob:example.org',
          displayName: 'Bob',
          homeserver: 'https://example.org',
        );
        await tester.pump();
        expect(api.requests.single.transfer.cancelled, isTrue);
        await waitForCleanup(tester, api.requests.single);
        expect(api.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('same-account session teardown cancels a video load', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(video('{"url":"mxc://example.org/video","key":{}}')),
    );
    await waitForRequest(tester, 1);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    );
    container.read(sessionReadyProvider.notifier).value = true;
    await tester.pump();
    container.read(sessionReadyProvider.notifier).value = false;
    await tester.pump();
    expect(api.requests.single.transfer.cancelled, isTrue);
    await waitForCleanup(tester, api.requests.single);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing a video while loading ignores its late failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(video('{"url":"mxc://example.org/video","key":{}}')),
    );
    await tester.pump();
    await waitForRequest(tester, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(api.requests.single.transfer.cancelled, isTrue);
    api.requests.single.fail();
    await waitForCleanup(tester, api.requests.single);
    expect(tester.takeException(), isNull);
  });
}
