import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_providers.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/max_content_width.dart';
import 'storage_actions.dart';
import 'storage_detail_page.dart';
import 'storage_rooms_section.dart';

class StorageChatsPage extends ConsumerWidget {
  const StorageChatsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    backgroundColor: context.neu.base,
    appBar: buildFloatingAppBar(
      title: const Text('聊天媒体缓存'),
      actions: [
        IconButton(
          tooltip: '聊天用量说明',
          onPressed: () => showStorageHelp(
            context,
            '聊天媒体缓存',
            '按本地消息补记可确认归属的媒体。\n数据库单独统计；无法识别的历史文件与公共媒体归入“其他媒体”。\n共用文件会出现在相关聊天中，合计只计一次。',
          ),
          icon: const Icon(Icons.info_outline),
        ),
      ],
    ),
    body: MaxContentWidth(
      maxWidth: 720,
      child: ref
          .watch(storageSnapshotProvider)
          .when(
            skipLoadingOnReload: true,
            data: (snapshot) => StorageRoomsSection(
              snapshot: snapshot,
              onOpen: (key, name) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => StorageDetailPage(title: name, room: key),
                ),
              ),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: TextButton(
                onPressed: () => ref.invalidate(storageSnapshotProvider),
                child: const Text('读取失败，重试'),
              ),
            ),
          ),
    ),
  );
}
