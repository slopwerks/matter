import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/rust/api/matrix.dart';

/// 预设模式
enum TimelineEventPreset {
  all, // 全部显示
  recommended, // 推荐（过滤高频个人头像与昵称改动，保留房间事件与进出通知）
  minimal, // 极简（隐藏成员进出与个人资料，仅保留重要群变动与管理操作）
  off, // 全部隐藏（纯聊天消息）
  custom, // 自定义
}

/// 时间线事件细分分类
enum TimelineEventCategory {
  memberAvatar, // 成员更换个人头像
  memberDisplayName, // 成员更改昵称
  memberJoinLeave, // 成员加入、离开、敲门申请
  memberInviteBan, // 邀请、移出、封禁、解封
  roomAvatar, // 房间头像变更
  roomNameTopic, // 房间名称、主题、主要别名
  roomSecurity, // 加密、创建、加入规则、权限级别、置顶
  call, // 通话邀请与通知
  other, // 其他状态事件（历史可见性、升级、第三方邀请等）
}

TimelineEventCategory classifyTimelineEvent(ChatMessage message) {
  final mime = message.mimeType;
  if (mime != null) {
    switch (mime) {
      case 'm.room.member:avatar':
        return TimelineEventCategory.memberAvatar;
      case 'm.room.member:displayname':
        return TimelineEventCategory.memberDisplayName;
      case 'm.room.member:join':
      case 'm.room.member:leave':
      case 'm.room.member:knock':
        return TimelineEventCategory.memberJoinLeave;
      case 'm.room.member:invite':
      case 'm.room.member:kick':
      case 'm.room.member:ban':
      case 'm.room.member:unban':
      case 'm.room.third_party_invite':
        return TimelineEventCategory.memberInviteBan;
      case 'm.room.avatar':
        return TimelineEventCategory.roomAvatar;
      case 'm.room.name':
      case 'm.room.topic':
      case 'm.room.canonical_alias':
      case 'm.room.pinned_events':
        return TimelineEventCategory.roomNameTopic;
      case 'm.room.encryption':
      case 'm.room.create':
      case 'm.room.join_rules':
      case 'm.room.power_levels':
      case 'm.room.history_visibility':
      case 'm.room.tombstone':
      case 'm.room.server_acl':
        return TimelineEventCategory.roomSecurity;
      case 'm.call.invite':
      case 'm.call.notification':
        return TimelineEventCategory.call;
    }
  }

  // Fallback content parsing for legacy or custom events
  final content = message.content;
  if (content.contains('房间头像')) {
    return TimelineEventCategory.roomAvatar;
  }
  if (content.contains('房间名称') ||
      content.contains('房间主题') ||
      content.contains('主题更改') ||
      content.contains('房间别名')) {
    return TimelineEventCategory.roomNameTopic;
  }
  if (content.contains('头像')) {
    return TimelineEventCategory.memberAvatar;
  }
  if (content.contains('昵称')) {
    return TimelineEventCategory.memberDisplayName;
  }
  if (content.contains('封禁') ||
      content.contains('移出') ||
      content.contains('踢出') ||
      content.contains('第三方邀请')) {
    return TimelineEventCategory.memberInviteBan;
  }
  if (content.contains('加入') ||
      content.contains('离开') ||
      content.contains('退出') ||
      content.contains('邀请') ||
      content.contains('请求加入')) {
    return TimelineEventCategory.memberJoinLeave;
  }
  if (content.contains('加密') ||
      content.contains('创建') ||
      content.contains('权限') ||
      content.contains('规则') ||
      content.contains('可见性') ||
      content.contains('置顶') ||
      content.contains('停用并升级')) {
    return TimelineEventCategory.roomSecurity;
  }
  if (content.contains('通话')) {
    return TimelineEventCategory.call;
  }
  return TimelineEventCategory.other;
}

@immutable
class TimelineEventSettings {
  final TimelineEventPreset preset;
  final bool showMemberAvatar;
  final bool showMemberDisplayName;
  final bool showMemberJoinLeave;
  final bool showMemberInviteBan;
  final bool showRoomAvatar;
  final bool showRoomNameTopic;
  final bool showRoomSecurity;
  final bool showCallEvents;
  final bool showOtherEvents;

