import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_client_config.dart';
import 'push_avatar.dart';
import 'push_conversation.dart';
import 'push_notification_actions.dart';
import 'push_payload.dart';
import 'push_read_state.dart';
import 'push_reply.dart';
import 'push_room_directory.dart';
import 'push_settings.dart';
import 'push_shortcut.dart';

/// Per-account room metadata snapshot, shared with the notification path.
final _roomDirectory = PushRoomDirectory();

/// Accumulated per-room conversations, rebuilt on every background message.
final _conversations = PushConversationStore();

/// Action id for the inline reply box on an Android notification.
const replyActionId = 'matter.reply';
const markReadActionId = 'matter.mark_read';
const muteActionId = 'matter.mute';

/// Whether the event can be answered from the notification.
///
/// Replying to an encrypted room needs the SDK's Olm session and key store,
/// which the notification path deliberately does not start, so the reply
/// action is offered only for rooms whose message is sent as plaintext.
bool supportsInlineReply(Map<String, dynamic> data, {PushRoomInfo? room}) =>
    isMessageEvent(data) && !(room?.isEncrypted ?? false);

// Preserve the callback name saved by notifications from earlier versions.
@pragma('vm:entry-point')
Future<void> handleNotificationReply(NotificationResponse response) =>
    handleNotificationAction(response);

/// Handle notification actions on the owning account's background isolate.
@pragma('vm:entry-point')
Future<void> handleNotificationAction(NotificationResponse response) async {
  final target = parsePushTargetPayload(response.payload);
  if (target == null || !await acceptsPushTarget(target)) return;
  if (response.actionId == markReadActionId ||
      response.actionId == muteActionId) {
    final conversation = await _conversations.load(
      target.userId,
      target.roomId,
    );
    final entries = conversation?.entries ?? <PushConversationEntry>[];
    final boundary = entries.indexWhere(
      (entry) => entry.eventId == target.eventId,
    );
    final covered = boundary < 0
        ? [target.eventId]
        : entries.take(boundary + 1).map((entry) => entry.eventId).toList();
    final mute = response.actionId == muteActionId;
    if (!await performNotificationRoomAction(target: target, mute: mute)) {
      return;
    }
    final notifications = FlutterLocalNotificationsPlugin();
    if (mute) {
      await _dismissMutedPushRoom(notifications, target.userId, target.roomId);
    } else {
      await _cancelPushRoom(
        notifications,
        target.userId,
        target.roomId,
        covered,
      );
    }
    return;
  }
  if (response.actionId != replyActionId) return;
  final input = response.input?.trim() ?? '';
  if (input.isEmpty) return;
  final room = await _roomDirectory.lookup(target.userId, target.roomId);
  // Re-check rather than trusting an old notification's action.
  if (room?.isEncrypted ?? false) {
    debugPrint('Refusing inline reply to an encrypted room');
    return;
  }
  final sent = await sendNotificationReply(
    userId: target.userId,
    roomId: target.roomId,
    body: input,
  );
  if (sent) await _conversations.clearRoom(target.userId, target.roomId);
}

/// Decode a notification payload into a target.
///
/// Shared by the background reply handler and the runtime's own handlers.
PushTarget? parsePushTargetPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final data = jsonDecode(payload);
    return data is Map<String, dynamic> ? PushTarget.fromData(data) : null;
  } on FormatException {
    return null;
  }
}

/// Cached avatar file for a room, or null when none is known.
///
/// Only a path is read here: the foreground already downloaded the avatar, so
/// the background isolate needs neither `path_provider` nor a network call.
Future<String?> _roomAvatarPath(PushTarget target, PushRoomInfo? room) async {
  final mxc = room?.avatarMxc ?? '';
  return mxc.isEmpty ? null : pushAvatarPath(target.userId, mxc);
}

/// Avatar file for the message author, or null when unavailable.
///
/// Returned null for an encrypted room: those authors are not resolved for
/// the notification path, matching how other clients render a locked room.
Future<String?> _senderAvatarPath(
  PushTarget target,
  String sender,
  PushRoomInfo? room,
) async {
  if ((room?.isEncrypted ?? false) || sender.isEmpty) return null;
  final mxc = await loadPushSenderAvatar(target.userId, sender);
  return mxc == null ? null : pushAvatarPath(target.userId, mxc);
}

