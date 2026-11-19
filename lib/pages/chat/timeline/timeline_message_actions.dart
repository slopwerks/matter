import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../src/rust/api/matrix.dart' hide redactMessage;
import '../../../theme/neu_colors.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../widgets/app_avatar.dart';
import '../../../widgets/glass.dart';
import '../../../widgets/sheets.dart';
import '../message_reader_page.dart';
import '../message_input.dart'
    show editingDraftProvider, editingSendInFlightProvider;
import '../message_pin_actions.dart';
import '../forward_message_sheet.dart';
import '../emoji_picker_panel.dart';
import '../action_failure_message.dart';
import 'timeline_message_menu.dart';
import 'timeline_reactions_bar.dart';

class TimelineMessageActions {
  const TimelineMessageActions({
    required this.roomId,
    required this.membersById,
    this.onReplyRequested,
    this.onMessageForwarded,
  });
  final String roomId;
  final Map<String, Contact> membersById;
  final VoidCallback? onReplyRequested;
  final ValueChanged<ChatRoom>? onMessageForwarded;
  void showMemberProfile(BuildContext context, String userId, Contact? member) {
    final memberName = member?.name.trim();
    final displayName = memberName == null || memberName.isEmpty
        ? userId
        : memberName;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        key: ValueKey('mention-profile:$userId'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassPanel(
          radius: NeuRadius.nav,
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppAvatar(
                fallback: displayName,
                size: 64,
                radius: 20,
                url: member?.avatarUrl,
              ),
              const SizedBox(height: 14),
              Text(
                displayName,
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 5),
              SelectableText(
                userId,
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the full-screen reader for a formatted message. The reader
  /// lives on the root navigator and can outlive this bubble (responsive
  /// layout switch), so mentions inside it are shown through the
  /// navigator's context instead of this bubble's.
  void openReaderFullScreen(
    BuildContext context, {
    required String html,
    required Map<String, String> mentionDisplayNames,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    openMessageReader(
      context,
      html: html,
      mentionDisplayNames: mentionDisplayNames,
      onMentionTap: (userId) {
        final navContext = navigator.context;
        if (navContext.mounted) {
          showMemberProfile(navContext, userId, membersById[userId]);
        }
      },
    );
  }

  /// Full emoji picker panel (pure-Dart, no native plugin).
  void _showEmojiPicker(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
    final colors = context.neu;
    showNeuSheet(
      context: context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
            child: Row(
              children: [
                Text('选择表情', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Icon(
                    Icons.close_rounded,
                    color: colors.textTertiary,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: EmojiPickerPanel(
              onEmojiSelected: (emoji) async {
                Navigator.of(context).pop();
                await toggleTimelineReaction(
                  context,
                  ref,
                  roomId: roomId,
                  eventId: message.id,
                  emoji: emoji,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> showContextMenu(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message, {
    VoidCallback? onReadFullScreen,
  }) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayContext = overlay.context;
    final container = ProviderScope.containerOf(context, listen: false);
    // Geometry of the long-pressed bubble, for popover positioning.
    final renderObject = context.findRenderObject();
    final Rect? bubbleRect = renderObject is RenderBox && renderObject.hasSize
        ? (renderObject.localToGlobal(Offset.zero) & renderObject.size)
        : null;
    final menuAccount = ref.read(activeUserIdProvider) ?? '';
    final canPin =
        message.msgType != MessageType.event &&
        !isLocalOutgoingMessage(message.id);
    bool? isPinned;
    var pinStateLoading = canPin;
    var menuOpen = true;

    late OverlayEntry entry;
    void close() {
      if (!menuOpen) return;
      menuOpen = false;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (_) => TimelineMessageMenu(
        message: message,
        isMe: message.isMe,
        bubbleRect: bubbleRect,
        onClose: close,
        onReadFullScreen: onReadFullScreen,
        onCopy: () async {
          await Clipboard.setData(ClipboardData(text: message.content));
          if (overlayContext.mounted) {
            neuToast(overlayContext, '已复制');
          }
        },
        onReply: () => startReply(overlayContext, ref, message),
        onForward: () async {
          final targetRoom = await showForwardMessageSheet(
            context: overlayContext,
            sourceRoomId: roomId,
            message: message,
          );
          if (targetRoom != null) {
            onMessageForwarded?.call(targetRoom);
          }
        },
        onEdit: () {
          final roomAccountKey = activeRoomAccountKey(ref, roomId);
          if (_blockEditingTransition(overlayContext, ref, roomAccountKey)) {
            return;
          }
          ref.read(replyingToProvider(roomAccountKey).notifier).value = null;
          ref.read(editingMessageProvider(roomAccountKey).notifier).value =
              message;
        },
        onRecall: () async {
          try {
            await redactMessage(ref, roomId, message.id);
          } catch (e) {
            if (overlayContext.mounted) {
              ScaffoldMessenger.of(overlayContext).showSnackBar(
                SnackBar(
                  content: Text('撤回失败: $e'),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          }
        },
        isPinned: isPinned,
        pinStateLoading: pinStateLoading,
        onPin: isPinned == null
            ? null
            : () async {
                try {
                  final target = !isPinned!;
                  final confirmed = await confirmMessagePinChange(
                    overlayContext,
                    pinned: target,
                  );
                  if (!confirmed ||
                      !overlayContext.mounted ||
                      container.read(activeUserIdProvider) != menuAccount) {
                    return;
                  }
                  final pinned = await setPinnedMessage(
                    accountUserId: menuAccount,
                    roomId: roomId,
                    eventId: message.id,
                    pinned: target,
                  );
                  if (overlayContext.mounted) {
                    showMessagePinFeedback(
                      context: overlayContext,
                      container: container,
                      accountUserId: menuAccount,
                      roomId: roomId,
                      eventId: message.id,
                      pinned: pinned,
                    );
                  }
                  if (overlayContext.mounted) {
                    container.invalidate(
                      pinnedMessagesProvider((
                        roomId: roomId,
                        userId: menuAccount,
                      )),
                    );
                  }
                } catch (error) {
                  if (!overlayContext.mounted) {
                    return;
                  }
                  final timedOut = isMutationTimeout(error);
                  if (timedOut) {
                    // A timeout may still land server-side: the queued operation
                    // keeps running in the background, and setPinnedMessage
                    // returns the request value, not the final state. Tell the
                    // user to confirm instead of claiming a failed pin.
                    ScaffoldMessenger.of(overlayContext).showSnackBar(
                      const SnackBar(
                        content: Text('置顶操作超时，状态可能已更新，请刷新确认'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                    return;
                  }
                  // Non-timeout failures go through the shared wording (Chinese,
                  // partial-success passthrough) — one source for all pages.
                  ScaffoldMessenger.of(overlayContext).showSnackBar(
                    SnackBar(
                      content: Text(actionFailureMessage(error)),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
        onReact: (emoji) => toggleTimelineReaction(
          overlayContext,
          ref,
          roomId: roomId,
          eventId: message.id,
          emoji: emoji,
        ),
        onShowFullEmojiPicker: () =>
            _showEmojiPicker(overlayContext, ref, message),
      ),
    );
    // Confirm the menu appeared with a light haptic.
    HapticFeedback.selectionClick();
    overlay.insert(entry);
    if (!canPin) return;
    try {
      final pinnedIds = await getPinnedEventIds(
        accountUserId: menuAccount,
        roomId: roomId,
      );
      if (!menuOpen || !overlayContext.mounted) return;
      isPinned = pinnedIds.contains(message.id);
      pinStateLoading = false;
      entry.markNeedsBuild();
    } catch (error) {
      if (!menuOpen || !overlayContext.mounted) return;
      pinStateLoading = false;
      entry.markNeedsBuild();
      debugPrint('Unable to load pinned state: $error');
      // Without the state read the menu cannot offer pin/unpin at all — say
      // so instead of silently dropping the entry.
      ScaffoldMessenger.of(overlayContext).showSnackBar(
        SnackBar(
          content: Text('无法获取置顶状态，请重试: ${actionFailureMessage(error)}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  bool _blockEditingTransition(
    BuildContext context,
    WidgetRef ref,
    RoomAccountKey roomAccountKey,
  ) {
    if (ref.read(editingSendInFlightProvider(roomAccountKey)) == null) {
      return false;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('编辑正在发送，请稍候'),
        duration: Duration(seconds: 1),
      ),
    );
    return true;
  }

  void startReply(BuildContext context, WidgetRef ref, ChatMessage message) {
    final roomAccountKey = activeRoomAccountKey(ref, roomId);
    if (_blockEditingTransition(context, ref, roomAccountKey)) return;
    ref.read(editingMessageProvider(roomAccountKey).notifier).value = null;
    ref.read(editingDraftProvider(roomAccountKey).notifier).value = null;
    ref.read(replyingToProvider(roomAccountKey).notifier).value = message;
    onReplyRequested?.call();
  }

  /// Menu for a failed local outgoing message: retry the send or drop the
  /// message. Failed sends are otherwise a dead end — no long-press menu,
  /// no retry, no delete — so the user can only retype the message.
  void showFailedMessageMenu(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
    final colors = context.neu;
    final roomAccountKey = activeRoomAccountKey(ref, roomId);
    final canRetry = message.msgType == MessageType.text;
    showNeuSheet<void>(
      context: context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NeuSheetItem(
            icon: Icons.refresh_rounded,
            label: '重试发送',
            color: canRetry ? null : colors.textTertiary,
            trailing: canRetry
                ? null
                : Text(
                    '仅文本消息支持重试',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
            onTap: !canRetry
                ? () {}
                : () async {
                    Navigator.of(context).pop();
                    try {
                      await retryFailedLocalMessage(
                        ref,
                        roomAccountKey,
                        message.id,
                      );
                      if (context.mounted &&
                          ref.read(activeUserIdProvider) ==
                              roomAccountKey.userId) {
                        neuToast(context, '已重新发送');
                      }
                    } catch (error) {
                      if (context.mounted &&
                          ref.read(activeUserIdProvider) ==
                              roomAccountKey.userId) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('重试失败: $error'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    }
                  },
          ),
          NeuSheetItem(
            icon: Icons.delete_outline_rounded,
            label: '删除消息',
            color: colors.error,
            onTap: () {
              Navigator.of(context).pop();
              removeLocalOutgoingMessage(ref, roomAccountKey, message.id);
            },
          ),
        ],
      ),
    );
  }
}
