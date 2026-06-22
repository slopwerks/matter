import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'emoji_picker_panel.dart';
import 'sticker_catalog.dart';

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
    return Container(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        border: Border.all(
          color: AppColors.surfaceVariant.withValues(alpha: 0.65),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                _PickerTabChip(
                  label: 'Emoji',
                  selected: widget.tab == ComposerPickerTab.emoji,
                  onTap: () => widget.onTabChanged(ComposerPickerTab.emoji),
                ),
                const SizedBox(width: 8),
                _PickerTabChip(
                  label: '贴纸',
                  selected: widget.tab == ComposerPickerTab.sticker,
                  onTap: () => widget.onTabChanged(ComposerPickerTab.sticker),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.surfaceVariant),
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

class StickerPackPanel extends ConsumerStatefulWidget {
  final String roomId;
  final void Function(StickerItem sticker, Rect? sourceRect) onStickerSelected;
  final Future<void> Function() onPackNavigation;
  final ScrollController scrollController;

  const StickerPackPanel({
    super.key,
    required this.roomId,
    required this.onStickerSelected,
    required this.onPackNavigation,
    required this.scrollController,
  });

  @override
  ConsumerState<StickerPackPanel> createState() => _StickerPackPanelState();
}

class _StickerPackPanelState extends ConsumerState<StickerPackPanel> {
  final GlobalKey _scrollViewportKey = GlobalKey();
  final ScrollController _packStripController = ScrollController();
  final List<GlobalKey> _headerKeys = [];
  final Map<String, GlobalKey> _stickerKeys = {};
  final Map<String, StickerItem> _visibleStickers = {};
  int _activePackIndex = 0;
  bool _isJumpingToPack = false;
  int _jumpGeneration = 0;
  List<StickerPack> _packs = const [];
  OverlayEntry? _holdPreviewOverlay;
  StickerItem? _holdPreviewSticker;

  void _syncPackKeys(int count) {
    while (_headerKeys.length < count) {
      _headerKeys.add(GlobalKey());
    }
    while (_headerKeys.length > count) {
      _headerKeys.removeLast();
    }
  }

  GlobalKey _stickerKeyFor(StickerItem sticker) {
    return _stickerKeys.putIfAbsent(sticker.id, GlobalKey.new);
  }

  void _syncVisibleStickers(List<StickerPack> packs) {
    _visibleStickers
      ..clear()
      ..addEntries(
        packs.expand(
          (pack) =>
              pack.stickers.map((sticker) => MapEntry(sticker.id, sticker)),
        ),
      );
  }

  Future<void> _jumpToPack(int index) async {
    if (index < 0 || index >= _packs.length) return;
    final generation = ++_jumpGeneration;
    _setActivePack(index, revealThumbnail: false);
    _isJumpingToPack = true;
    try {
      await widget.onPackNavigation();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _jumpGeneration) return;
      if (!widget.scrollController.hasClients) return;
      var targetOffset = _offsetForBuiltHeader(index);
      targetOffset ??= _estimatedPackOffset(index);
      await widget.scrollController.animateTo(
        targetOffset.clamp(
          widget.scrollController.position.minScrollExtent,
          widget.scrollController.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );

      // A distant lazy sliver may only exist after the approximate jump.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _jumpGeneration) return;
      final correctedOffset = _offsetForBuiltHeader(index);
      if (correctedOffset != null &&
          (correctedOffset - widget.scrollController.offset).abs() > 1) {
        await widget.scrollController.animateTo(
          correctedOffset.clamp(
            widget.scrollController.position.minScrollExtent,
            widget.scrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
        );
      }
    } catch (error) {
      debugPrint('Jump to sticker pack failed: $error');
    } finally {
      if (mounted && generation == _jumpGeneration) {
        _isJumpingToPack = false;
        _updateActivePackByViewport();
      }
    }
  }

  double? _offsetForBuiltHeader(int index) {
    if (!widget.scrollController.hasClients) return null;
    final viewportBox =
        _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    final headerBox =
        _headerKeys[index].currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null ||
        !viewportBox.hasSize ||
        headerBox == null ||
        !headerBox.hasSize) {
      return null;
    }
    final top = headerBox.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
    return widget.scrollController.offset + top - 8;
  }

  double _estimatedPackOffset(int index) {
    if (!widget.scrollController.hasClients || _packs.length <= 1) return 0;
    double packWeight(StickerPack pack) =>
        1 + (pack.stickers.length / 5).ceilToDouble();
    final before = _packs.take(index).fold<double>(0, (sum, pack) {
      return sum + packWeight(pack);
    });
    final total = _packs.fold<double>(0, (sum, pack) {
      return sum + packWeight(pack);
    });
    return widget.scrollController.position.maxScrollExtent * before / total;
  }

  void _setActivePack(int index, {bool revealThumbnail = true}) {
    if (index == _activePackIndex) return;
    setState(() => _activePackIndex = index);
    if (revealThumbnail) {
      unawaited(_revealPackThumbnail(index));
    }
  }

  Future<void> _revealPackThumbnail(int index) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_packStripController.hasClients) return;
    const itemStride = 48.0;
    const horizontalPadding = 10.0;
    const itemWidth = 40.0;
    final position = _packStripController.position;
    final itemStart = horizontalPadding + index * itemStride;
    final itemEnd = itemStart + itemWidth;
    var target = position.pixels;
    if (itemStart < position.pixels + horizontalPadding) {
      target = itemStart - horizontalPadding;
    } else if (itemEnd > position.pixels + position.viewportDimension) {
      target = itemEnd - position.viewportDimension + horizontalPadding;
    } else {
      return;
    }
    await _packStripController.animateTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  void _updateActivePackByViewport() {
    if (_isJumpingToPack) return;
    final viewportBox =
        _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;

    const activationLine = 20.0;
    int bestIndex = 0;
    double bestTop = double.negativeInfinity;
    double nextPositiveTop = double.infinity;

    for (var i = 0; i < _headerKeys.length; i++) {
      final context = _headerKeys[i].currentContext;
      final box = context?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;

      final top = box.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
      if (top <= activationLine && top >= bestTop) {
        bestTop = top;
        bestIndex = i;
      } else if (bestTop == double.negativeInfinity && top < nextPositiveTop) {
        nextPositiveTop = top;
        bestIndex = i;
      }
    }

    if (bestIndex != _activePackIndex && mounted) {
      _setActivePack(bestIndex);
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateActivePackByViewport();
      });
    }
    return false;
  }

  void _showHoldPreview(StickerItem sticker) {
    _holdPreviewSticker = sticker;
    final overlay = Overlay.of(context);
    _holdPreviewOverlay ??= OverlayEntry(
      builder: (context) {
        final sticker = _holdPreviewSticker;
        if (sticker == null) return const SizedBox.shrink();
        return _StickerHoldPreviewOverlay(sticker: sticker);
      },
    );
    if (!_holdPreviewOverlay!.mounted) {
      overlay.insert(_holdPreviewOverlay!);
    } else {
      _holdPreviewOverlay!.markNeedsBuild();
    }
  }

  void _updateHoldPreviewAt(Offset globalPosition) {
    final sticker = _stickerAt(globalPosition);
    if (sticker == null || sticker.id == _holdPreviewSticker?.id) return;
    _holdPreviewSticker = sticker;
    _holdPreviewOverlay?.markNeedsBuild();
  }

  StickerItem? _stickerAt(Offset globalPosition) {
    for (final entry in _stickerKeys.entries) {
      final context = entry.value.currentContext;
      final box = context?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final topLeft = box.localToGlobal(Offset.zero);
      if ((topLeft & box.size).contains(globalPosition)) {
        return _visibleStickerById(entry.key);
      }
    }
    return null;
  }

  StickerItem? _visibleStickerById(String id) {
    return _visibleStickers[id];
  }

  Rect? _globalRectFor(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _hideHoldPreview() {
    _holdPreviewSticker = null;
    _holdPreviewOverlay?.remove();
    _holdPreviewOverlay = null;
  }

  @override
  void dispose() {
    _hideHoldPreview();
    _packStripController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final packsAsync = ref.watch(stickerPacksProvider(widget.roomId));

    return packsAsync.when(
      data: (remotePacks) {
        final packs = stickerPacksFromRemote(remotePacks);
        _packs = packs;
        _syncPackKeys(packs.length);
        _syncVisibleStickers(packs);
        return _buildPackStream(packs);
      },
      loading: () => const Center(
        child: CircularProgressIndicator(
          color: AppColors.primary,
          strokeWidth: 2,
        ),
      ),
      error: (error, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Text(
              '加载贴纸包失败',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          const Expanded(
            child: Center(
              child: Text(
                '当前无法读取可用贴纸包',
                style: TextStyle(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPackStream(List<StickerPack> packs) {
    if (packs.isEmpty) {
      return const Center(
        child: Text(
          '当前房间没有可用贴纸包',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 13),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 58,
          child: NotificationListener<OverscrollIndicatorNotification>(
            onNotification: (notification) {
              notification.disallowIndicator();
              return false;
            },
            child: ListView.separated(
              controller: _packStripController,
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              scrollDirection: Axis.horizontal,
              itemCount: packs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final pack = packs[index];
                return _PackThumb(
                  sticker: pack.stickers.first,
                  fallback: pack.accent,
                  selected: index == _activePackIndex,
                  onTap: () => _jumpToPack(index),
                );
              },
            ),
          ),
        ),
        const Divider(height: 1, color: AppColors.surfaceVariant),
        Expanded(
          child: KeyedSubtree(
            key: _scrollViewportKey,
            child: NotificationListener<OverscrollIndicatorNotification>(
              onNotification: (notification) {
                notification.disallowIndicator();
                return false;
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: _handleScrollNotification,
                child: CustomScrollView(
                  controller: widget.scrollController,
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    const SliverPadding(padding: EdgeInsets.only(top: 8)),
                    for (var i = 0; i < packs.length; i++) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          key: _headerKeys[i],
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          child: Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: i == _activePackIndex
                                      ? AppColors.primary
                                      : AppColors.onSurfaceVariant.withValues(
                                          alpha: 0.65,
                                        ),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  packs[i].title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: i == _activePackIndex
                                        ? AppColors.onBackground
                                        : AppColors.onSurface,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        sliver: SliverGrid(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final sticker = packs[i].stickers[index];
                            final stickerKey = _stickerKeyFor(sticker);
                            return _StickerCard(
                              key: stickerKey,
                              sticker: sticker,
                              onTap: () {
                                _hideHoldPreview();
                                final sourceRect = _globalRectFor(stickerKey);
                                widget.onStickerSelected(sticker, sourceRect);
                              },
                              onLongPressStart: (_) =>
                                  _showHoldPreview(sticker),
                              onLongPressMoveUpdate: (details) =>
                                  _updateHoldPreviewAt(details.globalPosition),
                              onLongPressEnd: (_) => _hideHoldPreview(),
                              onLongPressCancel: _hideHoldPreview,
                            );
                          }, childCount: packs[i].stickers.length),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 5,
                                crossAxisSpacing: 4,
                                mainAxisSpacing: 4,
                                childAspectRatio: 1,
                              ),
                        ),
                      ),
                    ],
                    const SliverPadding(padding: EdgeInsets.only(bottom: 10)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PackThumb extends StatelessWidget {
  final StickerItem sticker;
  final String fallback;
  final bool selected;
  final VoidCallback onTap;

  const _PackThumb({
    required this.sticker,
    required this.fallback,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 40,
        height: 40,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.16)
              : AppColors.surfaceVariant.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.5)
                : AppColors.surfaceVariant.withValues(alpha: 0.45),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: _RemoteStickerPreview(sticker: sticker, fallback: fallback),
        ),
      ),
    );
  }
}

class StickerFlightPreview extends StatelessWidget {
  final StickerItem sticker;

  const StickerFlightPreview({super.key, required this.sticker});

  @override
  Widget build(BuildContext context) {
    return _RemoteStickerPreview(sticker: sticker, fallback: '');
  }
}

class _StickerCard extends StatelessWidget {
  final StickerItem sticker;
  final VoidCallback onTap;
  final GestureLongPressStartCallback onLongPressStart;
  final GestureLongPressMoveUpdateCallback onLongPressMoveUpdate;
  final GestureLongPressEndCallback onLongPressEnd;
  final VoidCallback onLongPressCancel;

  const _StickerCard({
    super.key,
    required this.sticker,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressMoveUpdate,
    required this.onLongPressEnd,
    required this.onLongPressCancel,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onLongPressEnd: onLongPressEnd,
      onLongPressCancel: onLongPressCancel,
      behavior: HitTestBehavior.opaque,
      child: Ink(
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.surfaceVariant.withValues(alpha: 0.35),
            width: 0.6,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AspectRatio(
            aspectRatio: sticker.aspectRatio,
            child: _RemoteStickerPreview(sticker: sticker),
          ),
        ),
      ),
    );
  }
}

class _StickerHoldPreviewOverlay extends StatelessWidget {
  final StickerItem sticker;

  const _StickerHoldPreviewOverlay({required this.sticker});

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final previewMaxSide = math.min(screenSize.width * 0.62, 260.0);

    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                ),
              ),
            ),
            Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 90),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeOut,
                child: Column(
                  key: ValueKey(sticker.id),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      constraints: BoxConstraints(
                        maxWidth: previewMaxSide,
                        maxHeight: previewMaxSide,
                      ),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(AppRadii.surface),
                        border: Border.all(
                          color: AppColors.surfaceVariant.withValues(
                            alpha: 0.65,
                          ),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.28),
                            blurRadius: 28,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: AspectRatio(
                        aspectRatio: sticker.aspectRatio,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: _RemoteStickerPreview(
                            sticker: sticker,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.42),
                        borderRadius: BorderRadius.circular(AppRadii.button),
                      ),
                      child: Text(
                        sticker.label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteStickerPreview extends ConsumerStatefulWidget {
  final StickerItem sticker;
  final BoxFit fit;
  final String? fallback;

  const _RemoteStickerPreview({
    required this.sticker,
    this.fit = BoxFit.contain,
    this.fallback,
  });

  @override
  ConsumerState<_RemoteStickerPreview> createState() =>
      _RemoteStickerPreviewState();
}

class _RemoteStickerPreviewState extends ConsumerState<_RemoteStickerPreview> {
  String? _sourceUrl;
  Future<String?>? _resolvedFuture;

  @override
  void initState() {
    super.initState();
    _syncFuture();
  }

  @override
  void didUpdateWidget(covariant _RemoteStickerPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sticker.thumbnailUrl != oldWidget.sticker.thumbnailUrl ||
        widget.sticker.imageUrl != oldWidget.sticker.imageUrl) {
      _syncFuture();
    }
  }

  void _syncFuture() {
    final nextSourceUrl =
        widget.sticker.thumbnailUrl ?? widget.sticker.imageUrl;
    if (_sourceUrl == nextSourceUrl && _resolvedFuture != null) return;
    _sourceUrl = nextSourceUrl;
    _resolvedFuture = nextSourceUrl == null
        ? Future<String?>.value(null)
        : nextSourceUrl.startsWith('mxc://')
        ? resolveMxcUrl(ref, nextSourceUrl)
        : Future<String?>.value(nextSourceUrl);
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = _sourceUrl;
    if (imageUrl == null) {
      return _StickerFallback(label: widget.fallback);
    }

    return FutureBuilder<String?>(
      future: _resolvedFuture,
      builder: (context, snapshot) {
        final resolvedUrl = snapshot.data;
        if (resolvedUrl == null) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  color: AppColors.primary,
                  strokeWidth: 2,
                ),
              ),
            );
          }
          return _StickerFallback(label: widget.fallback);
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AuthenticatedImageMessage(
            imageUrl: resolvedUrl,
            fit: widget.fit,
          ),
        );
      },
    );
  }
}

class _StickerFallback extends StatelessWidget {
  final String? label;

  const _StickerFallback({this.label});

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    if (label != null && label.isNotEmpty) {
      return Center(
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.onSurfaceVariant,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return const Center(
      child: Icon(
        Icons.sticky_note_2_rounded,
        color: AppColors.onSurfaceVariant,
        size: 28,
      ),
    );
  }
}

class _PickerTabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PickerTabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.button),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.16)
              : AppColors.surfaceVariant.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(AppRadii.button),
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.4)
                : AppColors.surfaceVariant.withValues(alpha: 0.35),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.primary : AppColors.onSurfaceVariant,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
