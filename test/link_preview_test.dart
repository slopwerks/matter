import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/link_preview.dart';
import 'package:matter/theme/neu_colors.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  test('server preview endpoint targets Matrix client media preview_url', () {
    final endpoint = LinkPreviewRepository.serverPreviewEndpoint(
      'https://matrix.example.org/',
      Uri.parse('https://blog.example.org/post?a=1'),
    );

    expect(
      endpoint.toString(),
      'https://matrix.example.org/_matrix/client/v1/media/preview_url'
      '?url=https%3A%2F%2Fblog.example.org%2Fpost%3Fa%3D1',
    );
  });

  test('Matrix preview JSON preserves mxc preview images', () {
    final preview = LinkPreviewRepository.parseMatrixPreview(
      Uri.parse('https://blog.example.org/post'),
      {
        'og:title': ' Cached title ',
        'og:description': 'First line\nsecond line',
        'og:site_name': 'Example Blog',
        'og:url': 'https://canonical.example.org/post',
        'og:image': 'mxc://media.example.org/abc123',
      },
    );

    expect(preview.uri.toString(), 'https://canonical.example.org/post');
    expect(preview.title, 'Cached title');
    expect(preview.description, 'First line second line');
    expect(preview.siteName, 'Example Blog');
    expect(preview.imageUrl, 'mxc://media.example.org/abc123');
  });

  testWidgets('link preview keeps its open action on a phone', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final uri = Uri.parse('https://example.test/article');
    Uri? opened;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: LinkPreviewCard(
              uri: uri,
              isMe: true,
              width: 210,
              onOpen: (uri) async => opened = uri,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byType(LinkPreviewCard);
    final context = tester.element(card);
    if (context.isMaterial) {
      final surface = tester.widget<Material>(
        find.descendant(of: card, matching: find.byType(Material)),
      );
      expect(
        surface.color,
        Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    }
    await tester.tap(find.text('example.test/article'));
    expect(opened, uri);
  });
}
