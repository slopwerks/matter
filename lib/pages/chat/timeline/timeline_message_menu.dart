import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../src/rust/api/matrix.dart';
import '../../../theme/neu_colors.dart';
import '../../../widgets/glass.dart';

/// An icon-over-text action button used inside the floating message menu.
class _IconTextAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _IconTextAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final c = color ?? colors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NeuRadius.tag),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: c, size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: color ?? colors.text,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A floating popover menu anchored near a long-pressed message bubble.
///
/// Renders as an [OverlayEntry] with a full-screen dismiss barrier. It measures
/// its own size on the first frame (off-screen, invisible), then repositions
/// itself above or below the bubble and fades in.
class TimelineMessageMenu extends StatefulWidget {
  final ChatMessage message;
  final bool isMe;
  final Rect? bubbleRect;
  final VoidCallback onClose;
  final VoidCallback onCopy;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final VoidCallback onEdit;
  final VoidCallback onRecall;
  final bool? isPinned;
  final bool pinStateLoading;
  final VoidCallback? onPin;
  final void Function(String emoji) onReact;
  final VoidCallback onShowFullEmojiPicker;
  final VoidCallback? onReadFullScreen;

  const TimelineMessageMenu({
    super.key,
    required this.message,
    required this.isMe,
    required this.bubbleRect,
    required this.onClose,
    required this.onCopy,
    required this.onReply,
    required this.onForward,
    required this.onEdit,
    required this.onRecall,
    required this.isPinned,
    required this.pinStateLoading,
    required this.onPin,
    required this.onReact,
    required this.onShowFullEmojiPicker,
    this.onReadFullScreen,
  });

  @override
  State<TimelineMessageMenu> createState() => TimelineMessageMenuState();
}

class TimelineMessageMenuState extends State<TimelineMessageMenu> {
  static const _quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
  static const _gap = 8.0;

  final _menuKey = GlobalKey();
  final _focusNode = FocusNode();
  double? _left;
  double? _top;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _measureAndPosition();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TimelineMessageMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pinStateLoading != widget.pinStateLoading) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _measureAndPosition(),
      );
    }
  }

  void _measureAndPosition() {
    final ro = _menuKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    final pos = _resolvePosition(ro.size);
    if (mounted) {
      setState(() {
        _left = pos.left;
        _top = pos.top;
        _ready = true;
      });
    }
  }

  ({double left, double top}) _resolvePosition(Size size) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    final h = mq.size.height;
    final safe = mq.padding;
    final mLeft = safe.left + 8;
    final mRight = w - safe.right - 8;

    final b = widget.bubbleRect;
    if (b == null) {
      final left = (w - size.width) / 2;
      return (left: left.clamp(mLeft, mRight - size.width), top: safe.top + 16);
    }

    final spaceAbove = b.top - safe.top;
    final spaceBelow = h - b.bottom - safe.bottom;
    final placeAbove =
        spaceAbove >= size.height + _gap || spaceAbove >= spaceBelow;
    final top = placeAbove ? b.top - _gap - size.height : b.bottom + _gap;

    var left = widget.isMe ? b.right - size.width : b.left;
    if (left < mLeft) left = mLeft;
    if (left + size.width > mRight) left = mRight - size.width;
    if (left < mLeft) left = mLeft;

    return (left: left, top: top);
  }

  /// Closes the menu, then runs the selected action.
  void _select(VoidCallback action) {
    widget.onClose();
    action();
  }

  Widget _buildEmojiRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._quickEmojis.map((emoji) => _emojiButton(emoji)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(NeuRadius.tag),
                onTap: () => _select(widget.onShowFullEmojiPicker),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    Icons.add_rounded,
                    color: context.neu.textTertiary,
                    size: 22,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emojiButton(String emoji) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(NeuRadius.tag),
        onTap: () => _select(() => widget.onReact(emoji)),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(emoji, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    final msg = widget.message;
    final isEvent = msg.msgType == MessageType.event;
    final isText = msg.msgType == MessageType.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isText)
              _IconTextAction(
                icon: Icons.copy_rounded,
                label: '复制',
                onTap: () => _select(widget.onCopy),
              ),
            if (widget.onReadFullScreen != null)
              _IconTextAction(
                icon: Icons.article_outlined,
                label: '全屏阅读',
                onTap: () => _select(widget.onReadFullScreen!),
              ),
            _IconTextAction(
              icon: Icons.reply_rounded,
              label: '回复',
              onTap: () => _select(widget.onReply),
            ),
            if (!isEvent)
              _IconTextAction(
                icon: Icons.forward_rounded,
                label: '转发',
                onTap: () => _select(widget.onForward),
              ),
            if (!isEvent && widget.onPin != null)
              _IconTextAction(
                icon: widget.isPinned!
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                label: widget.isPinned! ? '取消置顶' : '置顶',
                onTap: () => _select(widget.onPin!),
              ),
            if (!isEvent && widget.pinStateLoading)
              SizedBox(
                width: 56,
                height: 48,
                child: Center(
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: context.neu.textTertiary,
                    ),
                  ),
                ),
              ),
            if (widget.isMe && isText)
              _IconTextAction(
                icon: Icons.edit_outlined,
                label: '编辑',
                onTap: () => _select(widget.onEdit),
              ),
            if (widget.isMe)
              _IconTextAction(
                icon: Icons.delete_outline_rounded,
                label: '撤回',
                color: context.neu.error,
                onTap: () => _select(widget.onRecall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenu() {
    final msg = widget.message;
    final isEvent = msg.msgType == MessageType.event;
    return Material(
      type: MaterialType.transparency,
      child: GlassPanel(
        key: _menuKey,
        radius: NeuRadius.surface,
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isEvent) _buildEmojiRow(),
            if (!isEvent) Divider(color: context.neu.hairline, height: 0.5),
            _buildActionRow(),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (_, event) {
        if (event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent) widget.onClose();
        return KeyEventResult.handled;
      },
      child: Stack(
        children: [
          // Full-screen dismiss barrier.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: _left ?? 0,
            top: _top ?? 0,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: _ready ? 1 : 0),
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOutCubic,
              builder: (_, v, child) => Opacity(
                opacity: v,
                child: Transform.scale(
                  scale: 0.88 + 0.12 * v,
                  alignment: widget.isMe
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: child,
                ),
              ),
              child: _buildMenu(),
            ),
          ),
        ],
      ),
    );
  }
}
