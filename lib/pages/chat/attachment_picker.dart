import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_visual_settings_provider.dart';
import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
import '../../widgets/neu_decoration.dart';
import 'latest_message_control.dart';
import 'external_attachment_preview.dart';
import 'composer_attachment_strip.dart';
import 'attachment_caption_composer.dart';
import 'attachment_image_preview_page.dart';
import 'attachment_media_draft.dart';
import 'attachment_media_gallery.dart';
import 'attachment_location_tab.dart';
import 'attachment_picker_controls.dart';
import 'attachment_poll_tab.dart';
import 'attachment_send_controller.dart';

export 'attachment_media_utils.dart'
    show
        AttachmentMediaKind,
        resolveAttachmentMime,
        classifyAttachmentMime,
        detectImageMime;

export 'attachment_media_gallery.dart' show attachmentMediaOrder;

export 'attachment_picker_controls.dart' show AttachmentTab;
export 'attachment_location_tab.dart'
    show canonicalGeoUri, currentAttachmentLocation;

/// Whether [photo_manager]'s native gallery grid works on this platform.
/// On Web/Linux/Windows it has no implementation and must be replaced with a
/// [file_selector] fallback to avoid MissingPluginException.
bool get photoManagerSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// An inline attachment panel that starts at the keyboard height and expands
/// as the active content is dragged upward.
class AttachmentPicker extends StatefulWidget {
  final double height;
  final double maxHeight;
  final String roomId;
  final String accountUserId;
  final Future<void> Function(String roomId) onRefresh;
  final MessageSendPresentation Function() resolveSendPresentation;
  final void Function(
    MessageSendPresentation presentation,
    bool insertedOptimistically,
  )
  onMessageSent;

  /// Announces an optimistic image row so the timeline can play its entrance
  /// animation, exactly like a text or sticker send.
  final void Function(
    String stableMessageId,
    MessageSendPresentation presentation,
  )
  onMessageQueued;
  final int totalMembers;
  final ValueChanged<double> onHeightChanged;
  final VoidCallback onClose;
  final AttachmentTab initialTab;
  final bool enforceAccount;
  final List<XFile>? initialFiles;
  final AttachmentMediaDraft? draft;
  final bool inline;
  final TextEditingController? composerController;
  final Future<bool> Function()? onInlineSend;
  final ValueChanged<List<AttachmentMediaItem>>? onImagesSelected;
  final ValueChanged<List<AttachmentMediaItem>>? onImagesDeselected;
  final AttachmentMediaDraft? composerDraft;

  const AttachmentPicker({
    super.key,
    required this.height,
    required this.maxHeight,
    required this.roomId,
    required this.accountUserId,
    required this.onRefresh,
    required this.resolveSendPresentation,
    required this.onMessageSent,
    required this.onMessageQueued,
    required this.totalMembers,
    required this.onHeightChanged,
    required this.onClose,
    this.initialTab = AttachmentTab.media,
    this.enforceAccount = false,
    this.initialFiles,
    this.draft,
    this.inline = false,
    this.composerController,
    this.onInlineSend,
    this.onImagesSelected,
    this.onImagesDeselected,
    this.composerDraft,
  });

  @override
  AttachmentPickerState createState() => AttachmentPickerState();
}

class AttachmentPickerState extends State<AttachmentPicker> {
  late final DraggableScrollableController _sheetController;
  late final ValueNotifier<double> _sheetExtent;
  AttachmentTab _tab = AttachmentTab.media;
  final Set<AttachmentTab> _visitedTabs = {AttachmentTab.media};
  late final AttachmentSendController _sender;
  bool _isPickingFiles = false;
  late final _mediaDraft = widget.draft ?? AttachmentMediaDraft();
  bool _previewOpen = false;
  List<AttachmentMediaItem> _stagedImages = [];
  bool _syncingImages = false;

