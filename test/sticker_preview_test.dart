import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/pages/chat/sticker_catalog.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/widgets/app_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('sticker preview replaces a cached MXC thumbnail with download', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const mxcUrl = 'mxc://media.example/sticker';
    const thumbnailUrl =
        'https://matrix.example/_matrix/client/v1/media/thumbnail/'
        'media.example/sticker?width=800&height=600&method=scale';
    const downloadUrl =
        'https://matrix.example/_matrix/client/v1/media/download/'
        'media.example/sticker';

    await _pumpPreview(
      tester,
      const StickerItem(
        id: 'sticker',
        label: 'sticker',
        body: 'sticker',
        imageUrl: mxcUrl,
      ),
      overrides: [
        mxcUrlCacheProvider.overrideWith(
          () => MutableState({'anonymous::$mxcUrl': thumbnailUrl}),
        ),
      ],
    );

    final original = tester.widget<AuthenticatedImageMessage>(
      find.byType(AuthenticatedImageMessage),
    );
    expect(original.imageUrl, downloadUrl);

    original.onLoaded!();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StickerFlightPreview)),
    );
    expect(
      container.read(mxcUrlCacheProvider)['anonymous::$mxcUrl'],
      downloadUrl,
    );
  });
}

Future<void> _pumpPreview(
  WidgetTester tester,
  StickerItem sticker, {
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox.square(
            dimension: 100,
            child: StickerFlightPreview(sticker: sticker),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
