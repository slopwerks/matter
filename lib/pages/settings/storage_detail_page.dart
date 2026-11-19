import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_providers.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/max_content_width.dart';
import '../chat/chat_list_item.dart' show ChatListDivider;
import 'storage_actions.dart';
import 'storage_media_preview.dart';

class StorageDetailPage extends ConsumerStatefulWidget {
  const StorageDetailPage({
    super.key,
    required this.title,
    this.kind,
    this.room,
    this.chatType,
    this.shared = false,
    this.unassigned = false,
    this.applicationData = false,
    this.cleanableOnly = false,
    this.crossTypeShared = false,
  });
  final String title;
  final StorageKind? kind;
  final String? room;
  final StorageChatType? chatType;
  final bool shared;
  final bool unassigned;
  final bool applicationData;
  final bool cleanableOnly;
  final bool crossTypeShared;
  @override
  ConsumerState<StorageDetailPage> createState() => _StorageDetailPageState();
}

class _StorageDetailPageState extends ConsumerState<StorageDetailPage> {
  final _selected = <String>{};
  String _query = '';
  bool _newest = false;
  bool _cleaning = false;

  bool _matches(StorageFile file, StorageSnapshot snapshot) {
    if (widget.kind != null && file.kind != widget.kind) return false;
    if (widget.room != null &&
        !file.owners.any((owner) => owner.key == widget.room)) {
      return false;
    }
    if (widget.shared && file.owners.length < 2) return false;
    if (widget.applicationData && !file.applicationData) return false;
    if (widget.unassigned && (file.owners.isNotEmpty || file.applicationData)) {
      return false;
    }
    if (widget.chatType != null && file.applicationData) return false;
    if (widget.cleanableOnly && !file.cleanable) return false;
    final types = file.owners.isEmpty
        ? {StorageChatType.unknown}
        : file.owners
              .map(
                (owner) =>
                    snapshot.rooms[owner.key]?.type ?? StorageChatType.unknown,
              )
              .toSet();
    if (widget.crossTypeShared && types.length < 2) return false;
    if (widget.chatType != null &&
        !types.every((type) => type == widget.chatType)) {
      return false;
    }
    final text =
        '${file.name} ${file.path} ${file.owners.map((owner) => snapshot.rooms[owner.key]?.name ?? owner.roomId).join(' ')}';
    return text.toLowerCase().contains(_query.toLowerCase());
  }