const _channelId = 'matrix_messages';
const _initializationSettings = InitializationSettings(
  android: AndroidInitializationSettings('ic_notification'),
);

bool get fcmPushSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

@pragma('vm:entry-point')
void matterFcmBackgroundDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.aks.matter/fcm_background');
  channel.setMethodCallHandler((call) async {
    if (call.method != 'message') throw MissingPluginException();
    await handleFcmBackgroundMessage(
      RemoteMessage(data: Map<String, dynamic>.from(call.arguments as Map)),
    );
  });
  unawaited(channel.invokeMethod<void>('ready'));
}

@pragma('vm:entry-point')
Future<void> handleFcmBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
  final notifications = FlutterLocalNotificationsPlugin();
  // The reply handler must be registered on the isolate that owns the
  // notification, so the typed text is delivered to the background isolate
  // that the notification was posted from.
  await notifications.initialize(
    settings: _initializationSettings,
    onDidReceiveBackgroundNotificationResponse: handleNotificationAction,
  );
  await showMatrixPush(notifications, message.data);
}

Future<bool> acceptsPushTarget(PushTarget target) =>
    _acceptsPushAccount(target.userId, target.registrationId);

Future<bool> _acceptsPushAccount(String userId, String registrationId) async {
  final settings = await PushSettingsStore().load(userId);
  if (!settings.enabled || settings.registrationId != registrationId) {
    return false;
  }
  final prefs = await SharedPreferences.getInstance();
  final removedKey =
      'matrix_session_removed_${base64Url.encode(utf8.encode(userId))}';
  if (prefs.containsKey(removedKey)) return false;
  final sessions =
      jsonDecode(prefs.getString('multi_sessions') ?? '[]') as List;
  return sessions.any((session) => session['user_id'] == userId);
}

