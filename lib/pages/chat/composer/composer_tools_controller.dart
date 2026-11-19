import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../providers/composer_attachment_provider.dart';
import '../../../theme/material_theme.dart';
import '../../../theme/neu_colors.dart';
import '../../settings/composer_keyboard_settings_page.dart';
import '../attachment_picker.dart';
import '../latest_message_control.dart';
import '../markdown_composer_page.dart';
import 'composer_draft_controller.dart';
import 'composer_send.dart';
import 'composer_typing_controller.dart';

/// Owns auxiliary routes opened by the inline composer. Captured notifiers
/// and root navigator callbacks remain valid after the opening input disposes.
class ComposerToolsController {
  ComposerToolsController({
    required this.ref,
    required this.draftKey,
    required this.context,
    required this.isMounted,
    required this.textController,
    required this.totalMembers,
    required this.inlineImages,
    required this.isDesktop,
    required this.keyboardMouse,
    required this.sourceLoading,
    required this.hidePanel,
    required this.showKeyboard,
    required this.onChanged,
    required this.onTyping,
    required this.sendText,
    required this.resolveSendPresentation,
    required this.onMessageQueued,
    required this.onMessageSent,
  });

  final WidgetRef ref;
  final RoomAccountKey draftKey;
  final BuildContext Function() context;
  final bool Function() isMounted;
  final TextEditingController textController;
  final int Function() totalMembers;
  final bool Function() inlineImages;
  final bool Function() isDesktop;
  final bool Function() keyboardMouse;
  final bool Function() sourceLoading;
  final VoidCallback hidePanel;
  final VoidCallback showKeyboard;
  final VoidCallback onChanged;
  final ValueChanged<bool> onTyping;
  final Future<bool> Function(
    String text, {
    void Function(Object)? onDetachedError,
  })
  sendText;
  final MessageSendPresentation Function() resolveSendPresentation;
  final void Function(String, MessageSendPresentation) onMessageQueued;
  final void Function(MessageSendPresentation, bool) onMessageSent;

  bool attachmentsOpen = false;
  bool composerOpen = false;
  bool _pickingImages = false;

  Future<void> previewExternalFiles(List<XFile> files) async {
    if (attachmentsOpen || files.isEmpty || !isMounted()) return;
    if ((ref.read(activeUserIdProvider) ?? '') != draftKey.userId ||
        draftKey.userId.isEmpty) {
      return;
    }
    if (inlineImages() &&
        files.every(
          (file) =>
              classifyAttachmentMime(
                resolveAttachmentMime(file.name, file.mimeType),
              ) ==
              AttachmentMediaKind.image,
        )) {
      final pending = ref.read(composerAttachmentDraftProvider(draftKey));
      if (pending.isSending) return;
      final released = pending.stage(files);
      showKeyboard();
      await released;
      return;
    }
    final hostContext = context();
    final container = ProviderScope.containerOf(hostContext, listen: false);
    final navigator = Navigator.of(hostContext, rootNavigator: true);
    final roomId = draftKey.roomId;
    hidePanel();
    attachmentsOpen = true;
    onChanged();
    try {
      await showDialog<void>(
        context: hostContext,
        barrierDismissible: false,
        builder: (dialogContext) => Dialog(
          shape: hostContext.isMaterial ? null : composerControlShape,
          clipBehavior: Clip.antiAlias,
          child: ScaffoldMessenger(
            child: SizedBox(
              width: 720,
              height: MediaQuery.sizeOf(dialogContext).height * .8,
              child: AttachmentPicker(
                initialFiles: files,
                roomId: roomId,
                accountUserId: draftKey.userId,
                height: 400,
                maxHeight: 400,
                totalMembers: totalMembers(),
                onRefresh: (_) => refreshMessagesContainer(container, roomId),
                resolveSendPresentation: resolveSendPresentation,
                onMessageQueued: onMessageQueued,
                onMessageSent: onMessageSent,
                onHeightChanged: (_) {},
                onClose: () => navigator.pop(),
              ),
            ),
          ),
        ),
      );
    } finally {
      if (isMounted()) {
        attachmentsOpen = false;
        onChanged();
        showKeyboard();
      }
    }
  }