  const TimelineEventSettings({
    this.preset = TimelineEventPreset.recommended,
    this.showMemberAvatar = false,
    this.showMemberDisplayName = false,
    this.showMemberJoinLeave = true,
    this.showMemberInviteBan = true,
    this.showRoomAvatar = true,
    this.showRoomNameTopic = true,
    this.showRoomSecurity = true,
    this.showCallEvents = true,
    this.showOtherEvents = true,
  });

  bool isEventVisible(ChatMessage message) {
    if (message.msgType != MessageType.event) return true;
    final category = classifyTimelineEvent(message);
    return switch (category) {
      TimelineEventCategory.memberAvatar => showMemberAvatar,
      TimelineEventCategory.memberDisplayName => showMemberDisplayName,
      TimelineEventCategory.memberJoinLeave => showMemberJoinLeave,
      TimelineEventCategory.memberInviteBan => showMemberInviteBan,
      TimelineEventCategory.roomAvatar => showRoomAvatar,
      TimelineEventCategory.roomNameTopic => showRoomNameTopic,
      TimelineEventCategory.roomSecurity => showRoomSecurity,
      TimelineEventCategory.call => showCallEvents,
      TimelineEventCategory.other => showOtherEvents,
    };
  }

  TimelineEventSettings copyWith({
    TimelineEventPreset? preset,
    bool? showMemberAvatar,
    bool? showMemberDisplayName,
    bool? showMemberJoinLeave,
    bool? showMemberInviteBan,
    bool? showRoomAvatar,
    bool? showRoomNameTopic,
    bool? showRoomSecurity,
    bool? showCallEvents,
    bool? showOtherEvents,
  }) {
    return TimelineEventSettings(
      preset: preset ?? this.preset,
      showMemberAvatar: showMemberAvatar ?? this.showMemberAvatar,
      showMemberDisplayName:
          showMemberDisplayName ?? this.showMemberDisplayName,
      showMemberJoinLeave: showMemberJoinLeave ?? this.showMemberJoinLeave,
      showMemberInviteBan: showMemberInviteBan ?? this.showMemberInviteBan,
      showRoomAvatar: showRoomAvatar ?? this.showRoomAvatar,
      showRoomNameTopic: showRoomNameTopic ?? this.showRoomNameTopic,
      showRoomSecurity: showRoomSecurity ?? this.showRoomSecurity,
      showCallEvents: showCallEvents ?? this.showCallEvents,
      showOtherEvents: showOtherEvents ?? this.showOtherEvents,
    );
  }

  Map<String, dynamic> toJson() => {
    'preset': preset.name,
    'showMemberAvatar': showMemberAvatar,
    'showMemberDisplayName': showMemberDisplayName,
    'showMemberJoinLeave': showMemberJoinLeave,
    'showMemberInviteBan': showMemberInviteBan,
    'showRoomAvatar': showRoomAvatar,
    'showRoomNameTopic': showRoomNameTopic,
    'showRoomSecurity': showRoomSecurity,
    'showCallEvents': showCallEvents,
    'showOtherEvents': showOtherEvents,
  };

  factory TimelineEventSettings.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    final preset = switch (presetName) {
      'all' => TimelineEventPreset.all,
      'minimal' => TimelineEventPreset.minimal,
      'off' => TimelineEventPreset.off,
      'custom' => TimelineEventPreset.custom,
      _ => TimelineEventPreset.recommended,
    };
    final legacyProfile = json['showMemberProfile'] as bool?;
    final legacyRoomInfo = json['showRoomInfo'] as bool?;

