import 'package:flutter/material.dart';

import '../../features/storage/storage_models.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/grouped_rows.dart';
import '../chat/chat_list_item.dart' show ChatListDivider;
import 'storage_section.dart';

class StorageRoomsSection extends StatefulWidget {
  const StorageRoomsSection({
    super.key,
    required this.snapshot,
    required this.onOpen,
    this.compact = false,
    this.onOpenAll,
  });
  final StorageSnapshot snapshot;
  final void Function(String key, String name) onOpen;
  final bool compact;
  final VoidCallback? onOpenAll;
  @override
  State<StorageRoomsSection> createState() => _StorageRoomsSectionState();
}

class _StorageRoomsSectionState extends State<StorageRoomsSection> {
  String _query = '';
  StorageChatType? _type;
  bool _recent = false;

  @override
  Widget build(BuildContext context) {
    final roomFiles = <String, List<StorageFile>>{};
    for (final file in widget.snapshot.files) {
      for (final owner in file.owners) {
        roomFiles.putIfAbsent(owner.key, () => []).add(file);
      }
    }
    final rows =
        roomFiles.entries
            .map((entry) {
              final room = widget.snapshot.rooms[entry.key];
              return (
                key: entry.key,
                name:
                    room?.name ??
                    entry.value.first.owners
                        .firstWhere((owner) => owner.key == entry.key)
                        .roomId,
                type: room?.type ?? StorageChatType.unknown,
                files: entry.value,
                bytes: entry.value.fold<int>(
                  0,
                  (sum, file) => sum + file.bytes,
                ),
                used: entry.value
                    .map((file) => file.lastUsed.millisecondsSinceEpoch)
                    .reduce((a, b) => a > b ? a : b),
              );
            })
            .where(
              (row) =>
                  (_type == null || row.type == _type) &&
                  row.name.toLowerCase().contains(_query.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) =>
                _recent ? b.used.compareTo(a.used) : b.bytes.compareTo(a.bytes),
          );
    Widget tile(int index) {
      final row = rows[index];
      return ListTile(
        leading: CircleAvatar(
          child: Icon(switch (row.type) {
            StorageChatType.direct => Icons.person_outline,
            StorageChatType.space => Icons.hub_outlined,
            _ => Icons.groups_outlined,
          }),
        ),
        title: Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${row.files.length} 个文件${row.files.any((file) => file.owners.length > 1) ? ' · 含共用缓存' : ''}',
        ),
        trailing: Text(formatStorageBytes(row.bytes)),
        onTap: () => widget.onOpen(row.key, row.name),
      );
    }

    if (widget.compact) {
      return StorageSection(
        title: '聊天媒体缓存',
        action: TextButton(
          onPressed: widget.onOpenAll,
          child: const Text('全部'),
        ),
        child: GroupedRows(
          children: rows.isEmpty
              ? [
                  const ListTile(
                    leading: Icon(Icons.forum_outlined),
                    title: Text('暂无已归属缓存'),
                  ),
                ]
              : [for (var i = 0; i < rows.length.clamp(0, 3); i++) tile(i)],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSearchField(
                hint: '搜索聊天',
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _type == null,
                    onSelected: (_) => setState(() => _type = null),
                  ),
                  for (final type in [
                    StorageChatType.direct,
                    StorageChatType.group,
                    StorageChatType.space,
                  ])
                    ChoiceChip(
                      label: Text(type.label),
                      selected: _type == type,
                      onSelected: (_) => setState(() => _type = type),
                    ),
                  IconButton(
                    tooltip: _recent ? '按占用大小排序' : '按最近使用排序',
                    onPressed: () => setState(() => _recent = !_recent),
                    icon: Icon(_recent ? Icons.schedule : Icons.sort),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('没有匹配的聊天'))
              : ListView.separated(
                  itemCount: rows.length,
                  itemBuilder: (_, index) => tile(index),
                  separatorBuilder: (_, _) => const ChatListDivider(),
                ),
        ),
      ],
    );
  }
}