Future<void> showMatrixPush(
  FlutterLocalNotificationsPlugin notifications,
  Map<String, dynamic> data, {
  bool Function()? isFocused,
  Future<String?> Function(String id, String title, String? avatarPath)?
  publishShortcut,
  Future<Set<String>> Function(String userId, Set<String> eventIds)?
  fetchReadEvents,
}) async {
  final target = PushTarget.fromData(data);
  final userId = data['user_id'];
  final registrationId = data['registration_id'];
  if (userId is! String ||
      !userId.startsWith('@') ||
      registrationId is! String ||
      registrationId.isEmpty ||
      !await _acceptsPushAccount(userId, registrationId)) {
    return;
  }
  // Counts-only pushes wake the background engine after a read on another
  // device. They must reconcile existing conversations, not be discarded.
  if (target == null &&
      !data.containsKey('unread') &&
      !data.containsKey('counts') &&
      !data.containsKey('counts_unread')) {
    return;
  }
  // Record arrival before the network check so a receipt written while it is
  // pending can include this event in its notification snapshot.
  if (target != null && !(isFocused?.call() ?? false)) {
    await _conversations.append(
      target.userId,
      target.roomId,
      PushConversationEntry(
        senderId: pushSenderId(data) ?? '',
        senderName: pushSenderName(data) ?? '',
        // The messaging style renders the author through its Person entry.
        body: pushMessageText(data),
        eventId: target.eventId,
        receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
        eventType: data['type'] as String? ?? '',
        roomName: data['room_name'] as String? ?? '',
      ),
    );
  }
  final tracked = await _conversations.all(userId);
  // Android can retain a notification after its bounded history was evicted.
  // Include native tags so counts-only cleanup reaches those rooms too.
  final active = [
    for (final notification in await notifications.getActiveNotifications())
      if (_notificationData(notification) case final data?)
        if (data['user_id'] == userId && data['room_id'] is String) data,
  ];
  final roomByEvent = {
    for (final room in tracked.entries)
      for (final entry in room.value.entries) entry.eventId: room.key,
    for (final data in active)
      if (data['event_id'] case final String eventId)
        eventId: data['room_id'] as String,
    if (target != null) target.eventId: target.roomId,
  };
  final roomIds = {
    ...tracked.keys,
    for (final data in active) data['room_id'] as String,
    if (target != null) target.roomId,
  };
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final muteVersions = {
    for (final roomId in roomIds)
      roomId: prefs.getInt(pushRoomMuteKey(userId, roomId)),
  };
  final unreadCounts = <String, int>{};
  final serverMutes = <String, bool>{};
  final readRooms = <String>{};
  final read = fetchReadEvents != null
      ? await fetchReadEvents(userId, roomByEvent.keys.toSet())
      : await fetchReadPushEvents(
          userId,
          roomByEvent.keys.toSet(),
          roomByEvent: roomByEvent,
          roomIds: roomIds,
          onReadRoom: readRooms.add,
          onRoomUnreadCount: (roomId, count) => unreadCounts[roomId] = count,
          onRoomMuted: (roomId, muted) => serverMutes[roomId] = muted,
        );
  if (!await _acceptsPushAccount(userId, registrationId)) return;
  await prefs.reload();
  for (final entry in serverMutes.entries) {
    final key = pushRoomMuteKey(userId, entry.key);
    // A mute acknowledged while this query was pending wins over its old data.
    if (prefs.getInt(key) != muteVersions[entry.key]) continue;
    if (entry.value) {
      await prefs.setInt(
        key,
        muteVersions[entry.key] ?? DateTime.now().microsecondsSinceEpoch,
      );
    } else {
      await prefs.remove(key);
    }
  }
  final mutedRooms = {
    for (final roomId in roomIds)
      if (prefs.containsKey(pushRoomMuteKey(userId, roomId))) roomId,
  };
  for (final roomId in roomIds) {
    if (mutedRooms.contains(roomId)) {
      await _dismissMutedPushRoom(notifications, userId, roomId);
      continue;
    }
    final covered = [
      for (final entry in roomByEvent.entries)
        if (entry.value == roomId &&
            (read.contains(entry.key) || readRooms.contains(roomId)))
          entry.key,
    ];
    if (covered.isNotEmpty || readRooms.contains(roomId)) {
      await _cancelPushRoom(
        notifications,
        userId,
        roomId,
        covered,
        unreadCount: unreadCounts[roomId],
      );
    } else if (target?.roomId != roomId &&
        unreadCounts.containsKey(roomId) &&
        active.any((data) => data['room_id'] == roomId)) {
      final remaining = await _conversations.load(userId, roomId);
      if (remaining != null) {
        await _showPushConversation(
          notifications,
          PushTarget(
            userId: userId,
            roomId: roomId,
            eventId: remaining.latestEventId,
            registrationId: registrationId,
          ),
          onlyAlertOnce: true,
          unreadCount: unreadCounts[roomId],
          isFocused: isFocused,
        );
      }
    }
  }
  if (target == null || mutedRooms.contains(target.roomId)) return;
  if (await _conversations.wasRead(userId, target.eventId) ||
      (isFocused?.call() ?? false)) {
    return;
  }
  await _showPushConversation(
    notifications,
    target,
    publishShortcut: publishShortcut,
    isFocused: isFocused,
    unreadCount: unreadCounts[target.roomId],
  );
}

