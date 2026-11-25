import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/disabled_sticker_packs_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/material_list_detail.dart';
import '../../widgets/sheets.dart';
import 'sticker_catalog.dart';
import 'sticker_preview.dart';

void openRoomStickerPacks(BuildContext context, String roomId) {
  MaterialListDetail.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => RoomStickerPacksPage(roomId: roomId),
    ),
  );
}

class RoomStickerPacksTile extends StatelessWidget {
  const RoomStickerPacksTile({super.key, required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.collections_outlined),
    title: const Text('贴纸包'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => openRoomStickerPacks(context, roomId),
  );
}

class RoomStickerPacksPage extends ConsumerStatefulWidget {
  const RoomStickerPacksPage({super.key, required this.roomId});
  final String roomId;

  @override
  ConsumerState<RoomStickerPacksPage> createState() => _RoomStickerPacksState();
}

class _RoomStickerPacksState extends ConsumerState<RoomStickerPacksPage> {
  bool _saving = false;

  Future<void> _collect(String account, Iterable<StickerPack> packs) async {
    if (_saving || ref.read(activeUserIdProvider) != account) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _saving = true);
    try {
      await rust.setStickerPacksCollected(
        accountUserId: account,
        packs: [for (final pack in packs) pack.key],
        collected: true,
      );
    } catch (error) {
      if (mounted && ref.read(activeUserIdProvider) == account) {
        neuToast(context, '收藏失败：$error');
      }
    } finally {
      if (container.read(activeUserIdProvider) == account) {
        container.invalidate(stickerPacksProvider);
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(activeUserIdProvider);
    final catalog = stickerPacksProvider(widget.roomId);
    return Scaffold(
      appBar: buildFloatingAppBar(title: const Text('贴纸包')),
      body: ref
          .watch(catalog)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => Center(
              child: TextButton(
                onPressed: () => ref.invalidate(catalog),
                child: const Text('读取贴纸包失败，重试'),
              ),
            ),
            data: (remote) {
              final packs = stickerPacksFromRemote(remote)
                  .where((pack) => ownsRoomPack(pack, roomId: widget.roomId))
                  .toList();
              if (account == null || packs.isEmpty) {
                return const Center(child: Text('暂无贴纸包'));
              }
              final missing = packs.where((pack) => !pack.collected);
              final provider = disabledStickerPacksProvider((
                account: account,
                roomId: widget.roomId,
              ));
              final hidden = ref.watch(provider).value;
              return SafeArea(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: packs.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return FilledButton.icon(
                        icon: const Icon(Icons.collections_bookmark_outlined),
                        onPressed: missing.isEmpty || _saving
                            ? null
                            : () => _collect(account, missing),
                        label: Text(missing.isEmpty ? '已全部收藏' : '收藏全部贴纸包'),
                      );
                    }
                    final pack = packs[index - 1];
                    return GroupedRows(
                      children: [
                        ListTile(
                          title: Text(pack.title),
                          subtitle: Text('${pack.stickers.length} 张贴纸'),
                          trailing: TextButton(
                            onPressed: _saving || pack.collected
                                ? null
                                : () => _collect(account, [pack]),
                            child: Text(pack.collected ? '已收藏' : '收藏'),
                          ),
                        ),
                        SizedBox(
                          height: 88,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.all(8),
                            itemCount: pack.stickers.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (_, index) {
                              final sticker = pack.stickers[index];
                              return Semantics(
                                image: true,
                                label: sticker.label,
                                child: SizedBox.square(
                                  dimension: 72,
                                  child: RemoteStickerPreview(
                                    sticker: sticker,
                                    cacheDimension: 240,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        SwitchListTile(
                          title: const Text('在本房间的贴纸面板显示'),
                          value: hidden?.contains(pack.key) != true,
                          onChanged: hidden == null
                              ? null
                              : (enabled) => ref
                                    .read(provider.notifier)
                                    .setEnabled(pack.key, enabled),
                        ),
                      ],
                    );
                  },
                ),
              );
            },
          ),
    );
  }
}
