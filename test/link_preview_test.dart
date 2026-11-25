import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/link_preview.dart';

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
}