Future<void> _showPushConversation(
  FlutterLocalNotificationsPlugin notifications,
  PushTarget target, {
  bool onlyAlertOnce = false,
  int? unreadCount,
  bool Function()? isFocused,
  Future<String?> Function(String id, String title, String? avatarPath)?
  publishShortcut,
}) async {
  final conversation = await _conversations.load(target.userId, target.roomId);
  if (conversation == null || conversation.latestEventId != target.eventId) {
    return;
  }
  final latest = conversation.entries.last;
  final data = <String, dynamic>{
    ...target.toData(),
    'sender': latest.senderId,
    'sender_display_name': latest.senderName,
    'type': latest.eventType,
    'room_name': latest.roomName,
    'content_body': latest.body,
  };
  final room = await _roomDirectory.lookup(target.userId, target.roomId);
  final preview = buildPushPreview(data, room: room);
  final isDirect = room?.isDirect ?? false;
  // Avatar paths are read from cache written by the foreground: no session,
  // no download and no `path_provider` are needed on this isolate.
  final roomAvatar = await _roomAvatarPath(target, room);
  final senderAvatars = <String, String?>{};
  for (final sender
      in conversation.entries.map((entry) => entry.senderId).toSet()) {
    senderAvatars[sender] = await _senderAvatarPath(target, sender, room);
  }
  final senderAvatar = senderAvatars[pushSenderId(data)];
  final conversationAvatar = isDirect ? senderAvatar ?? roomAvatar : roomAvatar;
  final shortcutId = await (publishShortcut ?? publishPushShortcut)(
    'matrix:${target.userId}:${target.roomId}',
    preview.title,
    conversationAvatar,
  );
  final replyable = supportsInlineReply(data, room: room);
  // A read can complete while avatars or the shortcut are being resolved.
  // Reload before posting so it cannot resurrect a cancelled conversation.
  final current = await _conversations.load(target.userId, target.roomId);
  if (current == null ||
      current.latestEventId != target.eventId ||
      await _pushRoomMuted(target.userId, target.roomId) ||
      (isFocused?.call() ?? false)) {
    return;
  }
  await notifications.show(
    // Identity is stable per room: Android keys a notification by (tag, id),
    // so an event-specific tag would post a new notification per message
    // instead of updating the conversation in place.
    id: pushRoomNotificationId(target.userId, target.roomId),
    title: preview.title,
    body: preview.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        '聊天消息',
        channelDescription: 'Matrix 聊天消息推送',
        importance: Importance.high,
        priority: Priority.high,
        onlyAlertOnce: onlyAlertOnce,
        number: unreadCount,
        subText: unreadCount == null ? null : '$unreadCount 条未读消息',
        visibility: NotificationVisibility.private,
        // Group by room, not by account: Android collapses a conversation's
        // notifications together, which is what a chat notification should do.
        groupKey: 'matrix:${target.userId}:${target.roomId}',
        // The large icon identifies the room at a glance. A direct chat shows
        // the author instead, which is the more useful identity there.
        largeIcon: _bitmap(conversationAvatar),
        // A large icon alone does not identify an Android conversation. The
        // shortcut supplies the room avatar to the system's conversation UI.
        shortcutId: shortcutId,
        category: AndroidNotificationCategory.message,
        styleInformation: _conversationStyle(
          preview: preview,
          conversation: current,
          isDirect: isDirect,
          senderAvatars: senderAvatars,
        ),
        actions: [
          if (replyable)
            AndroidNotificationAction(
              replyActionId,
              '回复',
              showsUserInterface: false,
              semanticAction: SemanticAction.reply,
              inputs: const [AndroidNotificationActionInput()],
            ),
          const AndroidNotificationAction(
            markReadActionId,
            '标记已读',
            cancelNotification: false,
            semanticAction: SemanticAction.markAsRead,
          ),
          const AndroidNotificationAction(
            muteActionId,
            '静音',
            cancelNotification: false,
            semanticAction: SemanticAction.mute,
          ),
        ],
        // Android's active-notification query exposes tags, not payloads.
        // A stable tag plus a stable id keeps one notification per room; the
        // latest event id travels in the payload, which Android ignores for
        // identity.
        tag: pushRoomTag(
          userId: target.userId,
          roomId: target.roomId,
          registrationId: target.registrationId,
        ),
      ),
    ),
    payload: jsonEncode(target.toData()),
  );
}

/// Wrap an avatar file path as a notification large icon.
///
/// Android decodes the file natively, so no bytes cross the platform channel
/// and the background isolate never needs to download or hold an avatar.
FilePathAndroidBitmap? _bitmap(String? path) =>
    path == null ? null : FilePathAndroidBitmap(path);

