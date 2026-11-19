import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/image_message_collection.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

import 'helpers/neu_test_theme.dart';

rust.ChatMessage _picture(int index) => rust.ChatMessage(
  id: '$index',
  senderId: 'alice',
  senderName: 'Alice',
  content: '$index.png',
  timestamp: '1000',
  isMe: false,
  msgType: rust.MessageType.image,
  imageUrl: 'mxc://example.org/$index',
  imageWidth: 1200,
  imageHeight: 800,
  mentionedUserIds: const [],
  mentionsRoom: false,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

void main() {
  for (final reducedMotion in [false, true]) {
    testWidgets('image stack motion respects reduced motion ($reducedMotion)', (
      tester,
    ) async {
      final messages = [
        for (var index = 0; index < 5; index++) _picture(index),
      ];
      final anchors = {for (final message in messages) message.id: GlobalKey()};
      await tester.pumpWidget(
        MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reducedMotion),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ImageMessageCollection(
                      messages: messages,
                      selected: messages.last,
                      album: false,
                      isMe: false,
                      borderRadius: BorderRadius.circular(16),
                      shadows: const [],
                      anchors: anchors,
                      metadata: const SizedBox.shrink(),
                      captionBuilder: (_) => null,
                      collapsedBuilder: (content) => content,
                      tileBuilder: (message, size, radius) => SizedBox(
                        width: size.width,
                        height: size.height,
                        child: ColoredBox(
                          color: Colors.blue,
                          child: Text(message.id),
                        ),
                      ),
                      expandedBuilder: (button) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          button,
                          for (final message in messages)
                            SizedBox(
                              key: anchors[message.id],
                              width: 270,
                              height: 100,
                              child: ColoredBox(
                                color: Colors.blue,
                                child: Text(message.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final collection = find.byType(ImageMessageCollection);
      final foldedHeight = tester.getSize(collection).height;
      await tester.tap(find.byTooltip('展开全部5张图片'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final intermediateHeight = tester.getSize(collection).height;
      await tester.pumpAndSettle();
      final expandedHeight = tester.getSize(collection).height;
      expect(expandedHeight, greaterThan(foldedHeight));
      if (reducedMotion) {
        expect(intermediateHeight, closeTo(expandedHeight, .001));
      } else {
        expect(intermediateHeight, greaterThan(foldedHeight));
        expect(intermediateHeight, lessThan(expandedHeight));
      }
      final button = find.byKey(const ValueKey('image-stack-toggle:0'));
      expect(
        find.descendant(
          of: button,
          matching: find.byIcon(CupertinoIcons.chevron_down),
        ),
        findsOneWidget,
      );
      expect(anchors.values.every((key) => key.currentContext != null), isTrue);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final collapsingHeight = tester.getSize(collection).height;
      await tester.pumpAndSettle();
      if (!reducedMotion) {
        expect(collapsingHeight, greaterThan(foldedHeight));
        expect(collapsingHeight, lessThan(expandedHeight));
      }
      expect(tester.getSize(collection).height, closeTo(foldedHeight, .001));
      // Reverse a transition before it finishes: only one set of anchors stays alive.
      await tester.tap(find.byTooltip('展开全部5张图片'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byTooltip('收起图片，共5张'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-stack')), findsOneWidget);
      expect(anchors.values.every((key) => key.currentContext != null), isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