    return TimelineEventSettings(
      preset: preset,
      showMemberAvatar:
          json['showMemberAvatar'] as bool? ?? legacyProfile ?? false,
      showMemberDisplayName:
          json['showMemberDisplayName'] as bool? ?? legacyProfile ?? false,
      showMemberJoinLeave: json['showMemberJoinLeave'] as bool? ?? true,
      showMemberInviteBan: json['showMemberInviteBan'] as bool? ?? true,
      showRoomAvatar: json['showRoomAvatar'] as bool? ?? legacyRoomInfo ?? true,
      showRoomNameTopic:
          json['showRoomNameTopic'] as bool? ?? legacyRoomInfo ?? true,
      showRoomSecurity: json['showRoomSecurity'] as bool? ?? true,
      showCallEvents: json['showCallEvents'] as bool? ?? true,
      showOtherEvents: json['showOtherEvents'] as bool? ?? true,
    );
  }

  static TimelineEventPreset resolvePreset({
    required bool showMemberAvatar,
    required bool showMemberDisplayName,
    required bool showMemberJoinLeave,
    required bool showMemberInviteBan,
    required bool showRoomAvatar,
    required bool showRoomNameTopic,
    required bool showRoomSecurity,
    required bool showCallEvents,
    required bool showOtherEvents,
  }) {
    if (!showMemberAvatar &&
        !showMemberDisplayName &&
        !showMemberJoinLeave &&
        !showMemberInviteBan &&
        !showRoomAvatar &&
        !showRoomNameTopic &&
        !showRoomSecurity &&
        !showCallEvents &&
        !showOtherEvents) {
      return TimelineEventPreset.off;
    }
    if (showMemberAvatar &&
        showMemberDisplayName &&
        showMemberJoinLeave &&
        showMemberInviteBan &&
        showRoomAvatar &&
        showRoomNameTopic &&
        showRoomSecurity &&
        showCallEvents &&
        showOtherEvents) {
      return TimelineEventPreset.all;
    }
    if (!showMemberAvatar &&
        !showMemberDisplayName &&
        showMemberJoinLeave &&
        showMemberInviteBan &&
        showRoomAvatar &&
        showRoomNameTopic &&
        showRoomSecurity &&
        showCallEvents &&
        showOtherEvents) {
      return TimelineEventPreset.recommended;
    }
    if (!showMemberAvatar &&
        !showMemberDisplayName &&
        !showMemberJoinLeave &&
        showMemberInviteBan &&
        showRoomAvatar &&
        showRoomNameTopic &&
        showRoomSecurity &&
        showCallEvents &&
        !showOtherEvents) {
      return TimelineEventPreset.minimal;
    }
    return TimelineEventPreset.custom;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimelineEventSettings &&
          runtimeType == other.runtimeType &&
          preset == other.preset &&
          showMemberAvatar == other.showMemberAvatar &&
          showMemberDisplayName == other.showMemberDisplayName &&
          showMemberJoinLeave == other.showMemberJoinLeave &&
          showMemberInviteBan == other.showMemberInviteBan &&
          showRoomAvatar == other.showRoomAvatar &&
          showRoomNameTopic == other.showRoomNameTopic &&
          showRoomSecurity == other.showRoomSecurity &&
          showCallEvents == other.showCallEvents &&
          showOtherEvents == other.showOtherEvents;

  @override
  int get hashCode =>
      preset.hashCode ^
      showMemberAvatar.hashCode ^
      showMemberDisplayName.hashCode ^
      showMemberJoinLeave.hashCode ^
      showMemberInviteBan.hashCode ^
      showRoomAvatar.hashCode ^
      showRoomNameTopic.hashCode ^
      showRoomSecurity.hashCode ^
      showCallEvents.hashCode ^
      showOtherEvents.hashCode;
}

@immutable
class TimelineEventSettingsState {
  final TimelineEventSettings global;
  final Map<String, TimelineEventSettings> roomOverrides;

  const TimelineEventSettingsState({
    this.global = const TimelineEventSettings(),
    this.roomOverrides = const {},
  });

  TimelineEventPreset get preset => global.preset;
  bool get showMemberAvatar => global.showMemberAvatar;
  bool get showMemberDisplayName => global.showMemberDisplayName;
  bool get showMemberJoinLeave => global.showMemberJoinLeave;
  bool get showMemberInviteBan => global.showMemberInviteBan;
  bool get showRoomAvatar => global.showRoomAvatar;
  bool get showRoomNameTopic => global.showRoomNameTopic;
  bool get showRoomSecurity => global.showRoomSecurity;
  bool get showCallEvents => global.showCallEvents;
  bool get showOtherEvents => global.showOtherEvents;
  bool isEventVisible(ChatMessage message) => global.isEventVisible(message);

  TimelineEventSettings effectiveForRoom(String roomId) =>
      roomOverrides[roomId] ?? global;