  Future<void> pickImages() async {
    if (_pickingImages) return;
    _pickingImages = true;
    try {
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: '图片',
            extensions: [
              'png',
              'jpg',
              'jpeg',
              'gif',
              'webp',
              'bmp',
              'heic',
              'heif',
              'avif',
            ],
            mimeTypes: ['image/*'],
            uniformTypeIdentifiers: ['public.image'],
          ),
        ],
      );
      if (isMounted() && files.isNotEmpty) {
        unawaited(previewExternalFiles(files));
      }
    } catch (error) {
      if (isMounted()) {
        ScaffoldMessenger.of(context())
            .showSnackBar(SnackBar(content: Text('选择图片失败: $error')));
      }
    } finally {
      _pickingImages = false;
      if (isMounted()) showKeyboard();
    }
  }

  Future<void> showToolsMenu(BuildContext buttonContext) async {
    final hostContext = context();
    final buttonBox = buttonContext.findRenderObject();
    final overlay = Overlay.of(hostContext).context.findRenderObject();
    if (buttonBox is! RenderBox ||
        !buttonBox.attached ||
        !buttonBox.hasSize ||
        overlay is! RenderBox) {
      return;
    }
    final action = await showMenu<String>(
      shape: hostContext.isMaterial
          ? null
          : isDesktop()
          ? composerControlShape
          : null,
      context: hostContext,
      position: RelativeRect.fromRect(
        buttonBox.localToGlobal(Offset.zero) & buttonBox.size,
        Offset.zero & overlay.size,
      ),
      items: [
        if (isDesktop() || keyboardMouse()) ...[
          const PopupMenuItem<String>(
            value: 'file',
            child: Row(
              children: [
                Icon(Icons.attach_file_rounded, size: 22),
                SizedBox(width: 12),
                Text('发送文件'),
              ],
            ),
          ),
          const PopupMenuItem<String>(
            value: 'poll',
            child: Row(
              children: [
                Icon(Icons.poll_outlined, size: 22),
                SizedBox(width: 12),
                Text('发起投票'),
              ],
            ),
          ),
          const PopupMenuItem<String>(
            value: 'location',
            child: Row(
              children: [
                Icon(Icons.location_on_outlined, size: 22),
                SizedBox(width: 12),
                Text('发送位置'),
              ],
            ),
          ),
        ],
        if (isDesktop())
          PopupMenuItem<String>(
            value: 'keyboard',
            child: Row(
              children: [
                Icon(
                  Icons.keyboard_rounded,
                  color: hostContext.neu.textSecondary,
                  size: 22,
                ),
                const SizedBox(width: 12),
                const Text('发送与换行按键'),
              ],
            ),
          ),
        PopupMenuItem<String>(
          value: 'markdown',
          child: Row(
            children: [
              Icon(
                Icons.edit_note_rounded,
                color: hostContext.neu.textSecondary,
                size: 22,
              ),
              const SizedBox(width: 12),
              const Text('Markdown 编辑器'),
            ],
          ),
        ),
      ],
    );
    if (isMounted() && action == 'file') {
      final files = await openFiles();
      if (isMounted() && files.isNotEmpty) {
        unawaited(previewExternalFiles(files));
      }
    }
    if (isMounted() && (action == 'poll' || action == 'location')) {
      await _openAttachmentTool(
        action == 'poll' ? AttachmentTab.poll : AttachmentTab.location,
      );
    }
    if (action == 'keyboard' && isMounted()) {
      await showDialog<void>(
        context: context(),
        builder: (context) => AlertDialog(
          shape: context.isMaterial ? null : composerControlShape,
          title: const Text('发送与换行按键'),
          content: const SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: ComposerKeyboardSettingsOptions(grouped: false),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      );
      if (isMounted()) showKeyboard();
    }
    if (action == 'markdown' && isMounted()) openMarkdownComposer();
  }

  Future<void> _openAttachmentTool(AttachmentTab tab) async {
    if (attachmentsOpen) return;
    final hostContext = context();
    final container = ProviderScope.containerOf(hostContext, listen: false);
    final navigator = Navigator.of(hostContext, rootNavigator: true);
    final roomId = draftKey.roomId;
    hidePanel();
    attachmentsOpen = true;
    onChanged();
    try {
      await showDialog<void>(
        context: hostContext,
        builder: (dialogContext) => Dialog(
          shape: hostContext.isMaterial ? null : composerControlShape,
          clipBehavior: Clip.antiAlias,
          child: ScaffoldMessenger(
            child: SizedBox(
              width: 720,
              height: MediaQuery.sizeOf(dialogContext).height * .85,
              child: Scaffold(
                body: AttachmentPicker(
                  initialTab: tab,
                  enforceAccount: true,
                  accountUserId: draftKey.userId,
                  roomId: roomId,
                  height: MediaQuery.sizeOf(dialogContext).height * .85,
                  maxHeight: MediaQuery.sizeOf(dialogContext).height * .85,
                  totalMembers: totalMembers(),
                  onRefresh: (_) => refreshMessagesContainer(container, roomId),
                  resolveSendPresentation: resolveSendPresentation,
                  onMessageQueued: onMessageQueued,
                  onMessageSent: onMessageSent,
                  onHeightChanged: (_) {},
                  onClose: () => navigator.pop(),
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      if (isMounted()) {
        attachmentsOpen = false;
        onChanged();
        showKeyboard();
      }
    }
  }

  Future<void> openMarkdownComposer() async {
    if (sourceLoading()) return;
    hidePanel();
    composerOpen = true;
    final roomId = draftKey.roomId;
    final members = totalMembers();
    final container = ProviderScope.containerOf(context(), listen: false);
    final navigator = Navigator.of(context(), rootNavigator: true);
    final editing = ref.read(editingMessageProvider(draftKey));
    final draftState = ref.read(messageDraftProvider(draftKey).notifier);
    final editDraftState = ref.read(editingDraftProvider(draftKey).notifier);
    final detachedTyping = DetachedComposerTyping(
      container: container,
      roomId: roomId,
      userId: draftKey.userId,
    );
    void persistText(String text) {
      if (editing == null) {
        draftState.value = text;
      } else {
        editDraftState.value = (editingId: editing.id, text: text);
      }
    }

    void showSendError(Object error) {
      if (container.read(activeUserIdProvider) != draftKey.userId) return;
      final feedbackContext = navigator.context;
      if (!feedbackContext.mounted) return;
      ScaffoldMessenger.maybeOf(feedbackContext)?.showSnackBar(
        SnackBar(
          content: Text('发送失败: $error'),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    final result = await navigator.push<MarkdownComposerResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => MarkdownComposerPage(
          initialText: textController.text,
          onSend: (text, composerRef) => isMounted()
              ? sendText(text, onDetachedError: showSendError)
              : sendDraftText(
                  composerRef,
                  roomId: roomId,
                  draftKey: draftKey,
                  rawText: text,
                  totalMembers: members,
                  composerHoldsDraft: true,
                  refreshContainer: container,
                  onError: showSendError,
                ),
          onTyping: (typing) {
            if (isMounted()) {
              onTyping(typing);
            } else {
              detachedTyping.setTyping(typing);
            }
          },
          onDraftChanged: persistText,
        ),
      ),
    );
    detachedTyping.setTyping(false);
    composerOpen = false;
    if (!isMounted()) {
      if (result != null && !result.sent) persistText(result.text);
      return;
    }
    if (result == null || result.sent) return;
    if (result.text != textController.text) {
      textController.value = TextEditingValue(
        text: result.text,
        selection: TextSelection.collapsed(offset: result.text.length),
      );
    }
  }
}
