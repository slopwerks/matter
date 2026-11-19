import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/settings/settings_page.dart'
    show accountSwitchControllerProvider;
import '../../pages/chat/chat_detail_page.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../src/rust/api/matrix.dart' as matrix;
import '../../src/rust/api/matrix/desktop_notifications.dart' as rust;
import '../diagnostics/diagnostic_exporter.dart' show redactLogMessage;
import 'desktop_notification_runtime.dart';
import 'desktop_notification_settings.dart';
import 'push_settings.dart';

final desktopNotificationEventsProvider =
    StreamProvider<rust.DesktopNotification>((ref) {
      if (!desktopNotificationsSupported || !ref.watch(sessionReadyProvider)) {
        return const Stream.empty();
      }
      return rust.watchDesktopNotifications();
    });

class DesktopNotificationListener extends ConsumerStatefulWidget {
  const DesktopNotificationListener({
    super.key,
    required this.navigatorKey,
    required this.child,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  @override
  ConsumerState<DesktopNotificationListener> createState() =>
      _DesktopNotificationListenerState();
}

class _DesktopNotificationListenerState
    extends ConsumerState<DesktopNotificationListener> {
  StreamSubscription<PushTarget>? _opened;
  late DesktopNotificationRuntime _runtime;
  PushTarget? _pending;
  bool _opening = false;
  bool _failureShown = false;

  @override
  void initState() {
    super.initState();
    if (!desktopNotificationsSupported) return;
    _runtime = ref.read(desktopNotificationRuntimeProvider);
    _opened = _runtime.opened.listen((target) {
      _pending = target;
      unawaited(_openPending());
    });
  }

  bool _current(rust.DesktopNotification event) {
    if (!mounted ||
        !ref.read(sessionReadyProvider) ||
        !ref.read(isLoggedInProvider) ||
        ref.read(activeUserIdProvider) != event.userId ||
        ref
                .read(desktopNotificationsEnabledProvider(event.userId))
                .asData
                ?.value !=
            true) {
      return false;
    }
    final room = ref
        .read(allChatRoomsProvider)
        .asData
        ?.value
        .where((room) => room.id == event.roomId)
        .firstOrNull;
    if (room?.isMuted == true ||
        (room?.lastEventId == event.eventId && room?.unreadCount == 0)) {
      return false;
    }
    return !(ref.read(currentRoomIdProvider) == event.roomId &&
        ref.read(roomViewOwnerProvider(event.roomId)) == event.userId &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  }

  Future<void> _notify(rust.DesktopNotification event) async {
    try {
      if (!await ref.read(
            desktopNotificationsEnabledProvider(event.userId).future,
          ) ||
          !_current(event)) {
        return;
      }
      await _runtime.show(event, isCurrent: () => _current(event));
      _failureShown = false;
    } catch (error, stack) {
      _recordFailure(
        'show',
        error,
        stack,
        userId: event.userId,
        roomId: event.roomId,
        eventId: event.eventId,
      );
      if (mounted && !_failureShown) {
        _failureShown = true;
        _error('系统通知暂不可用：$error');
      }
    }
  }

  Future<void> _openPending() async {
    if (_opening) return;
    _opening = true;
    PushTarget? openingTarget;
    try {
      while (_pending != null && mounted) {
        final target = _pending!;
        openingTarget = target;
        _pending = null;
        if (!ref.read(sessionReadyProvider) ||
            !ref
                .read(sessionsProvider)
                .any((session) => session.userId == target.userId)) {
          continue;
        }
        if (!await ref.read(
              desktopNotificationsEnabledProvider(target.userId).future,
            ) ||
            !mounted) {
          continue;
        }
        final navigator = widget.navigatorKey.currentState;
        if (navigator == null) continue;
        navigator.popUntil((route) => route.isFirst);
        await ref.read(accountSwitchControllerProvider).switchTo(target.userId);
        if (!mounted || ref.read(activeUserIdProvider) != target.userId) {
          continue;
        }
        final rooms = await matrix.getChatRooms(authoritative: true);
        if (!mounted || ref.read(activeUserIdProvider) != target.userId) {
          continue;
        }
        final room = rooms
            .where((room) => room.id == target.roomId)
            .firstOrNull;
        if (room == null) throw StateError('房间暂不可用，请同步后再试');
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || ref.read(activeUserIdProvider) != target.userId) {
          continue;
        }
        if (ref
                .read(desktopRoomNavigationProvider)
                .open
                ?.call(room, messageId: target.eventId) ==
            true) {
          continue;
        }
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => ChatDetailPage(
                roomId: room.id,
                roomName: room.name,
                avatarUrl: room.avatarUrl,
                nameEventId: room.nameEventId,
                avatarEventId: room.avatarEventId,
                isDm: room.roomType == 'dm',
                initialMessageId: target.eventId,
              ),
            ),
          ),
        );
      }
    } catch (error, stack) {
      _recordFailure(
        'open',
        error,
        stack,
        userId: openingTarget?.userId,
        roomId: openingTarget?.roomId,
        eventId: openingTarget?.eventId,
      );
      _error('打开通知消息失败：$error');
    } finally {
      _opening = false;
      if (_pending != null && mounted) unawaited(_openPending());
    }
  }

  Future<void> _dismiss(Future<void> operation) async {
    try {
      await operation;
    } catch (error, stack) {
      _recordFailure('cleanup', error, stack);
    }
  }

  void _recordFailure(
    String operation,
    Object error,
    StackTrace stack, {
    String? userId,
    String? roomId,
    String? eventId,
  }) {
    matrix.logAppMessage(
      level: 'error',
      tag: 'desktop-notifications',
      message: redactLogMessage(
        'notification_$operation failed '
        'user_id=$userId room_id=$roomId event_id=$eventId\n$error\n$stack',
      ),
    );
  }

  void _error(String message) {
    final context = widget.navigatorKey.currentContext;
    if (mounted && context != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopNotificationsSupported) return widget.child;
    ref.listen(desktopNotificationEventsProvider, (_, next) {
      final event = next.asData?.value;
      if (event != null && !next.isLoading) unawaited(_notify(event));
    });
    ref.listen(currentRoomIdProvider, (_, room) {
      final userId = ref.read(activeUserIdProvider);
      if (room != null &&
          userId != null &&
          ref.read(roomViewOwnerProvider(room)) == userId) {
        unawaited(_dismiss(_runtime.cancelRoom(userId, room)));
      }
    });
    ref.listen(allChatRoomsProvider, (_, next) {
      final userId = ref.read(activeUserIdProvider);
      if (userId == null || next.isLoading) return;
      for (final room in next.asData?.value ?? const <matrix.ChatRoom>[]) {
        if (room.isMuted || room.unreadCount == 0) {
          unawaited(
            _dismiss(
              _runtime.cancelRoom(
                userId,
                room.id,
                eventIds: room.isMuted ? null : [room.lastEventId],
              ),
            ),
          );
        }
      }
    });
    ref.listen(sessionsProvider, (previous, next) {
      for (final session in previous ?? const <matrix.StoredSession>[]) {
        if (!next.any((item) => item.userId == session.userId)) {
          unawaited(_dismiss(_runtime.cancelAccount(session.userId)));
        }
      }
    });
    return widget.child;
  }

  @override
  void dispose() {
    unawaited(_opened?.cancel());
    super.dispose();
  }
}
