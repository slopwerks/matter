import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'action_failure_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/avatar.dart' show NeuBadge;
import '../../widgets/neu_action.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'chat_timestamp.dart';
import 'chat_detail_page.dart';
import 'message_input.dart';
import 'space_detail_page.dart';

String chatListPreview(ChatRoom room) {
  if (room.roomState == 'invited') {
    return '邀请你加入';
  }
  if (room.roomState == 'knocked') {
    return '等待对方批准';
  }
  final sender = room.lastMessageSender?.trim();
  if (room.roomType != 'group' ||
      sender == null ||
      sender.isEmpty ||
      room.lastMessage.isEmpty) {
    return room.lastMessage;
  }
  return '$sender：${room.lastMessage}';
}

class ChatListItem extends ConsumerWidget {
  final ChatRoom room;
  final bool dense;
  final bool showRoomTypeIcon;
  final ValueChanged<ChatRoom>? onRoomSelected;
  final bool isSelected;

  const ChatListItem({
    super.key,
    required this.room,
    this.dense = false,
    this.showRoomTypeIcon = true,
    this.onRoomSelected,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.neu;
    final room = this.room;
    final isPendingMembership =
        room.roomState == 'invited' || room.roomState == 'knocked';
    final userId =
        ref.watch(activeUserIdProvider) ??
        ref.watch(currentUserProvider.select((user) => user?.id)) ??
        'anonymous';
    final draft = ref.watch(
      messageDraftProvider((roomId: room.id, userId: userId)),
    );
    final hasDraft =
        room.roomState == 'joined' &&
        room.roomType != 'space' &&
        draft.trim().isNotEmpty;
    final preview = hasDraft
        ? draft.trim().replaceAll(RegExp(r'\s+'), ' ')
        : chatListPreview(room);
    final unreadOverride = ref.watch(roomUnreadOverrideProvider(room.id));
    final syncedHasUnread = room.unreadCount > 0 || room.isMarkedUnread;
    final overrideApplies = unreadOverride?.appliesTo(room) ?? false;
    final hasUnread = overrideApplies
        ? unreadOverride!.unread
        : syncedHasUnread;
    final unreadAccent = room.isMuted ? colors.textTertiary : colors.accent;
    // Same stale-override cleanup as the main room list: only a no-longer-
    // applicable override is dropped.
    if (unreadOverride != null && !overrideApplies) {
      clearStaleRoomUnreadOverride(ref, context, room.id, unreadOverride);
    }

    final surfaceColor = isPendingMembership
        ? colors.accentSoft.withValues(alpha: .5)
        : isSelected
        ? colors.surfaceStrong
        : colors.card;
    final borderColor = isSelected
        ? colors.accent.withValues(alpha: .8)
        : isPendingMembership
        ? colors.accent.withValues(alpha: .5)
        : null;

    return NeuAction(
      radius: NeuRadius.content,
      selected: isSelected,
      label: room.name,
      onTap: () {
        if (isPendingMembership) return;
        if (onRoomSelected case final onRoomSelected?) {
          onRoomSelected(room);
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => room.roomType == 'space'
                ? SpaceDetailPage(
                    space: Space(
                      id: room.id,
                      name: room.name,
                      avatarUrl: room.avatarUrl,
                    ),
                  )
                : ChatDetailPage(
                    roomId: room.id,
                    roomName: room.name,
                    avatarUrl: room.avatarUrl,
                    nameEventId: room.nameEventId,
                    avatarEventId: room.avatarEventId,
                    isDm: room.roomType == 'dm',
                    subtitle: hasUnread
                        ? (room.unreadCount > 0
                              ? '${room.unreadCount} 条未读消息'
                              : '已标记未读')
                        : switch (room.roomState) {
                            // "在线" is meaningless for pending rooms: the
                            // preview above already explains the state.
                            'invited' => '已邀请',
                            'knocked' => '待批准',
                            _ => '在线',
                          },
                  ),
          ),
        );
      },
      onLongPress: room.roomState == 'joined' && room.roomType != 'space'
          ? () => _showRoomListActions(context, ref, room)
          : null,
      child: NeuSurface(
        radius: NeuRadius.content,
        color: surfaceColor,
        borderColor: borderColor,
        padding: EdgeInsets.all(dense ? 8 : 12),
        child: Row(
          children: [
            AppAvatar(
              key: ValueKey('room-avatar:${room.id}:${room.avatarUrl}'),
              fallback: room.name,
              size: dense ? 44 : 46,
              url: room.avatarUrl,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (showRoomTypeIcon) ...[
                        _roomTypeIcon(context, room.roomType),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          room.name,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (room.isMuted) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.notifications_off_outlined,
                          key: ValueKey('room-muted-icon:${room.id}'),
                          size: 15,
                          color: colors.textTertiary,
                        ),
                      ],
                      const SizedBox(width: 8),
                      Text(
                        formatChatListTime(room.lastMessageTime),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: hasUnread ? unreadAccent : colors.textTertiary,
                          fontWeight: hasUnread
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: hasDraft
                            ? Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: '草稿：',
                                      style: TextStyle(
                                        color: colors.error,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    TextSpan(text: preview),
                                  ],
                                ),
                                style: Theme.of(context).textTheme.bodyMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : Text(
                                preview,
                                style: Theme.of(context).textTheme.bodyMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(width: 8),
                        if (room.unreadCount > 0)
                          NeuBadge(
                            key: ValueKey('room-unread-badge:${room.id}'),
                            count: room.unreadCount,
                            muted: room.isMuted,
                          )
                        else
                          Container(
                            key: ValueKey('room-unread-dot:${room.id}'),
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: unreadAccent,
                                width: 2.4,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                  if (isPendingMembership) ...[
                    const SizedBox(height: 10),
                    _PendingRoomActions(room: room),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roomTypeIcon(BuildContext context, String roomType) {
    final colors = context.neu;
    return switch (roomType) {
      'dm' => Icon(Icons.person_rounded, size: 14, color: colors.accent),
      'space' => Icon(
        Icons.account_tree_rounded,
        size: 14,
        color: colors.textSecondary,
      ),
      _ => Icon(Icons.group_rounded, size: 14, color: colors.textTertiary),
    };
  }

  void _showRoomListActions(
    BuildContext context,
    WidgetRef ref,
    ChatRoom room,
  ) {
    // Capture the account when the sheet OPENS: the actions must write as
    // the account the sheet was opened under (same snapshot discipline as
    // every other P0 write path), not as whatever account is active when
    // the user taps an item.
    final sheetAccountUserId = ref.read(activeUserIdProvider) ?? '';
    BuildContext? sheetContextRef;
    // 'read' | 'unread' — the row being written shows a spinner and both
    // rows stop accepting taps while it is set.
    String? savingAction;
    final sheetFuture = showNeuSheet<void>(
      context: context,
      child: StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          sheetContextRef = sheetContext;
          final colors = sheetContext.neu;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeuSheetItem(
                icon: Icons.done_all_rounded,
                label: '标记为已读',
                color: savingAction == null ? null : colors.textTertiary,
                trailing: savingAction == 'read'
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: savingAction != null
                    ? () {}
                    : () => _runRoomListAction(
                        context,
                        sheetContext,
                        ref,
                        room,
                        ({required String roomId}) => markRoomAsRead(
                          accountUserId: sheetAccountUserId,
                          roomId: roomId,
                          explicit: true,
                        ),
                        false,
                        '已标记为已读',
                        onStart: () =>
                            setSheetState(() => savingAction = 'read'),
                      ),
              ),
              const NeuSheetDivider(),
              NeuSheetItem(
                icon: Icons.mark_unread_chat_alt_rounded,
                label: '标记为未读',
                color: savingAction == null ? null : colors.textTertiary,
                trailing: savingAction == 'unread'
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: savingAction != null
                    ? () {}
                    : () => _runRoomListAction(
                        context,
                        sheetContext,
                        ref,
                        room,
                        ({required String roomId}) => markRoomUnread(
                          accountUserId: sheetAccountUserId,
                          roomId: roomId,
                        ),
                        true,
                        '已标记为未读',
                        onStart: () =>
                            setSheetState(() => savingAction = 'unread'),
                      ),
              ),
            ],
          );
        },
      ),
    );
    // An account switch dismisses the sheet (same discipline as the
    // management and space pages): its actions write under the account the
    // sheet opened with, and a switch mid-flight would leave it hovering
    // over the new account's list. The subscription lives only as long as
    // the sheet route.
    late final ProviderSubscription<String?> switchSub;
    switchSub = ref.listenManual(activeUserIdProvider, (_, next) {
      if (next == sheetAccountUserId) return;
      final sheet = sheetContextRef;
      // `isCurrent` guard: another modal (e.g. the device-verification
      // dialog) may sit above the sheet — popping then would dismiss that
      // dialog instead of the sheet.
      if (sheet != null &&
          sheet.mounted &&
          ModalRoute.of(sheet)?.isCurrent == true) {
        Navigator.of(sheet).pop();
      }
    });
    sheetFuture.whenComplete(switchSub.close);
  }

  Future<void> _runRoomListAction(
    BuildContext context,
    BuildContext sheetContext,
    WidgetRef ref,
    ChatRoom room,
    Future<void> Function({required String roomId}) action,
    bool markedUnread,
    String successMessage, {
    VoidCallback? onStart,
  }) async {
    // The write can wait behind the mutation queue for up to ~90s; the
    // sheet shows a spinner and disables both rows meanwhile (see
    // _showRoomListActions).
    onStart?.call();
    // `mounted` stays true while the sheet is in its exit animation, but
    // popping then would pop the route *below* the sheet; `isCurrent` turns
    // false as soon as the pop starts.
    bool sheetCanPop() =>
        sheetContext.mounted && ModalRoute.of(sheetContext)?.isCurrent == true;
    final suppression = roomAutoReadSuppressedProvider(room.id);
    final suppressionNotifier = ref.read(suppression.notifier);
    final previousSuppression = suppressionNotifier.value;
    // Captured up front (not via ref.read in the catch): the catch's
    // bookkeeping must survive the page being unmounted mid-request, and
    // ref.read throws on a disposed widget.
    final unreadOverrideNotifier = ref.read(
      roomUnreadOverrideProvider(room.id).notifier,
    );
    final previousUnreadOverride = unreadOverrideNotifier.value;
    final suppressionToken = setRoomAutoReadSuppressed(
      ref,
      room.id,
      suppressed: markedUnread,
    );
    // Optimistic local unread marker (same as the management page): the
    // queued write can take tens of seconds — the room must show the
    // pending state immediately, not after the server round-trip.
    if (markedUnread) {
      setRoomUnreadOverride(ref, room, unread: true);
    }
    try {
      await action(roomId: room.id);
      // The server write succeeded regardless of the token: close the
      // sheet and report it. A stale token only means a newer actor owns
      // the suppression/override bookkeeping, which must not be touched
      // (its changes converge via the sync echo) — but it must also not
      // leave the sheet stuck in its loading state. Pop first (the sheet
      // may still be up even if the list item was unmounted meanwhile).
      if (sheetContext.mounted &&
          ModalRoute.of(sheetContext)?.isCurrent == true) {
        Navigator.of(sheetContext).pop();
      }
      // The list item may have been unmounted while the request was in
      // flight (room removed from the list / page popped): skip the rest —
      // `ref` calls throw on a disposed widget, and the sync echo settles
      // the server state.
      if (!context.mounted) return;
      if (suppressionToken.isCurrent) {
        setRoomUnreadOverride(ref, room, unread: markedUnread);
        ref.invalidate(chatRoomsProvider);
        ref.invalidate(ungroupedRoomsProvider);
        ref.invalidate(spaceChildrenProvider);
        ref.invalidate(searchRoomsProvider);
      }
      // The account may have switched while the request was in flight (the
      // write itself was guarded server-side under the account the sheet
      // opened with): skip ALL feedback — a success snackbar about the
      // previous account's action would mislead under the new account
      // (same discipline as the management page).
      if (ref.read(activeUserIdProvider) != suppressionToken.accountId) {
        return;
      }
      neuToast(context, successMessage);
    } catch (error) {
      // Restore the suppression (and the optimistic marker) only while this
      // action still owns them.
      if (suppressionToken.isCurrent) {
        if (markedUnread) {
          // A timeout is not a failure: the queued write's tail may still
          // land (same discipline as the mute timeout marker). Keep the
          // suppression armed so a later auto-read cannot revoke a marker
          // that did land; drop only the optimistic marker (its TTL covers
          // a real failure). A confirmed failure restores everything.
          unreadOverrideNotifier.value = previousUnreadOverride;
          if (!isMutationTimeout(error)) {
            suppressionNotifier.value = previousSuppression;
            // Restoring a STALE-armed suppression (a previous write's
            // timeout left it true) must still be converged: the old entry
            // may already be gone (its revision no longer matches after
            // this write bumped it) — register afresh so the sync flow can
            // still lift the suppression once this write definitively
            // failed.
            if (previousSuppression) {
              noteTimedOutUnreadSuppression(
                room.id,
                revision: suppressionToken.value,
              );
            }
          } else {
            // The suppression stays armed: register the room so the sync
            // flow converges it if the write ultimately failed (same
            // discipline as the mute 250s convergence read). The token's
            // revision is captured when the write armed the suppression —
            // read before the await, so this works even if the page was
            // disposed.
            noteTimedOutUnreadSuppression(
              room.id,
              revision: suppressionToken.value,
            );
          }
        } else {
          // Un-marking restores the previous suppression freely: nothing
          // can be revoked by a timed-out read here. A STALE-armed
          // restoration (a previous mark-unread timeout left it true) must
          // still be converged: the old entry's revision no longer matches
          // after this write bumped it, so register afresh (same
          // discipline as the mark-unread branch).
          suppressionNotifier.value = previousSuppression;
          if (previousSuppression) {
            noteTimedOutUnreadSuppression(
              room.id,
              revision: suppressionToken.value,
            );
          }
        }
      }
      // Close the sheet first (same order as the success path): the sheet
      // is an independent route and may still be up even when the list
      // item was unmounted (room removed from the list) — leaving it would
      // strand its spinner with no feedback at all.
      if (sheetCanPop()) Navigator.of(sheetContext).pop();
      if (!context.mounted) return;
      // The account may have switched while the request was in flight (the
      // write was then rejected deterministically server-side): skip the
      // failure snackbar — it would describe the previous account's action
      // under the new account (same discipline as the success path and the
      // management page).
      if (ref.read(activeUserIdProvider) != suppressionToken.accountId) {
        return;
      }
      // Shared wording: timeout mapping and partial-success passthrough
      // come from the single `actionFailureMessage` source.
      neuToast(context, actionFailureMessage(error));
    }
  }
}

class _PendingRoomActions extends ConsumerStatefulWidget {
  final ChatRoom room;

  const _PendingRoomActions({required this.room});

  @override
  ConsumerState<_PendingRoomActions> createState() =>
      _PendingRoomActionsState();
}

class _PendingRoomActionsState extends ConsumerState<_PendingRoomActions> {
  /// In-flight guard for the accept/reject/withdraw buttons: a second tap
  /// before the first request resolves would double-fire the invite
  /// mutation (the second is then rejected server-side, misreporting a
  /// successful action as a failure).
  bool _pendingAction = false;

  ChatRoom get room => widget.room;

  @override
  Widget build(BuildContext context) {
    if (room.roomState == 'invited') {
      return Row(
        children: [
          Expanded(
            child: _ActionButton(
              icon: Icons.check_rounded,
              label: '接受',
              accent: true,
              onPressed: _pendingAction
                  ? null
                  : () => _runAction(
                      context,
                      ref,
                      () => acceptRoomInvite(
                        accountUserId: ref.read(activeUserIdProvider) ?? '',
                        roomId: room.id,
                      ),
                      successMessage: '已接受邀请',
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _ActionButton(
              icon: Icons.close_rounded,
              label: '拒绝',
              destructive: true,
              onPressed: _pendingAction
                  ? null
                  : () => _runAction(
                      context,
                      ref,
                      () => rejectRoomInvite(
                        accountUserId: ref.read(activeUserIdProvider) ?? '',
                        roomId: room.id,
                      ),
                      successMessage: '已拒绝邀请',
                    ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            icon: Icons.undo_rounded,
            label: '撤回',
            destructive: true,
            onPressed: _pendingAction
                ? null
                : () => _runAction(
                    context,
                    ref,
                    () => withdrawRoomKnock(
                      accountUserId: ref.read(activeUserIdProvider) ?? '',
                      roomId: room.id,
                    ),
                    successMessage: '已撤回请求',
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action, {
    required String successMessage,
  }) async {
    // Entry guard (not only the disabled button): the rebuild lags a frame.
    if (_pendingAction) return;
    setState(() => _pendingAction = true);
    // 账号快照：请求期间切换账号时，下面的刷新与反馈全部跳过。
    final accountUserId = ref.read(activeUserIdProvider) ?? '';
    try {
      await action();
      // 账号可能在请求期间切换：跳过刷新与成功反馈（与失败路径一致）。
      // `mounted` first: `ref.read` throws after unmount.
      if (!context.mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      neuToast(context, successMessage);
    } catch (error) {
      if (!context.mounted) return;
      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      // Shared wording: timeout mapping and partial-success passthrough
      // come from the single `actionFailureMessage` source.
      neuToast(context, actionFailureMessage(error));
    } finally {
      if (mounted) setState(() => _pendingAction = false);
    }
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;
  final bool accent;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final color = destructive
        ? colors.error
        : accent
        ? colors.onAccent
        : colors.text;
    return NeuButton(
      onPressed: onPressed,
      accent: accent,
      radius: NeuRadius.button,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      intensity: .7,
      icon: Icon(icon, size: 16, color: color),
      child: Text(label, style: TextStyle(color: color)),
    );
  }
}
