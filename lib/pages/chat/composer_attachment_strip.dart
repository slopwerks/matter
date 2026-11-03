import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/interaction_mode_provider.dart';

import '../../theme/material_theme.dart';
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
    final images = draft.selected.where((item) => item.isImage).toList();
    return SizedBox(
      key: const ValueKey('composer-attachment-strip'),
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = images[index];
          return SizedBox(
            key: ValueKey('pending-attachment:${item.id}'),
            width: 104,
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
                  child: IconButton.filledTonal(
                    tooltip: '移除图片',
                    style: composerIconButtonStyle(
                      Theme.of(context),
                      compact: compact,
                    ),
                    onPressed: draft.isSending
                        ? null
                        : () => draft.toggle(item),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ),
              ],
            ),
          );
        },
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
