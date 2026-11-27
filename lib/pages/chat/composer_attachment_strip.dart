import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/interaction_mode_provider.dart';

import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import 'attachment_caption_composer.dart';
import 'attachment_media_draft.dart';

class ComposerAttachmentStrip extends ConsumerWidget {
  const ComposerAttachmentStrip({
    super.key,
    required this.draft,
    required this.onPreview,
  });

  final AttachmentMediaDraft draft;
  final void Function(AttachmentMediaItem, List<AttachmentMediaItem>) onPreview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = ref
        .watch(interactionModeProvider)
        .usesKeyboardMouse(Theme.of(context).platform);
    if (draft.selected.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final material = context.isMaterial;
    final images = draft.selected.where((item) => item.isImage).toList();
    final strip = SizedBox(
      key: const ValueKey('composer-attachment-strip'),
      height: material ? 68 : 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = images[index];
          return SizedBox(
            key: ValueKey('pending-attachment:${item.id}'),
            width: material ? 56 : 104,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Material(
                  clipBehavior: Clip.antiAlias,
                  shape: composerThumbnailShape(Theme.of(context)),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: InkWell(
                    onTap: draft.isSending
                        ? null
                        : () => onPreview(item, images),
                    child: Tooltip(
                      message: item.editedFilename ?? item.file?.name ?? '图片',
                      child: _Thumbnail(item: item),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: draft.isSending ? null : () => draft.toggle(item),
                    child: SizedBox.square(
                      dimension: compact ? 32 : 48,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: IconButton.filledTonal(
                          key: ValueKey('remove-attachment:${item.id}'),
                          tooltip: '移除图片',
                          style: composerThumbnailRemoveStyle(
                            Theme.of(context),
                            compact: true,
                          ),
                          onPressed: draft.isSending
                              ? null
                              : () => draft.toggle(item),
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    final originalToggle = images.isEmpty
        ? null
        : AttachmentOriginalToggle(
            sendOriginal: !draft.hasCompressibleImages || draft.sendOriginal,
            enabled: !draft.isSending && draft.hasCompressibleImages,
            onPressed: draft.toggleSendOriginal,
          );
    if (!material) {
      if (originalToggle == null) return strip;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          strip,
          Align(alignment: Alignment.centerLeft, child: originalToggle),
        ],
      );
    }
    final style = materialAttachmentStageStyle(theme);
    final gallery = materialGalleryStyle(theme);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: style.fill,
        shape: style.shape,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('待发送图片', style: style.title),
                  const SizedBox(width: 6),
                  Badge(
                    backgroundColor: gallery.badge,
                    textColor: gallery.badgeText,
                    label: Text('${images.length}'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      draft.isSending ? '正在发送…' : '点击预览',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.status,
                    ),
                  ),
                  ?originalToggle,
                  TextButton(
                    onPressed: draft.isSending
                        ? null
                        : () {
                            for (final item in images) {
                              draft.toggle(item);
                            }
                          },
                    child: const Text('清空'),
                  ),
                ],
              ),
              strip,
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.item});
  final AttachmentMediaItem item;
  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  late Future<Uint8List> _bytes = widget.item.readImageBytes();
  Uint8List? _edit;

  @override
  void initState() {
    super.initState();
    _edit = widget.item.editedBytes;
  }

  @override
  void didUpdateWidget(covariant _Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item != widget.item ||
        !identical(_edit, widget.item.editedBytes)) {
      _edit = widget.item.editedBytes;
      _bytes = widget.item.readImageBytes();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) => snapshot.hasData
        ? Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            cacheWidth: 208,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          )
        : Icon(
            snapshot.hasError
                ? Icons.broken_image_outlined
                : Icons.image_outlined,
          ),
  );
}
