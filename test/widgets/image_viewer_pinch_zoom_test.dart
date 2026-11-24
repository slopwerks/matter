import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_image_preview_page.dart';
import 'package:matter/pages/chat/attachment_media_draft.dart';
import 'package:matter/pages/chat/image_zoom_frame.dart';

import '../helpers/neu_test_theme.dart';

final _testPng = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
  ),
);

/// Mirrors the viewer: a swipeable page stack plus a vertical-dismiss shell
/// around each zoomable image.
Widget _viewer({
  required bool zoomed,
  required bool multiTouch,
  required ValueChanged<bool> onZoom,
  required ValueChanged<bool> onMultiTouch,
}) {
  return MaterialApp(
    home: Scaffold(
      body: DismissibleImageGallery(
        enabled: !zoomed && !multiTouch,
        onClose: () {},
        child: PageView(
          physics: imageViewerScrollPhysics(
            zoomed: zoomed,
            multiTouch: multiTouch,
          ),
          children: [
            ZoomableImageFrame(
              active: true,
              onZoomChanged: onZoom,
              onMultiTouchChanged: onMultiTouch,
              child: const SizedBox.expand(
                child: ColoredBox(color: Colors.black),
              ),
            ),
            const SizedBox.expand(child: ColoredBox(color: Colors.blueGrey)),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a pinch zooms the image without a double tap first', (
    tester,
  ) async {
    var zoomed = false;
    var multiTouch = false;
    late StateSetter setOuter;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return _viewer(
            zoomed: zoomed,
            multiTouch: multiTouch,
            onZoom: (value) => setOuter(() => zoomed = value),
            onMultiTouch: (value) => setOuter(() => multiTouch = value),
          );
        },
      ),
    );

    final center = tester.getCenter(find.byType(ZoomableImageFrame));
    final first = await tester.startGesture(center - const Offset(24, 0));
    final second = await tester.startGesture(center + const Offset(24, 0));
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<NeverScrollableScrollPhysics>(),
      reason: 'the page swipe must yield while two fingers are down',
    );
    for (var step = 0; step < 8; step++) {
      await first.moveBy(const Offset(-7, 3));
      await second.moveBy(const Offset(7, -3));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(zoomed, isTrue, reason: 'a two finger pinch should zoom in');
    expect(multiTouch, isFalse, reason: 'the pinch lock is released again');
  });

  testWidgets('the page swipe comes back when a second finger leaves', (
    tester,
  ) async {
    var zoomed = false;
    var multiTouch = false;
    late StateSetter setOuter;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return _viewer(
            zoomed: zoomed,
            multiTouch: multiTouch,
            onZoom: (value) => setOuter(() => zoomed = value),
            onMultiTouch: (value) => setOuter(() => multiTouch = value),
          );
        },
      ),
    );

    final center = tester.getCenter(find.byType(ZoomableImageFrame));
    final first = await tester.startGesture(center - const Offset(24, 0));
    final second = await tester.startGesture(center + const Offset(24, 0));
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<NeverScrollableScrollPhysics>(),
    );

    await second.up();
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<PageScrollPhysics>(),
      reason: 'a single finger pages through the gallery again',
    );

    await first.up();
    await tester.pumpAndSettle();
    expect(zoomed, isFalse);
  });

  testWidgets('AttachmentImagePreviewPage pinch zooms directly at 1x', (
    tester,
  ) async {
    final draft = AttachmentMediaDraft();
    addTearDown(draft.dispose);
    final one = draft.forFile(
      XFile.fromData(
        _testPng,
        path: 'one.png',
        name: 'one.png',
        mimeType: 'image/png',
      ),
    );
    final two = draft.forFile(
      XFile.fromData(
        _testPng,
        path: 'two.png',
        name: 'two.png',
        mimeType: 'image/png',
      ),
    );
    one.editedBytes = _testPng;
    two.editedBytes = _testPng;
    await tester.pumpWidget(
      MaterialApp(
        theme: neuTestTheme(),
        home: AttachmentImagePreviewPage(
          draft: draft,
          images: [one, two],
          initialImage: one,
          onSend: () async => true,
          onCaptionFocus: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final frame = find.byType(InteractiveViewer);
    final center = tester.getCenter(frame);
    final first = await tester.startGesture(center - const Offset(24, 0));
    final second = await tester.startGesture(center + const Offset(24, 0));
    await tester.pump();
    for (var step = 0; step < 8; step++) {
      await first.moveBy(const Offset(-7, 3));
      await second.moveBy(const Offset(7, -3));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    final viewer = tester.widget<InteractiveViewer>(frame);
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1.1),
    );
  });
}
