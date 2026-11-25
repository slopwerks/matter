import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
import 'sticker_catalog.dart';
import 'sticker_preview.dart';

class StickerPackPanel extends ConsumerStatefulWidget {
  final String roomId;
  final void Function(StickerItem sticker, Rect? sourceRect) onStickerSelected;
  final Future<void> Function() onPackNavigation;
  final ScrollController scrollController;
  final bool packStripAtBottom;

  const StickerPackPanel({
    super.key,
    required this.roomId,
    required this.onStickerSelected,
    required this.onPackNavigation,
    required this.scrollController,
    this.packStripAtBottom = false,
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
  int _gridColumns = 5;
  bool _isJumpingToPack = false;

  int _gridColumnsForWidth(double width) {
    if (width < 450) return 5;
    return (width / 84).floor().clamp(5, 10);
  }

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
        1 + (pack.stickers.length / _gridColumns).ceilToDouble();
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
    final itemStride = widget.packStripAtBottom
        ? desktopPickerGroupSize + desktopPickerGroupGap
        : 48.0;
    final horizontalPadding = widget.packStripAtBottom
        ? desktopPickerGroupInset
        : 10.0;
    final itemWidth = widget.packStripAtBottom ? desktopPickerGroupSize : 40.0;
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
        return StickerHoldPreviewOverlay(sticker: sticker);
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
      loading: () => Center(
        child: CircularProgressIndicator(
          color: context.neu.accent,
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
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Center(
              child: Text(
                '当前无法读取可用贴纸包',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPackStream(List<StickerPack> packs) {
    final colors = context.neu;
    if (packs.isEmpty) {
      return Center(
        child: Text(
          '当前房间没有可用贴纸包',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    return Column(
      verticalDirection: widget.packStripAtBottom
          ? VerticalDirection.up
          : VerticalDirection.down,
      children: [
        SizedBox(
          height: widget.packStripAtBottom ? desktopPickerFooterHeight : 58,
          child: NotificationListener<OverscrollIndicatorNotification>(
            onNotification: (notification) {
              notification.disallowIndicator();
              return false;
            },
            child: ListView.separated(
              controller: _packStripController,
              padding: widget.packStripAtBottom
                  ? const EdgeInsets.all(desktopPickerGroupInset)
                  : const EdgeInsets.fromLTRB(10, 10, 10, 8),
              scrollDirection: Axis.horizontal,
              itemCount: packs.length,
              separatorBuilder: (_, _) => SizedBox(
                width: widget.packStripAtBottom ? desktopPickerGroupGap : 8,
              ),
              itemBuilder: (context, index) {
                final pack = packs[index];
                return _PackThumb(
                  desktop: widget.packStripAtBottom,
                  label: pack.title,
                  sticker: pack.stickers.isEmpty ? null : pack.stickers.first,
                  fallback: pack.accent,
                  selected: index == _activePackIndex,
                  onTap: () => _jumpToPack(index),
                );
              },
            ),
          ),
        ),
        Divider(height: 1, color: colors.hairline),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = _gridColumnsForWidth(constraints.maxWidth);
              _gridColumns = columns;
              return KeyedSubtree(
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
                                          ? colors.accent
                                          : colors.textTertiary.withValues(
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
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            color: i == _activePackIndex
                                                ? colors.text
                                                : colors.textSecondary,
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
                                    final sourceRect = _globalRectFor(
                                      stickerKey,
                                    );
                                    widget.onStickerSelected(
                                      sticker,
                                      sourceRect,
                                    );
                                  },
                                  onLongPressStart: (_) =>
                                      _showHoldPreview(sticker),
                                  onLongPressMoveUpdate: (details) =>
                                      _updateHoldPreviewAt(
                                        details.globalPosition,
                                      ),
                                  onLongPressEnd: (_) => _hideHoldPreview(),
                                  onLongPressCancel: _hideHoldPreview,
                                );
                              }, childCount: packs[i].stickers.length),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 4,
                                    mainAxisSpacing: 4,
                                    childAspectRatio: 1,
                                  ),
                            ),
                          ),
                        ],
                        const SliverPadding(
                          padding: EdgeInsets.only(bottom: 10),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PackThumb extends StatelessWidget {
  final String label;
  final bool desktop;
  final StickerItem? sticker;
  final String fallback;
  final bool selected;
  final VoidCallback onTap;

  const _PackThumb({
    required this.desktop,
    required this.label,
    required this.sticker,
    required this.fallback,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    if (desktop) {
      return Semantics(
        selected: selected,
        button: true,
        child: IconButton(
          tooltip: label,
          onPressed: onTap,
          isSelected: selected,
          style: desktopPickerGroupButtonStyle(context, selected: selected),
          icon: Padding(
            padding: const EdgeInsets.all(6),
            child: sticker == null
                ? Center(child: Text(fallback))
                : RemoteStickerPreview(
                    sticker: sticker!,
                    fallback: fallback,
                    cacheDimension: 96,
                  ),
          ),
        ),
      );
    }
    return Tooltip(
      message: label,
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(NeuRadius.button),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 40,
            height: 40,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: selected ? colors.accentSoft : colors.card,
              borderRadius: BorderRadius.circular(NeuRadius.button),
              border: Border.all(
                color: selected
                    ? colors.accent.withValues(alpha: 0.5)
                    : colors.hairline,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NeuRadius.tag),
              child: sticker == null
                  ? Center(child: Text(fallback))
                  : RemoteStickerPreview(
                      sticker: sticker!,
                      fallback: fallback,
                      cacheDimension: 96,
                    ),
            ),
          ),
        ),
      ),
    );
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
    final colors = context.neu;
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onLongPressEnd: onLongPressEnd,
      onLongPressCancel: onLongPressCancel,
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(NeuRadius.button),
          border: Border.all(color: colors.hairline, width: 0.6),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AspectRatio(
            aspectRatio: sticker.aspectRatio,
            child: RemoteStickerPreview(sticker: sticker, cacheDimension: 240),
          ),
        ),
      ),
    );
  }
}
