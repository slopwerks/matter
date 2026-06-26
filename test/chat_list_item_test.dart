import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/src/rust/api/matrix.dart';

ChatRoom room({
  required String type,
  String? sender,
  String state = 'joined',
}) => ChatRoom(
  id: '!room:example.org',
  name: '测试房间',
  lastMessage: '你好',
  lastMessageSender: sender,
  lastMessageTime: '0',
  unreadCount: 0,
  roomType: type,
  isEncrypted: false,
  roomState: state,
);

void main() {
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