/// Wrap an avatar file path as a `Person` icon.
///
/// `Person.icon` takes an `AndroidIcon` rather than an `AndroidBitmap`, so the
/// two helpers are not interchangeable. Every message carries a complete
/// Person: Android can display separate groups when an author speaks again.
BitmapFilePathAndroidIcon? _icon(String? path) =>
    path == null ? null : BitmapFilePathAndroidIcon(path);

/// Render accumulated messages as an Android conversation.
///
/// The author is carried by each entry's [Person], which is why the stored
/// bodies omit the `Sender：` prefix shown in the collapsed form.
MessagingStyleInformation _conversationStyle({
  required PushPreview preview,
  required PushConversation conversation,
  required bool isDirect,
  required Map<String, String?> senderAvatars,
}) {
  return MessagingStyleInformation(
    // Only used to label the user's own messages, which a push never contains;
    // the account display name is not in the payload, so fall back to a label.
    const Person(name: '我'),
    // A direct chat has no conversation title: Android then shows the sender
    // name alone, matching how the collapsed notification reads.
    conversationTitle: isDirect ? null : preview.groupTitle,
    groupConversation: !isDirect,
    messages: [
      for (final entry in conversation.entries)
        Message(
          entry.body,
          DateTime.fromMillisecondsSinceEpoch(entry.receivedAtMillis),
          Person(
            name: entry.senderName.isEmpty ? null : entry.senderName,
            key: entry.senderId.isEmpty ? null : entry.senderId,
            icon: _icon(senderAvatars[entry.senderId]),
          ),
        ),
    ],
  );
}

Map<String, dynamic>? _notificationData(ActiveNotification notification) {
  final raw = notification.payload ?? notification.tag;
  if (raw == null) return null;
  try {
    final data = jsonDecode(raw);
    return data is Map<String, dynamic> ? data : null;
  } on FormatException {
    return null;
  }
}

Future<void> _cancelPushRoom(
  FlutterLocalNotificationsPlugin notifications,
  String userId,
  String roomId,
  List<String> eventIds, {
  int? unreadCount,
}) async {
  final read = eventIds.toSet();
  // History is read state too, even after swiping the system notification away.
  await _conversations.markRead(userId, roomId, read);
  for (final notification in await notifications.getActiveNotifications()) {
    final data = _notificationData(notification);
    if (data?['user_id'] != userId || data?['room_id'] != roomId) continue;
    final legacyEvent = data?['event_id'];
    if (legacyEvent is String && !read.contains(legacyEvent)) continue;
    final remaining = await _conversations.load(userId, roomId);
    if (legacyEvent is String || remaining == null) {
      if (notification.id != null) {
        await notifications.cancel(id: notification.id!, tag: notification.tag);
      }
    } else {
      // One stable notification can contain read history and newer unread
      // messages. Rebuild it quietly with just the unread entries.
      final registrationId = data?['registration_id'];
      if (registrationId is! String || registrationId.isEmpty) continue;
      await _showPushConversation(
        notifications,
        PushTarget(
          userId: userId,
          roomId: roomId,
          eventId: remaining.latestEventId,
          registrationId: registrationId,
        ),
        onlyAlertOnce: true,
        unreadCount: unreadCount,
      );
    }
  }
}

Future<bool> _pushRoomMuted(String userId, String roomId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs.containsKey(pushRoomMuteKey(userId, roomId));
}

Future<void> _dismissMutedPushRoom(
  FlutterLocalNotificationsPlugin notifications,
  String userId,
  String roomId,
) async {
  // Muting is not reading: discard history without recording read receipts.
  await _conversations.clearRoom(userId, roomId);
  for (final notification in await notifications.getActiveNotifications()) {
    final data = _notificationData(notification);
    if (data?['user_id'] == userId &&
        data?['room_id'] == roomId &&
        notification.id != null) {
      await notifications.cancel(id: notification.id!, tag: notification.tag);
    }
  }
}

