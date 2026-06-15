import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'emoji_picker_panel.dart';
import 'sticker_catalog.dart';

enum ComposerPickerTab { emoji, sticker }

class ComposerPickerPanel extends StatelessWidget {
  final String roomId;
  final ComposerPickerTab tab;
  final ValueChanged<ComposerPickerTab> onTabChanged;
  final ValueChanged<String> onEmojiSelected;
  final ValueChanged<StickerItem> onStickerSelected;

  const ComposerPickerPanel({
    super.key,
    required this.roomId,
    required this.tab,
    required this.onTabChanged,
    required this.onEmojiSelected,
    required this.onStickerSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 316,
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
                  selected: tab == ComposerPickerTab.emoji,
                  onTap: () => onTabChanged(ComposerPickerTab.emoji),
                ),
                const SizedBox(width: 8),
                _PickerTabChip(
                  label: '贴纸',
                  selected: tab == ComposerPickerTab.sticker,
                  onTap: () => onTabChanged(ComposerPickerTab.sticker),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.surfaceVariant),
          Expanded(
            child: switch (tab) {
              ComposerPickerTab.emoji => EmojiPickerPanel(
                onEmojiSelected: onEmojiSelected,
              ),
              ComposerPickerTab.sticker => StickerPackPanel(
                roomId: roomId,
                onStickerSelected: onStickerSelected,
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
  final ValueChanged<StickerItem> onStickerSelected;

  const StickerPackPanel({
    super.key,
    required this.roomId,
    required this.onStickerSelected,
  });

  @override
  ConsumerState<StickerPackPanel> createState() => _StickerPackPanelState();
}

class _StickerPackPanelState extends ConsumerState<StickerPackPanel> {
  int _packIndex = 0;

  @override
  Widget build(BuildContext context) {
    final packsAsync = ref.watch(stickerPacksProvider(widget.roomId));

    return packsAsync.when(
      data: (remotePacks) {
        final packs = stickerPacksFromRemote(remotePacks);
        return _buildPackList(packs);
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

  Widget _buildPackList(List<StickerPack> packs) {
    if (_packIndex >= packs.length && packs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _packIndex = 0);
      });
    }
    if (packs.isEmpty) {
      return const Center(
        child: Text(
          '当前房间没有可用贴纸包',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 13),
        ),
      );
    }

    final pack = packs[_packIndex.clamp(0, packs.length - 1)];
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.12,
            ),
            itemCount: pack.stickers.length,
            itemBuilder: (context, index) {
              final sticker = pack.stickers[index];
              return _StickerCard(
                sticker: sticker,
                onTap: () => widget.onStickerSelected(sticker),
                onLongPress: () => _showStickerPreview(context, sticker),
              );
            },
          ),
        ),
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: AppColors.surfaceVariant, width: 0.5),
            ),
          ),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: packs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final current = packs[index];
              final selected = index == _packIndex;
              return InkWell(
                borderRadius: BorderRadius.circular(AppRadii.button),
                onTap: () => setState(() => _packIndex = index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.primary.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadii.button),
                    border: Border.all(
                      color: selected
                          ? AppColors.primary.withValues(alpha: 0.45)
                          : AppColors.surfaceVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (current.avatarUrl != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: AppAvatar(
                            fallback: current.title,
                            size: 26,
                            radius: AppRadii.button,
                            url: current.avatarUrl,
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            current.accent,
                            style: TextStyle(
                              color: selected
                                  ? AppColors.primary
                                  : AppColors.onSurfaceVariant,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            current.title,
                            style: TextStyle(
                              color: selected
                                  ? AppColors.onBackground
                                  : AppColors.onSurface,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            switch (current.source) {
                              'room' => '房间包',
                              'user' => '我的包',
                              _ => '内置包',
                            },
                            style: TextStyle(
                              color: selected
                                  ? AppColors.primary.withValues(alpha: 0.9)
                                  : AppColors.onSurfaceVariant,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showStickerPreview(BuildContext context, StickerItem sticker) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: AspectRatio(
                aspectRatio: sticker.aspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                  child: sticker.isRemote
                      ? _RemoteStickerPreview(
                          sticker: sticker,
                          fit: BoxFit.contain,
                        )
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: sticker.colors,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              sticker.glyph ?? sticker.body,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 72,
                                fontWeight: FontWeight.w700,
                                height: 1.0,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              sticker.label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StickerCard extends StatelessWidget {
  final StickerItem sticker;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _StickerCard({
    required this.sticker,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.button),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Ink(
        decoration: BoxDecoration(
          color: sticker.isRemote
              ? AppColors.surfaceVariant.withValues(alpha: 0.22)
              : null,
          gradient: sticker.isRemote
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: sticker.colors,
                ),
          borderRadius: BorderRadius.circular(AppRadii.button),
          border: Border.all(
            color: AppColors.surfaceVariant.withValues(alpha: 0.35),
            width: 0.6,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: sticker.aspectRatio,
                    child: sticker.isRemote
                        ? _RemoteStickerPreview(sticker: sticker)
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              sticker.glyph ?? sticker.body,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                height: 1.0,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              if (!sticker.isRemote) ...[
                const SizedBox(height: 6),
                Text(
                  sticker.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteStickerPreview extends ConsumerWidget {
  final StickerItem sticker;
  final BoxFit fit;

  const _RemoteStickerPreview({
    required this.sticker,
    this.fit = BoxFit.contain,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageUrl = sticker.thumbnailUrl ?? sticker.imageUrl;
    if (imageUrl == null) {
      return const Center(
        child: Icon(
          Icons.sticky_note_2_rounded,
          color: AppColors.onSurfaceVariant,
          size: 28,
        ),
      );
    }

    return FutureBuilder<String?>(
      future: imageUrl.startsWith('mxc://')
          ? resolveMxcUrl(ref, imageUrl)
          : Future.value(imageUrl),
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
          return const Center(
            child: Icon(
              Icons.sticky_note_2_rounded,
              color: AppColors.onSurfaceVariant,
              size: 28,
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AuthenticatedImageMessage(imageUrl: resolvedUrl, fit: fit),
        );
      },
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
                ? AppColors.primary.withValues(alpha: 0.45)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.primary : AppColors.onSurface,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