  @override
  void initState() {
    super.initState();
    _sender = AttachmentSendController(
      container: ProviderScope.containerOf(context, listen: false),
      draftKey: (roomId: widget.roomId, userId: widget.accountUserId),
      draft: _mediaDraft,
      roomId: () => widget.roomId,
      totalMembers: () => widget.totalMembers,
      isMounted: () => mounted,
      previewOpen: () => _previewOpen,
      hasSharedDraft: () => widget.draft != null,
      enforceAccount: () =>
          widget.initialFiles != null || widget.inline || widget.enforceAccount,
      onChanged: () {
        if (mounted) setState(() {});
      },
      onError: (message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      ),
      onRefresh: (roomId) => widget.onRefresh(roomId),
      resolveSendPresentation: () => widget.resolveSendPresentation(),
      onMessageQueued: (id, presentation) =>
          widget.onMessageQueued(id, presentation),
      onMessageSent: (presentation, optimistic) =>
          widget.onMessageSent(presentation, optimistic),
      onClose: () => widget.onClose(),
    );
    if (widget.onImagesSelected != null) {
      _mediaDraft.description.text = widget.composerController!.text;
    }
    _sheetController = DraggableScrollableController();
    _sheetExtent = ValueNotifier<double>(0);
    _tab = widget.initialTab;
    _visitedTabs.add(widget.initialTab);
    for (final file in widget.initialFiles ?? const <XFile>[]) {
      final item = _mediaDraft.forFile(file);
      if (!_mediaDraft.selected.contains(item)) _mediaDraft.toggle(item);
    }
    if (widget.onImagesSelected != null) {
      final pending = widget.composerDraft;
      if (pending != null) {
        _stagedImages = pending.selected.where((item) => item.isImage).toList();
        _mediaDraft.addItems(_stagedImages);
        pending.addListener(_syncComposerImages);
      }
      _mediaDraft.addListener(_syncImages);
    }
  }

  @override
  void dispose() {
    widget.composerDraft?.removeListener(_syncComposerImages);
    _mediaDraft.removeListener(_syncImages);
    _sheetController.dispose();
    _sheetExtent.dispose();
    if (!_previewOpen && widget.draft == null) _mediaDraft.dispose();
    super.dispose();
  }

  Future<bool> sendSelectedMedia({
    required String description,
    bool includeReply = true,
  }) {
    if (_sender.isSending || _mediaDraft.isSending) return Future.value(false);
    _mediaDraft.description.text = description;
    return _sender.sendSelectedMedia(
      closePicker: false,
      includeReply: includeReply,
    );
  }

  Future<void> _openPreview(
    AttachmentMediaItem item,
    List<AttachmentMediaItem> images,
  ) async {
    if (_sender.isSending || _previewOpen) return;
    _previewOpen = true;
    if (widget.inline || widget.onImagesSelected != null) {
      _mediaDraft.description.text = widget.composerController!.text;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final route = MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => AttachmentImagePreviewPage(
        draft: _mediaDraft,
        images: images,
        initialImage: item,
        onCaptionFocus: _expandForCaption,
        actionLabel: _stagingImages ? '完成' : null,
        allowDescription: !widget.inline && widget.onImagesSelected == null,
        onSend: _stagingImages
            ? () async => _stageImages()
            : widget.inline
            ? () {
                widget.composerController!.text = _mediaDraft.description.text;
                return widget.onInlineSend!();
              }
            : () => _sender.sendSelectedMedia(closePicker: false),
      ),
    );
    try {
      final sent = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
      if (widget.inline && mounted && sent != true) {
        widget.composerController!.text = _mediaDraft.description.text;
      }
      if (mounted && sent == true) widget.onClose();
    } finally {
      _previewOpen = false;
      if (!mounted && widget.draft == null) _mediaDraft.dispose();
    }
  }

  bool get _stagingImages =>
      widget.onImagesSelected != null &&
      _mediaDraft.selected.every((item) => item.isImage);

  void _syncImages() {
    if (_syncingImages) return;
    _syncingImages = true;
    try {
      final images = _mediaDraft.selected
          .where((item) => item.isImage)
          .toList();
      final removed = _stagedImages
          .where((item) => !images.contains(item))
          .toList();
      _stagedImages = images;
      if (removed.isNotEmpty) widget.onImagesDeselected?.call(removed);
      if (images.isNotEmpty) widget.onImagesSelected!(images);
    } finally {
      _syncingImages = false;
    }
  }

