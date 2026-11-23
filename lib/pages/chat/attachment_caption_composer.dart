import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/glass.dart';
import 'attachment_media_draft.dart';

const attachmentCaptionClearance = 144.0;

class AttachmentCaptionComposer extends StatefulWidget {
  final AttachmentMediaDraft draft;
  final VoidCallback onSend;
  final VoidCallback? onClear;
  final VoidCallback? onFocus;
  final int? sendCount;
  final bool allowDescription;

  const AttachmentCaptionComposer({
    super.key,
    required this.draft,
    required this.onSend,
    this.onClear,
    this.onFocus,
    this.sendCount,
    this.allowDescription = true,
  });

  @override
  State<AttachmentCaptionComposer> createState() =>
      _AttachmentCaptionComposerState();
}

class _AttachmentCaptionComposerState extends State<AttachmentCaptionComposer> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (_focus.hasFocus) widget.onFocus?.call();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final theme = Theme.of(context);
    final material = context.isMaterial;
    final count = widget.sendCount ?? widget.draft.selected.length;
    final content = Row(
      children: [
        if (widget.onClear != null)
          IconButton(
            tooltip: '取消选择',
            onPressed: widget.draft.isSending ? null : widget.onClear,
            icon: Icon(
              material ? Icons.cancel_outlined : CupertinoIcons.xmark_circle,
              color: material
                  ? theme.colorScheme.onSurfaceVariant
                  : colors.textSecondary,
              size: 22,
            ),
          ),
        Expanded(
          child: widget.allowDescription
              ? TextField(
                  key: const ValueKey('attachment-caption-input'),
                  controller: widget.draft.description,
                  focusNode: _focus,
                  readOnly: widget.draft.isSending,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 4096,
                  keyboardType: TextInputType.multiline,
                  style: material
                      ? theme.textTheme.bodyLarge
                      : TextStyle(color: colors.text),
                  decoration: material
                      ? materialAttachmentCaptionDecoration
                      : const InputDecoration(
                          hintText: '添加图片描述',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(
                              Radius.circular(NeuRadius.content),
                            ),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          isDense: true,
                          counterText: '',
                        ),
                )
              : Text(
                  '已选 $count 项',
                  style: material
                      ? theme.textTheme.labelLarge
                      : TextStyle(color: colors.text),
                ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: '发送 $count 项',
          child: FilledButton(
            key: const ValueKey('attachment-send-button'),
            onPressed: widget.draft.isSending || count == 0
                ? null
                : widget.onSend,
            style: material
                ? null
                : FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
            child: widget.draft.isSending
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.onAccent,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        material ? Icons.send_rounded : CupertinoIcons.arrow_up,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text('$count'),
                    ],
                  ),
          ),
        ),
      ],
    );
    return SafeArea(
      top: false,
      child: MaxContentWidth(
        maxWidth: material ? 720 : double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: material
              ? Card(
                  margin: EdgeInsets.zero,
                  color: materialMediaChromeStyle(theme).surface,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: content,
                  ),
                )
              : GlassPanel(
                  radius: NeuRadius.nav,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: content,
                ),
        ),
      ),
    );
  }
}
