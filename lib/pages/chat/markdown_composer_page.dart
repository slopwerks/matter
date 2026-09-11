import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/markdown/markdown_composer.dart';
import '../../features/markdown/markdown_format_toolbar.dart';
import '../../features/markdown/markdown_text_editing_controller.dart';
import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../theme/neu_colors.dart';

/// What the full-screen markdown composer returns to the message input:
/// the (possibly edited) draft [text], and whether the message was [sent]
/// — in which case the input clears its own draft instead of restoring.
class MarkdownComposerResult {
  final String text;
  final bool sent;

  const MarkdownComposerResult({required this.text, required this.sent});
}

/// Full-screen markdown editor with a live preview mode. Opened from the
/// message input with the current draft; closing (close button or system
/// back) returns the edited text so no draft is lost, while sending goes
/// through the input's normal pipeline (optimistic bubble, reply/edit
/// handling, failure retry) via [onSend].
///
/// The [onSend] ref is the route's own element as a [WidgetRef]: while the
/// opening input is still alive it is identical to that state's ref, so the
/// caller can route through its full local pipeline; after a layout switch
/// disposed the host it stays live on this route (the root navigator keeps
/// it), letting the caller fall back to provider-only state.
class MarkdownComposerPage extends ConsumerStatefulWidget {
  final String initialText;

  /// Sends [text] through the caller's send pipeline. Returns true when
  /// the message was accepted for sending; on false the editor stays open
  /// so the draft is not lost.
  final Future<bool> Function(String text, WidgetRef ref) onSend;

  /// Reports active and idle typing transitions. The editor owns the idle
  /// timer because its route can outlive the input widget that opened it.
  final ValueChanged<bool>? onTyping;

  /// Called with the current text on every edit, so the draft can be
  /// synced to state that outlives the page's host (a responsive layout
  /// switch may dispose the host while this route stays open).
  final ValueChanged<String>? onDraftChanged;

  const MarkdownComposerPage({
    super.key,
    required this.initialText,
    required this.onSend,
    this.onTyping,
    this.onDraftChanged,
  });

  @override
  ConsumerState<MarkdownComposerPage> createState() =>
      _MarkdownComposerPageState();
}

class _MarkdownComposerPageState extends ConsumerState<MarkdownComposerPage> {
  static const _composer = MarkdownComposer();

  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  bool _previewing = false;
  bool _sending = false;
  bool _closing = false;
  late bool _hasText;
  bool _typingActive = false;
  Timer? _typingIdleTimer;

  @override
  void initState() {
    super.initState();
    _controller = MarkdownTextEditingController(text: widget.initialText);
    _hasText = widget.initialText.trim().isNotEmpty;
    _controller.addListener(() {
      final text = _controller.text;
      final hasText = text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
      if (hasText) {
        _typingActive = true;
        widget.onTyping?.call(true);
        _typingIdleTimer?.cancel();
        _typingIdleTimer = Timer(const Duration(seconds: 3), _stopTyping);
      } else {
        _stopTyping();
      }
      widget.onDraftChanged?.call(text);
    });
  }

  void _stopTyping() {
    _typingIdleTimer?.cancel();
    _typingIdleTimer = null;
    if (!_typingActive) return;
    _typingActive = false;
    widget.onTyping?.call(false);
  }

  /// Single exit path for the close button, system back and a completed
  /// send; the [_closing] latch keeps a second trigger (double-tap, or a
  /// send finishing after the user already closed) from popping the route
  /// underneath the composer. Closing mid-send takes effect immediately —
  /// parking the request behind a possibly long-running network call would
  /// strand the user in the editor.
  void _close({bool sent = false}) {
    if (_closing) return;
    _closing = true;
    // Closing while a send is in flight: the text has already been handed
    // to the send pipeline (optimistic bubble; a failure leaves a
    // retryable failed message), so the input must not restore it as a
    // draft when the composer closes.
    final consumed = sent || _sending;
    Navigator.of(context).pop(
      MarkdownComposerResult(
        text: consumed ? '' : _controller.text,
        sent: consumed,
      ),
    );
  }

  Future<void> _send() async {
    if (_closing) return;
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final sent = await widget.onSend(_controller.text, ref);
      // If the user already closed mid-send, the latch swallows this.
      if (sent && mounted) {
        _close(sent: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _stopTyping();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _setPreviewing(bool previewing) {
    setState(() => _previewing = previewing);
    if (previewing) {
      _focusNode.unfocus();
    } else {
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return PopScope(
      // Keep system back from dropping in-editor edits: veto it and close
      // through the same draft-returning path as the close button.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Markdown'),
          leading: IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded),
            onPressed: _close,
          ),
          actions: [
            IconButton(
              tooltip: '发送',
              onPressed: _hasText && !_sending ? _send : null,
              icon: _sending
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        color: colors.accent,
                        strokeWidth: 2,
                      ),
                    )
                  : Icon(Icons.send_rounded, color: colors.accent),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.edit_rounded),
                      label: Text('编辑'),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.visibility_rounded),
                      label: Text('预览'),
                    ),
                  ],
                  selected: {_previewing},
                  onSelectionChanged: (selection) =>
                      _setPreviewing(selection.first),
                ),
              ),
              Expanded(child: _previewing ? _buildPreview() : _buildEditor()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEditor() {
    final colors = context.neu;
    final editorStyle = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w400, height: 1.5);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        readOnly: _sending,
        autofocus: true,
        contextMenuBuilder: markdownSelectionContextMenuBuilder,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        cursorColor: colors.accent,
        style: editorStyle,
        decoration: InputDecoration(
          hintText: '用 Markdown 编写消息…',
          hintStyle: editorStyle?.copyWith(color: colors.textTertiary),
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final colors = context.neu;
    final textStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w400,
          height: 1.5,
        ) ??
        const TextStyle(fontSize: 16, height: 1.5);
    final compiled = _composer.compile(_controller.text);
    final formattedBody = compiled.formattedBody;
    final Widget content;
    if (formattedBody != null) {
      content = MatrixHtmlMessage(
        html: formattedBody,
        style: textStyle,
        accentColor: colors.accent,
      );
    } else if (compiled.body.isNotEmpty) {
      content = Text(compiled.body, style: textStyle);
    } else {
      content = Center(
        child: Text('暂无内容可预览', style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: SizedBox(width: double.infinity, child: content),
        ),
      ),
    );
  }
}
