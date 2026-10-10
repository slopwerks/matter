import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/chat/chat_detail_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../providers/auth_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import 'fcm_push_runtime.dart' show acceptsPushTarget;
import 'push_runtime.dart';
import 'push_providers.dart';
import 'push_settings.dart';

class PushNotificationListener extends ConsumerStatefulWidget {
  const PushNotificationListener({
    super.key,
    required this.navigatorKey,
    required this.child,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<PushNotificationListener> createState() =>
      _PushNotificationListenerState();
}

class _PushNotificationListenerState
    extends ConsumerState<PushNotificationListener>
    with WidgetsBindingObserver {
  StreamSubscription<PushTarget>? _subscription;
  PushTarget? _pending;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    if (!pushSupported) return;
    WidgetsBinding.instance.addObserver(this);
    _pending = takeInitialPushTarget();
    _subscription = openedPushes.listen((target) {
      _pending = target;
      _scheduleOpen();
    });
    _scheduleOpen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && ref.read(sessionReadyProvider)) {
      unawaited(
        ref
            .read(pushRegistrationManagerProvider)
            .refresh(
              ref
                  .read(sessionsProvider)
                  .map((session) => session.userId)
                  .toList(),
            )
            .catchError((Object error) {
              debugPrint('Push resume refresh failed: ${error.runtimeType}');
            }),
      );
    }
  }

  void _scheduleOpen() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openPending());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _openPending() async {
    if (_opening ||
        _pending == null ||
        !ref.read(sessionReadyProvider) ||
        !ref.read(isLoggedInProvider)) {
      return;
    }
    final target = _pending!;
    _pending = null;
    _opening = true;
    try {
      if (!await acceptsPushTarget(target) || !mounted) return;
      final navigator = widget.navigatorKey.currentState;
      if (navigator == null) return;
      navigator.popUntil((route) => route.isFirst);
      await ref.read(accountSwitchControllerProvider).switchTo(target.userId);
      if (!mounted || ref.read(activeUserIdProvider) != target.userId) return;
      final rooms = await rust.getChatRooms(authoritative: true);
      if (!mounted ||
          ref.read(activeUserIdProvider) != target.userId ||
          !await acceptsPushTarget(target)) {
        return;
      }
      final room = rooms.where((room) => room.id == target.roomId).firstOrNull;
      if (room == null) throw StateError('房间暂不可用，请同步后再试');
      // Wait until account state has rebuilt the home route before pushing.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || ref.read(activeUserIdProvider) != target.userId) return;
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
    } catch (error) {
      final context = widget.navigatorKey.currentContext;
      if (mounted && context != null && context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('打开推送消息失败：$error')));
      }
    } finally {
      _opening = false;
      if (_pending != null && mounted) _scheduleOpen();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(pushLifecycleProvider);
    ref.watch(pushReadStateProvider);
    ref.listen(sessionReadyProvider, (_, ready) {
      if (ready) _scheduleOpen();
    });
    ref.listen(isLoggedInProvider, (_, loggedIn) {
      if (loggedIn) _scheduleOpen();
    });
    return widget.child;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