  void _syncComposerImages() {
    if (_syncingImages) return;
    _syncingImages = true;
    try {
      final images = widget.composerDraft!.selected
          .where((item) => item.isImage)
          .toList();
      _mediaDraft.selected.removeWhere((item) => item.isImage);
      _mediaDraft.addItems(images);
      _stagedImages = images;
    } finally {
      _syncingImages = false;
    }
  }

  bool _stageImages() {
    if (_mediaDraft.isSending || _mediaDraft.selected.isEmpty) return false;
    if (_mediaDraft.selected.any((item) => !item.isImage)) return false;
    widget.onImagesSelected!(List.of(_mediaDraft.selected));
    return true;
  }

  void _expandForCaption() {
    if (!mounted) return;
    widget.onHeightChanged(widget.maxHeight);
    if (_sheetController.isAttached) {
      unawaited(
        _sheetController.animateTo(
          1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  Future<void> _pickFiles() async {
    if (_sender.isSending || _isPickingFiles) return;
    setState(() => _isPickingFiles = true);
    try {
      final files = List<XFile>.of(await openFiles());
      if (!mounted || files.isEmpty) return;
      await _sender.sendFiles(files);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选择文件失败: $error')));
      }
    } finally {
      if (mounted) setState(() => _isPickingFiles = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _mediaDraft,
    builder: (context, _) => _buildPanel(context),
  );

  Widget _buildPanel(BuildContext context) {
    if (widget.inline) {
      return ComposerAttachmentStrip(
        draft: _mediaDraft,
        onPreview: _openPreview,
      );
    }
    if (widget.initialFiles != null) {
      return ExternalAttachmentPreview(
        draft: _mediaDraft,
        onClose: widget.onClose,
        onPreview: _openPreview,
        onSend: () async {
          if (await _sender.sendSelectedMedia(closePicker: false) && mounted) {
            widget.onClose();
          }
        },
      );
    }
    final maxHeight = math.max(widget.height, widget.maxHeight);
    final minSize = (widget.height / maxHeight).clamp(0.01, 1.0);
    if (_sheetExtent.value == 0) _sheetExtent.value = minSize;

    return ValueListenableBuilder<double>(
      valueListenable: _sheetExtent,
      builder: (context, extent, _) {
        final visibleHeight = (extent * maxHeight).clamp(
          widget.height,
          maxHeight,
        );
        return SizedBox(
          width: double.infinity,
          height: visibleHeight,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.bottomCenter,
              minHeight: maxHeight,
              maxHeight: maxHeight,
              child: SizedBox(
                width: double.infinity,
                height: maxHeight,
                child: NotificationListener<DraggableScrollableNotification>(
                  onNotification: (notification) {
                    if ((_sheetExtent.value - notification.extent).abs() >
                        0.0005) {
                      _sheetExtent.value = notification.extent;
                      widget.onHeightChanged(notification.extent * maxHeight);
                    }
                    return false;
                  },
                  child: DraggableScrollableSheet(
                    controller: _sheetController,
                    expand: false,
                    initialChildSize: minSize,
                    minChildSize: minSize,
                    maxChildSize: 1,
                    builder: (context, scrollController) => _buildSheet(
                      context,
                      scrollController,
                      maxHeight: maxHeight,
                      minSize: minSize,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSheet(
    BuildContext context,
    ScrollController scrollController, {
    required double maxHeight,
    required double minSize,
  }) {
    final colors = context.neu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        decoration: context.isMaterial
            ? null
            : NeuDecoration(
                colors: colors,
                superellipseEnabled: ChatVisualSettingsScope.of(context)
                    .superellipseBorderEnabled,
                radius: NeuRadius.surface,
                intensity: .6,
              ),
        child: Material(
          type: context.isMaterial
              ? MaterialType.canvas
              : MaterialType.transparency,
          color: context.isMaterial
              ? Theme.of(context).colorScheme.surfaceContainerLow
              : null,
          clipBehavior: Clip.antiAlias,
          shape: context.isMaterial
              ? materialListItemShape
              : (ChatVisualSettingsScope.maybeOf(context)
                        ?.superellipseBorderEnabled ??
                    true)
              ? RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(NeuRadius.surface),
                )
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NeuRadius.surface),
                ),
          child: Column(
            children: [
              GestureDetector(
                key: const ValueKey('attachment-panel-drag-handle'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) => _dragSheet(
                  details.primaryDelta ?? 0,
                  maxHeight: maxHeight,
                  minSize: minSize,
                ),
                onVerticalDragEnd: (details) => _settleSheet(
                  details.primaryVelocity ?? 0,
                  minSize: minSize,
                ),
                child: SizedBox(
                  height: 32,
                  child: Center(
                    child: Container(
                      width: 34,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.textTertiary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: colors.hairline),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: IndexedStack(
                        index: _tab.index,
                        children: [
                          _buildTabBody(AttachmentTab.media, scrollController),
                          const SizedBox.shrink(),
                          _buildTabBody(AttachmentTab.poll, scrollController),
                          _buildTabBody(
                            AttachmentTab.location,
                            scrollController,
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child:
                          _tab == AttachmentTab.media &&
                              _mediaDraft.selected.isNotEmpty
                          ? AttachmentCaptionComposer(
                              draft: _mediaDraft,
                              allowDescription:
                                  _mediaDraft.hasImages &&
                                  widget.onImagesSelected == null,
                              actionLabel: _stagingImages ? '完成' : null,
                              onFocus: _expandForCaption,
                              onClear: () {
                                _mediaDraft.selected.clear();
                                _mediaDraft.selectionChanged();
                                FocusManager.instance.primaryFocus?.unfocus();
                              },
                              onSend: () {
                                if (_stagingImages) {
                                  if (_stageImages()) widget.onClose();
                                } else {
                                  unawaited(_sender.sendSelectedMedia());
                                }
                              },
                            )
                          : AttachmentTabBar(
                              tab: _tab,
                              isFileBusy: _isPickingFiles,
                              onTabChanged: _sender.isSending || _isPickingFiles
                                  ? null
                                  : _selectTab,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabBody(
    AttachmentTab tab,
    ScrollController sheetScrollController,
  ) {
    if (!_visitedTabs.contains(tab)) return const SizedBox.shrink();
    final scrollController = _tab == tab ? sheetScrollController : null;
    return switch (tab) {
      AttachmentTab.media =>
        photoManagerSupported
            ? AttachmentGalleryTab(
                draft: _mediaDraft,
                scrollController: scrollController,
                onPreview: _openPreview,
              )
            : AttachmentMediaFallback(
                draft: _mediaDraft,
                scrollController: scrollController,
                onPreview: _openPreview,
              ),
      AttachmentTab.poll => AttachmentPollTab(
        isSending: _sender.isSending,
        scrollController: scrollController,
        onSendPoll: _sender.sendPoll,
      ),
      AttachmentTab.location => AttachmentLocationTab(
        isSending: _sender.isSending,
        scrollController: scrollController,
        onSendLocation: _sender.sendLocation,
      ),
      AttachmentTab.file => const SizedBox.shrink(),
    };
  }

  void _selectTab(AttachmentTab tab) {
    if (tab == AttachmentTab.file) {
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      unawaited(_pickFiles());
      return;
    }
    if (tab != _tab) {
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
    setState(() {
      _visitedTabs.add(tab);
      _tab = tab;
    });
  }

  void _dragSheet(
    double delta, {
    required double maxHeight,
    required double minSize,
  }) {
    if (!_sheetController.isAttached) return;
    final target = (_sheetController.size - delta / maxHeight).clamp(
      minSize,
      1.0,
    );
    _sheetController.jumpTo(target);
  }

  Future<void> _settleSheet(double velocity, {required double minSize}) async {
    if (!_sheetController.isAttached) return;
    final target =
        velocity < -300 ||
            (velocity <= 300 &&
                _sheetController.size > minSize + (1 - minSize) / 2)
        ? 1.0
        : minSize;
    await _sheetController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }
}
