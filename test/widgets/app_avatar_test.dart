import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/widgets/app_avatar.dart';

import '../helpers/neu_test_theme.dart';
import '../support/temp_path_provider.dart';

final _avatarPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _AvatarCacheManager implements BaseCacheManager, ImageCacheManager {
  _AvatarCacheManager(this.info);
  final FileInfo info;

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) => Stream.value(info);

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      getImageFile(url, key: key, headers: headers, withProgress: withProgress);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('avatar initials and size follow the supplied fallback', (
    tester,
  ) async {
    for (final (fallback, initials, size) in [
      ('Alice', 'A', 32.0),
      ('Alice Smith', 'AS', 48.0),
      ('Alice  Bob', 'AB', 64.0),
      ('', '?', 32.0),
    ]) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: AppAvatar(fallback: fallback, size: size),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text(initials), findsOneWidget, reason: fallback);
      expect(tester.getSize(find.byType(AppAvatar)), Size(size, size));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'cached mxc avatar resolves synchronously without spinner or rebuild decode',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('avatar_test_');
      installTempPathProvider(tempDir);
      final cachedFile = await tester.runAsync(() async {
        final fs = IOFileSystem(tempDir.path);
        final file = await fs.createFile('a.png');
        await file.writeAsBytes(_avatarPng);
        return file;
      });
      final prevCache = CachedNetworkImageProvider.defaultCacheManager;
      const mxcUrl = 'mxc://example.org/avatar';
      const httpUrl = 'https://example.org/avatar.png';
      CachedNetworkImageProvider.defaultCacheManager = _AvatarCacheManager(
        FileInfo(
          cachedFile!,
          FileSource.Cache,
          DateTime.now().add(const Duration(days: 1)),
          httpUrl,
        ),
      );
      addTearDown(() {
        CachedNetworkImageProvider.defaultCacheManager = prevCache;
        PaintingBinding.instance.imageCache.clear();
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      var avatarSize = 36.0;
      late StateSetter updateSize;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mxcUrlCacheProvider.overrideWith(
              () => MutableState({'anonymous::$mxcUrl|96x96': httpUrl}),
            ),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  updateSize = setState;
                  return AppAvatar(
                    fallback: 'Alice',
                    url: mxcUrl,
                    size: avatarSize,
                  );
                },
              ),
            ),
          ),
        ),
      );
      // Synchronous cache resolution must mount CachedNetworkImage on frame 0
      // with zero spinner flash.
      expect(find.byType(CachedNetworkImage), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.byType(RawImage), findsOneWidget);

      final imageKey = ValueKey('avatar-image:$httpUrl');
      final imageState = tester.state(find.byKey(imageKey));
      updateSize(() => avatarSize = 48.0);
      await tester.pump();
      expect(tester.state(find.byKey(imageKey)), same(imageState));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
}