  bool _canClean(StorageFile file) =>
      file.cleanable &&
      !file.busy &&
      (widget.room == null || file.owners.length == 1);
  void _toggle(StorageFile file, bool value) => setState(() {
    if (value) {
      _selected.add(file.path);
    } else {
      _selected.remove(file.path);
    }
  });
  Future<void> _clean(StorageSnapshot snapshot) async {
    try {
      await cleanSelectedStorage(
        context,
        ref,
        snapshot,
        StorageSelection(paths: Set.of(_selected)),
        onStarted: () => setState(() => _cleaning = true),
      );
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  void _preview(StorageFile file) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => StorageMediaPreviewPage(file: file),
    ),
  );
  void _details(StorageFile file, StorageSnapshot snapshot) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(file.name),
      content: SingleChildScrollView(
        child: SelectableText(
          '${file.kind.label} · ${formatStorageBytes(file.bytes)}\n${file.busy
              ? '正在使用'
              : file.cleanable
              ? '可清理缓存'
              : '保留数据'}\n\n最近使用：${file.lastUsed.toLocal()}${file.usageEstimated ? '（估计）' : ''}\n\n${file.owners.isEmpty ? (file.applicationData ? '公共应用数据' : '未识别的历史媒体或公共媒体') : file.owners.map((owner) => snapshot.rooms[owner.key]?.name ?? owner.roomId).join('\n')}\n\n${file.path}',
        ),
      ),
      actions: [
        if (canPreviewStorageFile(file))
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _preview(file);
            },
            child: const Text('预览'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _fileRow(StorageFile file, StorageSnapshot snapshot) {
    final status = file.busy
        ? '使用中'
        : !file.cleanable
        ? '保留数据'
        : file.owners.length > 1
        ? '${file.owners.length} 个聊天共用'
        : null;
    return ListTile(
      leading: Semantics(
        button: canPreviewStorageFile(file),
        label: canPreviewStorageFile(file)
            ? '预览 ${file.name}'
            : file.kind.label,
        child: InkWell(
          onTap: () => canPreviewStorageFile(file)
              ? _preview(file)
              : _details(file, snapshot),
          child: SizedBox.square(
            dimension: 56,
            child: StorageMediaThumbnail(key: ValueKey(file.path), file: file),
          ),
        ),
      ),
      title: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${formatStorageBytes(file.bytes)}${status == null ? '' : ' · $status'}',
      ),
      trailing: Checkbox(
        value: _selected.contains(file.path),
        onChanged: _cleaning || !_canClean(file)
            ? null
            : (value) => _toggle(file, value == true),
      ),
      onTap: () => _details(file, snapshot),
    );
  }

  Widget _body(StorageSnapshot snapshot) {
    final files =
        snapshot.files.where((file) => _matches(file, snapshot)).toList()..sort(
          (a, b) => _newest
              ? b.lastUsed.compareTo(a.lastUsed)
              : b.bytes.compareTo(a.bytes),
        );
    _selected.retainAll(
      snapshot.files.where(_canClean).map((file) => file.path),
    );
    final selectedBytes = snapshot.files
        .where((file) => _selected.contains(file.path))
        .fold<int>(0, (sum, file) => sum + file.bytes);
    final paths = files.where(_canClean).map((file) => file.path).toSet();
    final allSelected = paths.isNotEmpty && _selected.containsAll(paths);
    final hiddenCount = _selected
        .difference(files.map((file) => file.path).toSet())
        .length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSearchField(
                hint: '搜索文件',
                onChanged: (text) => setState(() => _query = text),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${files.length} 项 · ${formatStorageBytes(files.fold<int>(0, (sum, file) => sum + file.bytes))}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: _newest ? '按大小排序' : '按最近使用排序',
                    icon: Icon(_newest ? Icons.schedule : Icons.sort),
                    onPressed: () => setState(() => _newest = !_newest),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '选择操作',
                    enabled: !_cleaning,
                    onSelected: (action) => setState(() {
                      if (action == 'clear') {
                        _selected.clear();
                      } else if (allSelected) {
                        _selected.removeAll(paths);
                      } else {
                        _selected.addAll(paths);
                      }
                    }),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'all',
                        enabled: paths.isNotEmpty,
                        child: Text(allSelected ? '取消当前' : '全选当前'),
                      ),
                      PopupMenuItem(
                        value: 'clear',
                        enabled: _selected.isNotEmpty,
                        child: const Text('清除选择'),
                      ),
                    ],
                  ),
                ],
              ),
              if (hiddenCount > 0)
                Text(
                  '另有 $hiddenCount 项已选',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        Expanded(
          child: files.isEmpty
              ? const Center(child: Text('没有匹配的文件'))
              : ListView.separated(
                  itemCount: files.length,
                  itemBuilder: (context, index) =>
                      _fileRow(files[index], snapshot),
                  separatorBuilder: (_, _) => const ChatListDivider(indent: 80),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _cleaning || _selected.isEmpty
                    ? null
                    : () => _clean(snapshot),
                icon: _cleaning
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cleaning_services_outlined),
                label: Text(
                  _selected.isEmpty
                      ? '选择要清理的文件'
                      : '清理已选 ${_selected.length} 项 · ${formatStorageBytes(selectedBytes)}',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.neu.base,
    appBar: buildFloatingAppBar(
      title: Text(widget.title),
      actions: [
        IconButton(
          tooltip: '清理说明',
          onPressed: () => showStorageHelp(
            context,
            '清理说明',
            '仅删除本地缓存，附件可重新下载。\n聊天记录、密钥、草稿和已保存文件保留。\n共用文件请在“共用缓存”中清理。',
          ),
          icon: const Icon(Icons.info_outline),
        ),
        IconButton(
          tooltip: '刷新列表',
          onPressed: () => ref.invalidate(storageSnapshotProvider),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: MaxContentWidth(
      maxWidth: 720,
      child: ref
          .watch(storageSnapshotProvider)
          .when(
            skipLoadingOnReload: true,
            data: _body,
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
