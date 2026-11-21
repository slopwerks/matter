import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../providers/chat_visual_settings_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_surface.dart';
import 'emoji_picker_panel.dart';
import 'sticker_catalog.dart';
import 'sticker_pack_panel.dart';

export 'sticker_pack_panel.dart' show StickerPackPanel;
export 'sticker_preview.dart' show StickerFlightPreview;

enum ComposerPickerTab { emoji, sticker }

class ComposerPickerPanel extends StatefulWidget {
  static const double baseHeight = 316;

  final double? height;
  final double? maxHeight;
  final String roomId;
  final ComposerPickerTab tab;
  final ValueChanged<ComposerPickerTab> onTabChanged;
  final ValueChanged<String> onEmojiSelected;
  final void Function(StickerItem sticker, Rect? sourceRect) onStickerSelected;
  final ValueChanged<double>? onHeightChanged;

  const ComposerPickerPanel({
    super.key,
    this.height,
    this.maxHeight,
    required this.roomId,
    required this.tab,
    required this.onTabChanged,
    required this.onEmojiSelected,
    required this.onStickerSelected,
    this.onHeightChanged,
  });

  @override
  State<ComposerPickerPanel> createState() => _ComposerPickerPanelState();
}

class _ComposerPickerPanelState extends State<ComposerPickerPanel> {
  late final DraggableScrollableController _sheetController;
  late final ValueNotifier<double> _sheetExtent;

  double _maxPanelHeight(BuildContext context) {
    final baseHeight = widget.height ?? ComposerPickerPanel.baseHeight;
    if (widget.maxHeight != null) {
      return math.max(baseHeight, widget.maxHeight!);
    }
    final mediaQuery = MediaQuery.of(context);
    final screenHeight = mediaQuery.size.height;
    final safeTop = mediaQuery.padding.top;
    return math.max(baseHeight, screenHeight - safeTop - 88);
  }

  @override
  void initState() {
    super.initState();
    _sheetController = DraggableScrollableController();
    _sheetExtent = ValueNotifier<double>(0);
  }

  @override
  void dispose() {
    _sheetController.dispose();
    _sheetExtent.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ComposerPickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tab != widget.tab && widget.tab == ComposerPickerTab.emoji) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || !_sheetController.isAttached) return;
        final maxHeight = _maxPanelHeight(context);
        final baseHeight = widget.height ?? ComposerPickerPanel.baseHeight;
        await _sheetController.animateTo(
          baseHeight / maxHeight,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = _maxPanelHeight(context);
    final baseHeight = widget.height ?? ComposerPickerPanel.baseHeight;
    final minSize = baseHeight / maxHeight;
    final lockToBaseHeight =
        widget.tab == ComposerPickerTab.emoji &&
        _sheetExtent.value <= minSize + 0.001;

    if (_sheetExtent.value == 0) {
      _sheetExtent.value = minSize;
    }

    return ValueListenableBuilder<double>(
      valueListenable: _sheetExtent,
      builder: (context, currentExtent, child) {
        final visibleHeight = (currentExtent * maxHeight).clamp(
          baseHeight,
          maxHeight,
        );
        return SizedBox(height: visibleHeight, child: child);
      },
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.bottomCenter,
          minHeight: maxHeight,
          maxHeight: maxHeight,
          child: SizedBox(
            height: maxHeight,
            child: NotificationListener<DraggableScrollableNotification>(
              onNotification: _handleSheetNotification,
              child: DraggableScrollableSheet(
                controller: _sheetController,
                expand: false,
                initialChildSize: minSize,
                minChildSize: minSize,
                maxChildSize: lockToBaseHeight ? minSize : 1,
                builder: _buildSheet,
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _handleSheetNotification(DraggableScrollableNotification notification) {
    if (!mounted) return false;
    if ((_sheetExtent.value - notification.extent).abs() > 0.0005) {
      _sheetExtent.value = notification.extent;
      widget.onHeightChanged?.call(
        notification.extent * _maxPanelHeight(context),
      );
    }
    return false;
  }

  void _handleStickerSelected(StickerItem sticker, Rect? sourceRect) {
    widget.onStickerSelected(sticker, sourceRect);
    unawaited(_collapseToBaseHeight());
  }

  Future<void> _collapseToBaseHeight() async {
    if (!mounted) return;
    final maxHeight = _maxPanelHeight(context);
    final baseHeight = widget.height ?? ComposerPickerPanel.baseHeight;
    final minSize = baseHeight / maxHeight;
    if (_sheetExtent.value <= minSize + 0.001) return;

    if (_sheetController.isAttached) {
      try {
        await _sheetController.animateTo(
          minSize,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      } catch (error) {
        debugPrint('Collapse sticker panel failed: $error');
      }
    }
    if (!mounted) return;
    _sheetExtent.value = minSize;
    widget.onHeightChanged?.call(baseHeight);
  }

  Future<void> _expandForStickerPackNavigation() async {
    if (!mounted || !_sheetController.isAttached) return;
    final maxHeight = _maxPanelHeight(context);
    final baseHeight = widget.height ?? ComposerPickerPanel.baseHeight;
    final minSize = baseHeight / maxHeight;
    if (_sheetExtent.value <= minSize + 0.001) return;
    if (_sheetExtent.value >= 0.999) return;
    try {
      await _sheetController.animateTo(
        1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } catch (error) {
      debugPrint('Expand sticker panel failed: $error');
    }
  }

  Widget _buildSheet(BuildContext context, ScrollController scrollController) {
    final colors = context.neu;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: NeuDecoration(
        colors: colors,
        superellipseEnabled: ChatVisualSettingsScope.of(context)
            .superellipseBorderEnabled,
        radius: NeuRadius.surface,
        intensity: .7,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                NeuChip(
                  label: 'Emoji',
                  selected: widget.tab == ComposerPickerTab.emoji,
                  onTap: () => widget.onTabChanged(ComposerPickerTab.emoji),
                ),
                const SizedBox(width: 8),
                NeuChip(
                  label: '贴纸',
                  selected: widget.tab == ComposerPickerTab.sticker,
                  onTap: () => widget.onTabChanged(ComposerPickerTab.sticker),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.hairline),
          Expanded(
            child: switch (widget.tab) {
              ComposerPickerTab.emoji => EmojiPickerPanel(
                onEmojiSelected: widget.onEmojiSelected,
                scrollController: scrollController,
              ),
              ComposerPickerTab.sticker => StickerPackPanel(
                roomId: widget.roomId,
                onStickerSelected: _handleStickerSelected,
                onPackNavigation: _expandForStickerPackNavigation,
                scrollController: scrollController,
              ),
            },
          ),
        ],
      ),
    );
  }
}