  bool hasRoomOverride(String roomId) => roomOverrides.containsKey(roomId);

  TimelineEventSettingsState copyWith({
    TimelineEventSettings? global,
    Map<String, TimelineEventSettings>? roomOverrides,
  }) {
    return TimelineEventSettingsState(
      global: global ?? this.global,
      roomOverrides: roomOverrides ?? this.roomOverrides,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimelineEventSettingsState &&
          runtimeType == other.runtimeType &&
          global == other.global &&
          mapEquals(roomOverrides, other.roomOverrides);

  @override
  int get hashCode => global.hashCode ^ Object.hashAll(roomOverrides.entries);
}

class TimelineEventSettingsNotifier
    extends Notifier<TimelineEventSettingsState> {
  static const _keyPreset = 'timeline_events_preset';
  static const _keyMemberAvatar = 'timeline_events_member_avatar';
  static const _keyMemberDisplayName = 'timeline_events_member_display_name';
  static const _keyMemberJoinLeave = 'timeline_events_member_join_leave';
  static const _keyMemberInviteBan = 'timeline_events_member_invite_ban';
  static const _keyRoomAvatar = 'timeline_events_room_avatar';
  static const _keyRoomNameTopic = 'timeline_events_room_name_topic';
  static const _keyRoomSecurity = 'timeline_events_room_security';
  static const _keyCallEvents = 'timeline_events_call';
  static const _keyOtherEvents = 'timeline_events_other';
  static const _keyRoomOverrides = 'timeline_events_room_overrides';

  bool _userModified = false;

  @override
  TimelineEventSettingsState build() {
    _restore();
    return const TimelineEventSettingsState();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_userModified) return;
    final presetName = prefs.getString(_keyPreset);
    final preset = switch (presetName) {
      'all' => TimelineEventPreset.all,
      'minimal' => TimelineEventPreset.minimal,
      'off' => TimelineEventPreset.off,
      'custom' => TimelineEventPreset.custom,
      'recommended' => TimelineEventPreset.recommended,
      _ => TimelineEventPreset.recommended,
    };

    final memberAvatar = prefs.getBool(_keyMemberAvatar) ?? false;
    final memberDisplayName = prefs.getBool(_keyMemberDisplayName) ?? false;
    final memberJoinLeave = prefs.getBool(_keyMemberJoinLeave) ?? true;
    final memberInviteBan = prefs.getBool(_keyMemberInviteBan) ?? true;
    final roomAvatar = prefs.getBool(_keyRoomAvatar) ?? true;
    final roomNameTopic = prefs.getBool(_keyRoomNameTopic) ?? true;
    final roomSecurity = prefs.getBool(_keyRoomSecurity) ?? true;
    final callEvents = prefs.getBool(_keyCallEvents) ?? true;
    final otherEvents = prefs.getBool(_keyOtherEvents) ?? true;

    final global = TimelineEventSettings(
      preset: preset,
      showMemberAvatar: memberAvatar,
      showMemberDisplayName: memberDisplayName,
      showMemberJoinLeave: memberJoinLeave,
      showMemberInviteBan: memberInviteBan,
      showRoomAvatar: roomAvatar,
      showRoomNameTopic: roomNameTopic,
      showRoomSecurity: roomSecurity,
      showCallEvents: callEvents,
      showOtherEvents: otherEvents,
    );

    final overridesString = prefs.getString(_keyRoomOverrides);
    Map<String, TimelineEventSettings> roomOverrides = {};
    if (overridesString != null && overridesString.isNotEmpty) {
      try {
        final decoded = jsonDecode(overridesString) as Map<String, dynamic>;
        roomOverrides = decoded.map(
          (k, v) => MapEntry(
            k,
            TimelineEventSettings.fromJson(v as Map<String, dynamic>),
          ),
        );
      } catch (_) {}
    }

    state = TimelineEventSettingsState(
      global: global,
      roomOverrides: roomOverrides,
    );
  }

  Future<void> setPreset(TimelineEventPreset preset) async {
    TimelineEventSettings nextGlobal;
    switch (preset) {
      case TimelineEventPreset.all:
        nextGlobal = const TimelineEventSettings(
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
        break;
      case TimelineEventPreset.recommended:
        nextGlobal = const TimelineEventSettings(
          preset: TimelineEventPreset.recommended,
          showMemberAvatar: false, // 过滤高噪音个人头像
          showMemberDisplayName: false, // 过滤高噪音个人昵称
          showMemberJoinLeave: true,
          showMemberInviteBan: true,
          showRoomAvatar: true,
          showRoomNameTopic: true,
          showRoomSecurity: true,
          showCallEvents: true,
          showOtherEvents: true,
        );
        break;
      case TimelineEventPreset.minimal:
        nextGlobal = const TimelineEventSettings(
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
        break;
      case TimelineEventPreset.off:
        nextGlobal = const TimelineEventSettings(
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
        break;
      case TimelineEventPreset.custom:
        nextGlobal = state.global.copyWith(preset: TimelineEventPreset.custom);
        break;
    }
    await _save(state.copyWith(global: nextGlobal));
  }

  Future<void> setShowMemberAvatar(bool value) =>
      _updateGlobal((s) => s.copyWith(showMemberAvatar: value));

  Future<void> setShowMemberDisplayName(bool value) =>
      _updateGlobal((s) => s.copyWith(showMemberDisplayName: value));

  Future<void> setShowMemberJoinLeave(bool value) =>
      _updateGlobal((s) => s.copyWith(showMemberJoinLeave: value));

  Future<void> setShowMemberInviteBan(bool value) =>
      _updateGlobal((s) => s.copyWith(showMemberInviteBan: value));

  Future<void> setShowRoomAvatar(bool value) =>
      _updateGlobal((s) => s.copyWith(showRoomAvatar: value));

  Future<void> setShowRoomNameTopic(bool value) =>
      _updateGlobal((s) => s.copyWith(showRoomNameTopic: value));

  Future<void> setShowRoomSecurity(bool value) =>
      _updateGlobal((s) => s.copyWith(showRoomSecurity: value));

  Future<void> setShowCallEvents(bool value) =>
      _updateGlobal((s) => s.copyWith(showCallEvents: value));

  Future<void> setShowOtherEvents(bool value) =>
      _updateGlobal((s) => s.copyWith(showOtherEvents: value));

  Future<void> enableRoomOverride(
    String roomId, [
    TimelineEventSettings? initial,
  ]) async {
    final nextOverrides = Map<String, TimelineEventSettings>.from(
      state.roomOverrides,
    );
    nextOverrides[roomId] = initial ?? state.global;
    await _save(state.copyWith(roomOverrides: nextOverrides));
  }

  Future<void> clearRoomOverride(String roomId) async {
    final nextOverrides = Map<String, TimelineEventSettings>.from(
      state.roomOverrides,
    );
    nextOverrides.remove(roomId);
    await _save(state.copyWith(roomOverrides: nextOverrides));
  }

  Future<void> setRoomPreset(String roomId, TimelineEventPreset preset) async {
    final current = state.effectiveForRoom(roomId);
    TimelineEventSettings next;
    switch (preset) {
      case TimelineEventPreset.all:
        next = const TimelineEventSettings(
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
        break;
      case TimelineEventPreset.recommended:
        next = const TimelineEventSettings(
          preset: TimelineEventPreset.recommended,
          showMemberAvatar: false,
          showMemberDisplayName: false,
          showMemberJoinLeave: true,
          showMemberInviteBan: true,
          showRoomAvatar: true,
          showRoomNameTopic: true,
          showRoomSecurity: true,
          showCallEvents: true,
          showOtherEvents: true,
        );
        break;
      case TimelineEventPreset.minimal:
        next = const TimelineEventSettings(
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
        break;
      case TimelineEventPreset.off:
        next = const TimelineEventSettings(
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
        break;
      case TimelineEventPreset.custom:
        next = current.copyWith(preset: TimelineEventPreset.custom);
        break;
    }
    await _updateRoom(roomId, (_) => next);
  }

  Future<void> setRoomShowMemberAvatar(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showMemberAvatar: value));

  Future<void> setRoomShowMemberDisplayName(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showMemberDisplayName: value));

  Future<void> setRoomShowMemberJoinLeave(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showMemberJoinLeave: value));

  Future<void> setRoomShowMemberInviteBan(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showMemberInviteBan: value));

  Future<void> setRoomShowRoomAvatar(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showRoomAvatar: value));

  Future<void> setRoomShowRoomNameTopic(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showRoomNameTopic: value));

  Future<void> setRoomShowRoomSecurity(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showRoomSecurity: value));

