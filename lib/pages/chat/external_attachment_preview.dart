import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/max_content_width.dart';
import 'attachment_media_draft.dart';

/// Clipboard and dropped files share the picker's existing upload pipeline.
class ExternalAttachmentPreview extends StatelessWidget {
  const ExternalAttachmentPreview({
    super.key,
    required this.draft,
    required this.onSend,
    required this.onClose,
    required this.onPreview,
  });

  final AttachmentMediaDraft draft;
  final Future<void> Function() onSend;
  final VoidCallback onClose;
  final void Function(AttachmentMediaItem, List<AttachmentMediaItem>) onPreview;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: draft,
    builder: (context, _) {
      final actions = <Widget>[
        TextButton(
          onPressed: draft.isSending ? null : onClose,
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('external-attachment-send'),
          style: context.isMaterial
              ? null
              : composerSendButtonStyle(Theme.of(context), compact: true),
          onPressed: draft.isSending || draft.selected.isEmpty
              ? null
              : () async {
                  try {
                    await onSend();
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('发送失败: $error')));
                    }
                  }
                },
          child: Text(
            draft.isSending ? '发送中…' : '发送 ${draft.selected.length} 项',
          ),
        ),
      ];
      final footer = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (draft.hasImages)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: draft.description,
                readOnly: draft.isSending,
                maxLines: 3,
                minLines: 1,
                decoration: context.isMaterial
                    ? const InputDecoration(labelText: '图片说明（可选）')
                    : const InputDecoration(hintText: '图片说明（可选）'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: context.isMaterial
                ? Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: actions,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      actions.first,
                      const SizedBox(width: 8),
                      actions.last,
                    ],
                  ),
          ),
        ],
      );
      return PopScope(
        canPop: !draft.isSending,
        child: Scaffold(
          appBar: context.isMaterial
              ? buildFloatingAppBar(
                  title: const Text('发送附件'),
                  automaticallyImplyLeading: !draft.isSending,
                )
              : AppBar(
                  title: const Text('发送附件'),
                  automaticallyImplyLeading: !draft.isSending,
                ),
          body: MaxContentWidth(
            maxWidth: context.isMaterial ? 720 : double.infinity,
            child: Column(
              children: [
                if (context.isMaterial)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        leading: const Icon(Icons.attach_file_rounded),
                        title: Text('待发送附件 · ${draft.selected.length} 项'),
                        subtitle: const Text('点击图片预览，移除不需要的附件。'),
                      ),
                    ),
                  ),
                Expanded(
                  child: context.isMaterial && draft.selected.isEmpty
                      ? Center(
                          child: Text(
                            '尚未选择附件',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        )
                      : ListView.separated(
                          itemCount: draft.selected.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = draft.selected[index];
                            return ListTile(
                              leading: item.isImage
                                  ? SizedBox.square(
                                      dimension: 56,
                                      child: FutureBuilder<Uint8List>(
                                        future: item.readImageBytes(),
                                        builder: (context, snapshot) =>
                                            snapshot.hasData
                                            ? Image.memory(
                                                snapshot.data!,
                                                fit: BoxFit.contain,
                                                errorBuilder: (_, _, _) =>
                                                    const Icon(
                                                      Icons
                                                          .broken_image_outlined,
                                                    ),
                                              )
                                            : const Icon(Icons.image_outlined),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.insert_drive_file_outlined,
                                    ),
                              title: Text(
                                item.editedFilename ?? item.file?.name ?? '附件',
                              ),
                              onTap: item.isImage && !draft.isSending
                                  ? () => onPreview(
                                      item,
                                      draft.selected
                                          .where((file) => file.isImage)
                                          .toList(),
                                    )
                                  : null,
                              trailing: IconButton(
                                tooltip: '移除附件',
                                onPressed: draft.isSending
                                    ? null
                                    : () => draft.toggle(item),
                                icon: const Icon(Icons.close),
                              ),
                            );
                          },
                        ),
                ),
                if (context.isMaterial)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: footer,
                        ),
                      ),
                    ),
                  )
                else
                  footer,
              ],
            ),
          ),
        ),
      );
    },
  );
}
