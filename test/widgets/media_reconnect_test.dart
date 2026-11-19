import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/app_avatar.dart';

import '../helpers/neu_test_theme.dart';

class _OfflineCacheManager implements BaseCacheManager {
  int requests = 0;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    requests++;
    return Stream.error(const SocketException('Connection reset'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LogApi implements RustLibApi {
  final messages = <String>[];

  @override
  void crateApiMatrixLogAppMessage({
    required String level,
    required String tag,
    required String message,
  }) => messages.add(message);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _LogApi api;
  setUp(() {
    api = _LogApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  testWidgets(
    'failed media retries after sync reconnects without changing URL',
    (tester) async {
      final cache = _OfflineCacheManager();
      final previousCache = CachedNetworkImageProvider.defaultCacheManager;
      CachedNetworkImageProvider.defaultCacheManager = cache;
      addTearDown(() {
        CachedNetworkImageProvider.defaultCacheManager = previousCache;
        PaintingBinding.instance.imageCache.clear();
      });

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const Scaffold(
              body: AuthenticatedImageMessage(
                imageUrl: 'https://images.example/reconnect.png',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(cache.requests, 1);
      expect(find.byIcon(Icons.broken_image_rounded), findsOneWidget);
      expect(api.messages, hasLength(1));
      expect(api.messages.single, contains('error_type=SocketException'));
      tester.element(find.byType(AuthenticatedImageMessage)).markNeedsBuild();
      await tester.pumpAndSettle();
      expect(api.messages, hasLength(1));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AuthenticatedImageMessage)),
      );
      container.read(connectionProvider.notifier).value =
          AppConnectionState.disconnected;
      await tester.pump();
      container.read(connectionProvider.notifier).value =
          AppConnectionState.connected;
      await tester.pumpAndSettle();

      expect(cache.requests, 2);
      expect(api.messages, hasLength(2));
      expect(api.messages.last, contains('attempt=2'));
      // Another healthy status poll must not create a retry loop.
      container.read(connectionProvider.notifier).value =
          AppConnectionState.connected;
      await tester.pumpAndSettle();
      expect(cache.requests, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
