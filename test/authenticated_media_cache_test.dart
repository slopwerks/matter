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

  test('authenticated media cache manager supports resized images', () {
    final manager = authenticatedMediaCacheManager(
      url: 'https://example.org/_matrix/client/v1/media/thumbnail/server/id',
      userId: '@alice:example.org',
      homeserver: 'https://example.org',
    );

    expect(manager, isA<ImageCacheManager>());
  });
}
