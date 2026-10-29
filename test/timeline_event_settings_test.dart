import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/providers/timeline_event_settings_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';

ChatMessage _createEvent({
  required String id,
  required String content,
  String? mimeType,
}) {
  return ChatMessage(
    id: id,
    senderId: '@user:server.org',
    senderName: 'User',
    content: content,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: '1700000000000',
    isMe: false,
    msgType: MessageType.event,
    mimeType: mimeType,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 5,
  );
}

ChatMessage _createText({required String id, required String content}) {
  return ChatMessage(
    id: id,
    senderId: '@user:server.org',
    senderName: 'User',
    content: content,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: '1700000000000',
    isMe: false,
    msgType: MessageType.text,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 5,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('classifyTimelineEvent', () {
    test('classifies by mimeType correctly', () {
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '1',
            content: 'Alice 更改了头像',
            mimeType: 'm.room.member:avatar',
          ),
        ),
        TimelineEventCategory.memberAvatar,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '2',
            content: 'Alice 设置昵称为: 小爱',
            mimeType: 'm.room.member:displayname',
          ),
        ),
        TimelineEventCategory.memberDisplayName,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '3',
            content: 'Alice 加入了房间',
            mimeType: 'm.room.member:join',
          ),
        ),
        TimelineEventCategory.memberJoinLeave,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '4',
            content: 'Alice 离开了房间',
            mimeType: 'm.room.member:leave',
          ),
        ),
        TimelineEventCategory.memberJoinLeave,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '5',
            content: 'Alice 被移出房间',
            mimeType: 'm.room.member:kick',
          ),
        ),
        TimelineEventCategory.memberInviteBan,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '6',
            content: 'Alice 被封禁',
            mimeType: 'm.room.member:ban',
          ),
        ),
        TimelineEventCategory.memberInviteBan,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '7',
            content: 'Alice 更改了房间头像',
            mimeType: 'm.room.avatar',
          ),
        ),
        TimelineEventCategory.roomAvatar,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '8',
            content: 'Alice 将房间名称更改为: 测试群',
            mimeType: 'm.room.name',
          ),
        ),
        TimelineEventCategory.roomNameTopic,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '9',
            content: '已启用端到端加密',
            mimeType: 'm.room.encryption',
          ),
        ),
        TimelineEventCategory.roomSecurity,
      );
      expect(
        classifyTimelineEvent(
          _createEvent(
            id: '10',
            content: 'Alice 发起了通话邀请',
            mimeType: 'm.call.invite',
          ),
        ),
        TimelineEventCategory.call,
      );
    });

    test('classifies legacy events without mimeType from content', () {
      expect(
        classifyTimelineEvent(_createEvent(id: '1', content: 'Alice 更改了头像')),
        TimelineEventCategory.memberAvatar,
      );
      expect(
        classifyTimelineEvent(_createEvent(id: '2', content: '房间头像已更改')),
        TimelineEventCategory.roomAvatar,
      );
      expect(
        classifyTimelineEvent(_createEvent(id: '3', content: '房间名称更改为: 新群名')),
        TimelineEventCategory.roomNameTopic,
      );
      expect(
        classifyTimelineEvent(_createEvent(id: '4', content: 'Alice 加入了房间')),
        TimelineEventCategory.memberJoinLeave,
      );
      expect(
        classifyTimelineEvent(_createEvent(id: '5', content: 'Alice 被移出房间')),
        TimelineEventCategory.memberInviteBan,
      );
      expect(
        classifyTimelineEvent(_createEvent(id: '6', content: '房间已创建')),
        TimelineEventCategory.roomSecurity,
      );
    });
  });

  group('TimelineEventSettings visibility filtering', () {
    test('non-event messages are always visible', () {
      const settings = TimelineEventSettings(
        preset: TimelineEventPreset.off,
        showMemberAvatar: false,
        showMemberDisplayName: false,
        showMemberJoinLeave: false,
        showMemberInviteBan: false,
        showRoomAvatar: false,
        showRoomNameTopic: false,
        showRoomSecurity: false,
        showCallEvents: false,
        showOtherEvents: false,
      );
      expect(
        settings.isEventVisible(_createText(id: 't1', content: 'hello')),
        isTrue,
      );
    });

    test('recommended preset filters personal member avatar/name noise but keeps room events', () {
      const settings = TimelineEventSettings();
      expect(settings.preset, TimelineEventPreset.recommended);
      final memberAvatarEvent = _createEvent(
        id: '1',
        content: 'Alice 更换了头像',
        mimeType: 'm.room.member:avatar',
      );
      final memberNameEvent = _createEvent(
        id: '2',
        content: 'Alice 设置昵称为: 小爱',
        mimeType: 'm.room.member:displayname',
      );
      final joinEvent = _createEvent(
        id: '3',
        content: 'Bob 加入了房间',
        mimeType: 'm.room.member:join',
      );
      final roomAvatarEvent = _createEvent(
        id: '4',
        content: 'Alice 更改了房间头像',
        mimeType: 'm.room.avatar',
      );

      // Recommended hides high-noise personal profile changes
      expect(settings.isEventVisible(memberAvatarEvent), isFalse);
      expect(settings.isEventVisible(memberNameEvent), isFalse);

      // But keeps room avatar and member joins
      expect(settings.isEventVisible(joinEvent), isTrue);
      expect(settings.isEventVisible(roomAvatarEvent), isTrue);
    });

    test('all preset shows personal profile changes as well', () {
      const settings = TimelineEventSettings(
        preset: TimelineEventPreset.all,
        showMemberAvatar: true,
        showMemberDisplayName: true,
        showMemberJoinLeave: true,
        showMemberInviteBan: true,
        showRoomAvatar: true,
        showRoomNameTopic: true,
        showRoomSecurity: true,
        showCallEvents: true,
        showOtherEvents: true,
      );
      final memberAvatarEvent = _createEvent(
        id: '1',
        content: 'Alice 更换了头像',
        mimeType: 'm.room.member:avatar',
      );
      expect(settings.isEventVisible(memberAvatarEvent), isTrue);
    });

    test('minimal preset hides member profile and join/leave', () {
      const settings = TimelineEventSettings(
        preset: TimelineEventPreset.minimal,
        showMemberAvatar: false,
        showMemberDisplayName: false,
        showMemberJoinLeave: false,
        showMemberInviteBan: true,
        showRoomAvatar: true,
        showRoomNameTopic: true,
        showRoomSecurity: true,
        showCallEvents: true,
        showOtherEvents: false,
      );
      final avatarEvent = _createEvent(
        id: '1',
        content: 'Alice 更换了头像',
        mimeType: 'm.room.member:avatar',
      );
      final joinEvent = _createEvent(
        id: '2',
        content: 'Alice 加入了房间',
        mimeType: 'm.room.member:join',
      );
      final kickEvent = _createEvent(
        id: '3',
        content: 'Alice 被移出房间',
        mimeType: 'm.room.member:kick',
      );
      final roomAvatarEvent = _createEvent(
        id: '4',
        content: 'Alice 更改了房间头像',
        mimeType: 'm.room.avatar',
      );

      expect(settings.isEventVisible(avatarEvent), isFalse);
      expect(settings.isEventVisible(joinEvent), isFalse);
      expect(settings.isEventVisible(kickEvent), isTrue);
      expect(settings.isEventVisible(roomAvatarEvent), isTrue);
    });

    test('off preset hides all events', () {
      const settings = TimelineEventSettings(
        preset: TimelineEventPreset.off,
        showMemberAvatar: false,
        showMemberDisplayName: false,
        showMemberJoinLeave: false,
        showMemberInviteBan: false,
        showRoomAvatar: false,
        showRoomNameTopic: false,
        showRoomSecurity: false,
        showCallEvents: false,
        showOtherEvents: false,
      );
      final avatarEvent = _createEvent(
        id: '1',
        content: 'Alice 更换了头像',
        mimeType: 'm.room.member:avatar',
      );
      expect(settings.isEventVisible(avatarEvent), isFalse);
    });
  });

  group('TimelineEventSettingsNotifier', () {
    test('updates preset and persists', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(timelineEventSettingsProvider.notifier);
      await notifier.setPreset(TimelineEventPreset.minimal);

      final state = container.read(timelineEventSettingsProvider);
      expect(state.preset, TimelineEventPreset.minimal);
      expect(state.showMemberAvatar, isFalse);
      expect(state.showRoomAvatar, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('timeline_events_preset'), 'minimal');
      expect(prefs.getBool('timeline_events_member_avatar'), isFalse);
      expect(prefs.getBool('timeline_events_room_avatar'), isTrue);
    });

    test('toggling individual switch updates to custom preset', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(timelineEventSettingsProvider.notifier);
      await notifier.setPreset(TimelineEventPreset.all);
      await notifier.setShowMemberAvatar(false);

      final state = container.read(timelineEventSettingsProvider);
      expect(state.preset, TimelineEventPreset.custom);
      expect(state.showMemberAvatar, isFalse);
      expect(state.showMemberDisplayName, isTrue);
      expect(state.showMemberJoinLeave, isTrue);
    });

    test(
      'supports per-room override settings without modifying global',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final notifier = container.read(timelineEventSettingsProvider.notifier);
        const roomId = '!special:server.org';

        // Initially follows global (recommended has showRoomAvatar true)
        expect(
          container.read(timelineEventSettingsProvider).hasRoomOverride(roomId),
          isFalse,
        );
        expect(
          container
              .read(roomTimelineEventSettingsProvider(roomId))
              .showRoomAvatar,
          isTrue,
        );

        // Enable room override and set preset to off
        await notifier.enableRoomOverride(roomId);
        expect(
          container.read(timelineEventSettingsProvider).hasRoomOverride(roomId),
          isTrue,
        );

        await notifier.setRoomPreset(roomId, TimelineEventPreset.off);

        // Room override is off
        final roomSettings = container.read(
          roomTimelineEventSettingsProvider(roomId),
        );
        expect(roomSettings.preset, TimelineEventPreset.off);
        expect(roomSettings.showRoomAvatar, isFalse);

        // Global is still recommended
        final globalState = container.read(timelineEventSettingsProvider);
        expect(globalState.global.preset, TimelineEventPreset.recommended);
        expect(globalState.global.showRoomAvatar, isTrue);

        // Clear override restores room to following global
        await notifier.clearRoomOverride(roomId);
        expect(
          container.read(timelineEventSettingsProvider).hasRoomOverride(roomId),
          isFalse,
        );
        expect(
          container
              .read(roomTimelineEventSettingsProvider(roomId))
              .showRoomAvatar,
          isTrue,
        );
      },
    );
  });
}
