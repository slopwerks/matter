import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/authenticated_media_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('detects authenticated Matrix media URLs', () {
    expect(
      isMatrixAuthenticatedMediaUrl(
        'https://example.org/_matrix/client/v1/media/download/server/id',
      ),
      isTrue,
    );
    expect(
      isMatrixAuthenticatedMediaUrl(
        'https://example.org/_matrix/media/v3/download/server/id',
      ),
      isFalse,
    );
  });

  test('only trusts Matrix media on the active homeserver', () {
    const homeserver = 'https://matrix.example.org:8448';
    expect(
      isCurrentHomeserverMatrixMediaUrl(
        'https://matrix.example.org:8448/_matrix/client/v1/media/download/s/id',
        homeserver,
      ),
      isTrue,
    );
    expect(
      isCurrentHomeserverMatrixMediaUrl(
        'https://attacker.example/_matrix/client/v1/media/download/s/id',
        homeserver,
      ),
      isFalse,
    );
    expect(
      isCurrentHomeserverMatrixMediaUrl(
        'http://matrix.example.org:8448/_matrix/client/v1/media/download/s/id',
        homeserver,
      ),
      isFalse,
    );
  });

  test('cache key is scoped by account and homeserver', () {
    const url = 'https://example.org/_matrix/client/v1/media/download/s/id';

    final aliceKey = authenticatedMediaCacheKey(
      url: url,
      userId: '@alice:example.org',
      homeserver: 'https://example.org',
    );
    final bobKey = authenticatedMediaCacheKey(
      url: url,
      userId: '@bob:example.org',
      homeserver: 'https://example.org',
    );
    final otherHomeserverKey = authenticatedMediaCacheKey(
      url: url,
      userId: '@alice:example.org',
      homeserver: 'https://matrix.example.org',
    );

    expect(aliceKey, isNotNull);
    expect(aliceKey, isNot(bobKey));
    expect(aliceKey, isNot(otherHomeserverKey));
  });

  test('non authenticated media keeps the default cache key behavior', () {
    expect(
      authenticatedMediaCacheKey(
        url: 'https://example.org/image.png',
        userId: '@alice:example.org',
        homeserver: 'https://example.org',
      ),
      isNull,
    );
  });

  test('session cleanup waits for media directory initialization', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'matter-cache-lifecycle-',
    );
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final requested = Completer<void>();
    final release = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getTemporaryDirectory') {
            if (!requested.isCompleted) requested.complete();
            await release.future;
          }
          return temporary.path;
        });
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await temporary.delete(recursive: true);
    });
    var finished = false;
    final clearing = clearAuthenticatedMediaCacheForSession(
      userId: '@cleanup:example.org',
      homeserver: 'https://example.org',
    ).then((_) => finished = true);
    await requested.future;
    // Let metadata cleanup settle while the file directory is still blocked.
    await pumpEventQueue(times: 100);
    expect(
      finished,
      isFalse,
      reason:
          'cleanup must not outlive the directory initialization it started',
    );
    release.complete();
    await clearing;
    expect(finished, isTrue);
  });

  test('authenticated media cache manager supports resized images', () {
    final manager = authenticatedMediaCacheManager(
      url: 'https://example.org/_matrix/client/v1/media/thumbnail/server/id',
      userId: '@alice:example.org',
      homeserver: 'https://example.org',
    );

    expect(manager, isA<ImageCacheManager>());
  });
}