  Future<void> setRoomShowCallEvents(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showCallEvents: value));

  Future<void> setRoomShowOtherEvents(String roomId, bool value) =>
      _updateRoom(roomId, (s) => s.copyWith(showOtherEvents: value));

  Future<void> _updateGlobal(
    TimelineEventSettings Function(TimelineEventSettings) updater,
  ) async {
    final updated = updater(state.global);
    final resolvedPreset = TimelineEventSettings.resolvePreset(
      showMemberAvatar: updated.showMemberAvatar,
      showMemberDisplayName: updated.showMemberDisplayName,
      showMemberJoinLeave: updated.showMemberJoinLeave,
      showMemberInviteBan: updated.showMemberInviteBan,
      showRoomAvatar: updated.showRoomAvatar,
      showRoomNameTopic: updated.showRoomNameTopic,
      showRoomSecurity: updated.showRoomSecurity,
      showCallEvents: updated.showCallEvents,
      showOtherEvents: updated.showOtherEvents,
    );
    final nextGlobal = updated.copyWith(preset: resolvedPreset);
    await _save(state.copyWith(global: nextGlobal));
  }

  Future<void> _updateRoom(
    String roomId,
    TimelineEventSettings Function(TimelineEventSettings) updater,
  ) async {
    final current = state.effectiveForRoom(roomId);
    final updated = updater(current);
    final resolvedPreset = TimelineEventSettings.resolvePreset(
      showMemberAvatar: updated.showMemberAvatar,
      showMemberDisplayName: updated.showMemberDisplayName,
      showMemberJoinLeave: updated.showMemberJoinLeave,
      showMemberInviteBan: updated.showMemberInviteBan,
      showRoomAvatar: updated.showRoomAvatar,
      showRoomNameTopic: updated.showRoomNameTopic,
      showRoomSecurity: updated.showRoomSecurity,
      showCallEvents: updated.showCallEvents,
      showOtherEvents: updated.showOtherEvents,
    );
    final nextRoom = updated.copyWith(preset: resolvedPreset);
    final nextOverrides = Map<String, TimelineEventSettings>.from(
      state.roomOverrides,
    );
    nextOverrides[roomId] = nextRoom;
    await _save(state.copyWith(roomOverrides: nextOverrides));
  }

  Future<void> _save(TimelineEventSettingsState next) async {
    _userModified = true;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPreset, next.global.preset.name);
    await prefs.setBool(_keyMemberAvatar, next.global.showMemberAvatar);
    await prefs.setBool(
      _keyMemberDisplayName,
      next.global.showMemberDisplayName,
    );
    await prefs.setBool(_keyMemberJoinLeave, next.global.showMemberJoinLeave);
    await prefs.setBool(_keyMemberInviteBan, next.global.showMemberInviteBan);
    await prefs.setBool(_keyRoomAvatar, next.global.showRoomAvatar);
    await prefs.setBool(_keyRoomNameTopic, next.global.showRoomNameTopic);
    await prefs.setBool(_keyRoomSecurity, next.global.showRoomSecurity);
    await prefs.setBool(_keyCallEvents, next.global.showCallEvents);
    await prefs.setBool(_keyOtherEvents, next.global.showOtherEvents);

    final encodedOverrides = jsonEncode(
      next.roomOverrides.map((k, v) => MapEntry(k, v.toJson())),
    );
    await prefs.setString(_keyRoomOverrides, encodedOverrides);
  }
}

final timelineEventSettingsProvider =
    NotifierProvider<TimelineEventSettingsNotifier, TimelineEventSettingsState>(
      TimelineEventSettingsNotifier.new,
    );

final roomTimelineEventSettingsProvider =
    Provider.family<TimelineEventSettings, String>((ref, roomId) {
      final state = ref.watch(timelineEventSettingsProvider);
      return state.effectiveForRoom(roomId);
    });
