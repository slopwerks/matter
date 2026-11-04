import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../widgets/sheets.dart';
import 'action_failure_message.dart';

Future<bool> confirmMessagePinChange(
  BuildContext context, {
  required bool pinned,
}) => showNeuConfirm(
  context,
  title: pinned ? '置顶这条消息？' : '取消置顶这条消息？',
  message: pinned ? '这条消息会出现在会话的置顶栏中，所有成员都能看到。' : '这条消息将从所有成员的置顶栏中移除，原消息仍会保留。',
  confirmLabel: pinned ? '置顶' : '取消置顶',
  cancelLabel: '返回',
);

/// Inverse writes use explicit states, so retrying never toggles by accident.
/// Every action stays bound to the account that performed the original write.
void showMessagePinFeedback({
  required BuildContext context,
  required ProviderContainer container,
  required String accountUserId,
  required String roomId,
  required String eventId,
  required bool pinned,
  ValueChanged<bool>? onChanged,
  bool redo = false,
}) {
  bool isCurrent() =>
      context.mounted && container.read(activeUserIdProvider) == accountUserId;
  if (!isCurrent()) return;
  final messenger = ScaffoldMessenger.of(context);
  var inFlight = false;

  Future<void> reverse() async {
    if (!isCurrent() || inFlight) return;
    inFlight = true;
    try {
      await rust.setPinnedMessage(
        accountUserId: accountUserId,
        roomId: roomId,
        eventId: eventId,
        pinned: !pinned,
      );
      if (!context.mounted || !isCurrent()) return;
      container.invalidate(
        pinnedMessagesProvider((roomId: roomId, userId: accountUserId)),
      );
      onChanged?.call(!pinned);
      showMessagePinFeedback(
        context: context,
        container: container,
        accountUserId: accountUserId,
        roomId: roomId,
        eventId: eventId,
        pinned: !pinned,
        onChanged: onChanged,
        redo: !redo,
      );
    } catch (error) {
      if (!context.mounted || !isCurrent()) return;
      container.invalidate(
        pinnedMessagesProvider((roomId: roomId, userId: accountUserId)),
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(actionFailureMessage(error)),
            persist: false,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: '重试',
              onPressed: () => unawaited(reverse()),
            ),
          ),
        );
    } finally {
      inFlight = false;
    }
  }

  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(pinned ? '消息已置顶' : '已取消置顶'),
        persist: false,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: redo ? '重做' : '撤销',
          onPressed: () => unawaited(reverse()),
        ),
      ),
    );
}
