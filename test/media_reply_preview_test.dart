import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/timeline/timeline_message_group.dart';
import 'package:matter/pages/chat/timeline/timeline_clustering.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/theme/material_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

rust.ChatMessage message(String id, rust.MessageType type, {String? reply}) =>
    rust.ChatMessage(
      id: id,
      senderId: '@me:example.org',
      senderName: 'Me',
      content: 'Original message',
      mentionedUserIds: const [],
      mentionsRoom: false,
      timestamp: '1',
      isMe: true,
      msgType: type,
      inReplyTo: reply,
      imageUrl: type == rust.MessageType.text
          ? null
          : 'mxc://example.org/media',
      isEdited: false,
      editHistory: const [],
      reactions: const [],
      readers: const [],
      totalMembers: 2,
    );
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final type in [
    rust.MessageType.image,
    rust.MessageType.sticker,
    rust.MessageType.text,
  ]) {
    testWidgets('$type displays a tappable reply reference', (tester) async {
      final original = message(r'$target', rust.MessageType.text);
      final media = message(r'$remote-media', type, reply: original.id);
      String? jumped;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildMaterialTheme(Brightness.light),
            home: Scaffold(
              body: MessageGroupWidget(
                group: MessageGroup(
                  senderId: media.senderId,
                  senderName: media.senderName,
                  isMe: true,
                  messages: [media],
                ),
                showAvatar: false,
                roomId: '!room:example.org',
                messageIndex: {original.id: original, media.id: media},
                localImagePreviews: {
                  media.id: Uint8List.fromList(
                    img.encodePng(img.Image(width: 2, height: 2)),
                  ),
                },
                onMessageJumpRequested: (id) => jumped = id,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final preview = find.byKey(ValueKey('reply-preview:${original.id}'));
      expect(preview, findsOneWidget);
      await tester.tap(preview);
      expect(jumped, original.id);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
