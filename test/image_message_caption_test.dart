import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/image_media.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _pixels = Uint8List.fromList(
  img.encodePng(img.Image(width: 2, height: 2)),
);

Future<void> _pumpImage(
  WidgetTester tester, {
  String? caption,
  String? formattedBody,
  String filename = 'photo.png',
  bool isSticker = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: ImageMessageBubble(
              previewBytes: _pixels,
              filename: filename,
              caption: caption,
              captionFormattedBody: formattedBody,
              isMe: false,
              isSticker: isSticker,
              heroTag: 'received-image',
              metadata: const Text('12:00'),
              displaySize: const Size(160, 120),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('received image and real caption share one bubble', (
    tester,
  ) async {
    await _pumpImage(tester, caption: 'A day at the beach');

    final bubble = find.byKey(const ValueKey('image-caption-bubble'));
    expect(bubble, findsOneWidget);
    expect(
      find.descendant(of: bubble, matching: find.byType(ChatMediaImage)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bubble, matching: find.text('A day at the beach')),
      findsOneWidget,
    );
    expect(find.text('photo.png'), findsNothing);
    expect(find.text('12:00'), findsOneWidget);
    expect(
      tester
          .widgetList<GestureDetector>(
            find.ancestor(of: bubble, matching: find.byType(GestureDetector)),
          )
          .any((detector) => detector.onTap != null),
      isTrue,
      reason: 'The image viewer tap still wraps the captioned bubble.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('filename and blank captions never create a caption bubble', (
    tester,
  ) async {
    for (final caption in <String?>[null, '', '  \n ']) {
      await _pumpImage(tester, caption: caption);
      expect(find.byKey(const ValueKey('image-caption-bubble')), findsNothing);
      expect(find.byType(ImageMessageCaption), findsNothing);
      expect(find.text('photo.png'), findsNothing);
      expect(find.byType(ChatMediaImage), findsOneWidget);
      expect(find.byType(Hero), findsOneWidget);
      expect(
        tester
            .widgetList<GestureDetector>(find.byType(GestureDetector))
            .any((detector) => detector.onTap != null),
        isTrue,
        reason: 'Plain images retain their viewer gesture.',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('formatted body alone does not turn a filename into a caption', (
    tester,
  ) async {
    await _pumpImage(tester, formattedBody: '<strong>photo.png</strong>');
    expect(find.byType(ImageMessageCaption), findsNothing);
    expect(find.text('photo.png'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stickers do not gain image captions', (tester) async {
    await _pumpImage(tester, caption: 'Sticker filename', isSticker: true);
    expect(find.byType(ImageMessageCaption), findsNothing);
    expect(find.byType(ChatMediaImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