class FcmPushRuntime {
  final notifications = FlutterLocalNotificationsPlugin();
  final _opened = StreamController<PushTarget>.broadcast();
  Stream<PushTarget> get opened => _opened.stream;
  PushTarget? initialTarget;
  String? initializationError;
  FirebaseClientConfig? configuration;
  bool configurationChanged = false;
  bool get isConfigured => configuration != null && !configurationChanged;
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!fcmPushSupported) return;
    try {
      configuration = await FirebaseClientConfigStore().load();
      if (configuration == null) return;
      await Firebase.initializeApp(options: configuration!.options);
      await notifications.initialize(
        settings: _initializationSettings,
        onDidReceiveNotificationResponse: (response) {
          if (response.actionId?.isNotEmpty ?? false) {
            unawaited(handleNotificationAction(response));
          } else {
            _openPayload(response.payload);
          }
        },
        onDidReceiveBackgroundNotificationResponse: handleNotificationAction,
      );
      final launch = await notifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        initialTarget = parsePushTargetPayload(
          launch?.notificationResponse?.payload,
        );
      }
      FirebaseMessaging.onMessage.listen((message) {
        unawaited(
          showMatrixPush(
            notifications,
            message.data,
            isFocused: () =>
                WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed,
          ).catchError((Object error) {
            debugPrint(
              'Failed to display Matrix notification: ${error.runtimeType}',
            );
          }),
        );
      });
      // Also handle a gateway supplying an FCM notification payload.
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final target = PushTarget.fromData(message.data);
        if (target != null) _opened.add(target);
      });
      final initialMessage = await FirebaseMessaging.instance
          .getInitialMessage();
      initialTarget ??= initialMessage == null
          ? null
          : PushTarget.fromData(initialMessage.data);
    } catch (error) {
      initializationError = 'FCM 初始化失败，请检查导入的 Firebase 配置和 Google Play 服务';
      debugPrint('FCM initialization failed: ${error.runtimeType}');
    }
  }

  void _openPayload(String? payload) {
    final target = parsePushTargetPayload(payload);
    if (target != null) _opened.add(target);
  }

  Future<List<String>> roomNotificationEvents(
    String userId,
    String roomId,
  ) async {
    final conversation = await _conversations.load(userId, roomId);
    final events = {
      if (conversation != null)
        for (final entry in conversation.entries) entry.eventId,
    };
    for (final notification in await notifications.getActiveNotifications()) {
      final data = _notificationData(notification);
      final eventId = data?['event_id'];
      if (data?['user_id'] == userId &&
          data?['room_id'] == roomId &&
          eventId is String) {
        events.add(eventId);
      }
    }
    return events.toList();
  }

  Future<void> cancelRoomNotifications(
    String userId,
    String roomId,
    List<String> eventIds,
  ) => _cancelPushRoom(notifications, userId, roomId, eventIds);

  Future<void> retireToken() async {
    if (configuration != null && initializationError == null) {
      // Matrix push gateways still address FCM tokens, not Installation IDs.
      // ignore: deprecated_member_use
      await FirebaseMessaging.instance.deleteToken();
    }
  }

  void _checkConfiguration() {
    if (configurationChanged) {
      throw StateError('Firebase 配置已更换，请在系统设置中强行停止 Matter 后重新打开');
    }
    if (configuration == null) {
      throw StateError('请先导入 Android google-services.json');
    }
  }

  Future<void> requestPermission() async {
    await initialize();
    _checkConfiguration();
    if (initializationError != null) throw StateError(initializationError!);
    final permission = await FirebaseMessaging.instance.requestPermission();
    if (permission.authorizationStatus != AuthorizationStatus.authorized) {
      throw StateError('通知权限未授予，请在系统设置中允许 Matter 通知');
    }
  }

  Future<String> getToken() async {
    await initialize();
    _checkConfiguration();
    if (initializationError != null) throw StateError(initializationError!);
    final permission = await FirebaseMessaging.instance
        .getNotificationSettings();
    if (permission.authorizationStatus != AuthorizationStatus.authorized) {
      throw StateError('通知权限未授予，请在系统设置中允许 Matter 通知');
    }
    // register()/onRegistered return an FID, which Matrix push gateways cannot use.
    // ignore: deprecated_member_use
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      throw StateError('无法获取 FCM 令牌，请检查 Google Play 服务和网络');
    }
    return token;
  }
}

final fcmPushRuntime = FcmPushRuntime();
