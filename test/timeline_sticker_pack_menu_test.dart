import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/timeline/timeline_message_menu.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

ChatMessage _sticker() => ChatMessage(
  id: r'$sticker',
  senderId: '@bob:example.org',
  senderName: 'Bob',
  content: 'cat',
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '100',
  isMe: false,
  msgType: MessageType.sticker,
  imageUrl: 'mxc://example.org/cat',
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

Widget _menu({required bool withAdd}) => MaterialApp(
  theme: neuTestTheme(),
  home: Scaffold(
    body: TimelineMessageMenu(
      message: _sticker(),
      isMe: false,
      bubbleRect: const Rect.fromLTWH(0, 0, 100, 40),
      onClose: () {},
      onCopy: () {},
      onReply: () {},
      onForward: () {},
      onEdit: () {},
      onRecall: () {},
      isPinned: null,
      pinStateLoading: false,
      onPin: null,
      onReact: (_) {},
      onShowFullEmojiPicker: () {},
      onAddStickerPack: withAdd ? () {} : null,
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('sticker messages offer adding the whole pack', (tester) async {
    await tester.pumpWidget(_menu(withAdd: true));
    await tester.pumpAndSettle();
    expect(find.text('添加贴纸包'), findsOneWidget);
  });

  testWidgets('the entry is hidden when there is no pack to add', (
    tester,
  ) async {
    await tester.pumpWidget(_menu(withAdd: false));
    await tester.pumpAndSettle();
    expect(find.text('添加贴纸包'), findsNothing);
  });
}
