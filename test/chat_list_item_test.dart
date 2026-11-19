import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatRoom room({
  required String type,
  String? sender,
  String state = 'joined',
  int unreadCount = 0,
}) => ChatRoom(
  id: '!room:example.org',
  name: '测试房间',
  lastMessage: '你好',
  lastMessageSender: sender,
  lastMessageTime: '0',
  lastEventId: '',
  unreadCount: unreadCount,
  isMarkedUnread: false,
  roomType: type,
  isEncrypted: false,
  isMuted: false,
  roomState: state,
);

void main() {
  for (final brightness in Brightness.values) {
    for (final state in ['joined', 'invited', 'knocked']) {
      testWidgets('Material $brightness $state row fits narrow enlarged text', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: buildMaterialTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    ChatListItem(
                      room: room(
                        type: 'group',
                        sender: '小林',
                        state: state,
                        unreadCount: state == 'joined' ? 99 : 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('测试房间'), findsOneWidget);
        if (state == 'joined') {
          expect(find.text('小林：你好'), findsOneWidget);
          expect(find.text('99'), findsOneWidget);
        } else if (state == 'invited') {
          expect(find.text('接受'), findsOneWidget);
          expect(find.text('拒绝'), findsOneWidget);
        } else {
          expect(find.text('撤回'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('group preview includes the last message sender', () {
    expect(chatListPreview(room(type: 'group', sender: '小明')), '小明：你好');
  });

  test('group preview labels the current user as me', () {
    expect(chatListPreview(room(type: 'group', sender: '我')), '我：你好');
  });

  test('dm preview does not repeat the sender', () {
    expect(chatListPreview(room(type: 'dm', sender: '小明')), '你好');
  });

  test('group preview falls back when sender is unavailable', () {
    expect(chatListPreview(room(type: 'group')), '你好');
  });

  test('invited and knocked rooms show membership status previews', () {
    expect(chatListPreview(room(type: 'group', state: 'invited')), '邀请你加入');
    expect(chatListPreview(room(type: 'group', state: 'knocked')), '等待对方批准');
  });
}
