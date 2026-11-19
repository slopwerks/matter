import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_providers.dart';
import '../../features/storage/storage_service.dart';
import '../../widgets/sheets.dart';

Future<void> showStorageHelp(
  BuildContext context,
  String title,
  String message,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SingleChildScrollView(child: Text(message)),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('知道了'),
      ),
    ],
  ),
);

Future<void> cleanSelectedStorage(
  BuildContext context,
  WidgetRef ref,
  StorageSnapshot snapshot,
  StorageSelection selection, {
  VoidCallback? onStarted,
}) async {
  final files = snapshot.files
      .where((file) => selection.matches(file, snapshot.rooms))
      .toList();
  final bytes = files.fold<int>(0, (sum, file) => sum + file.bytes);
  if (files.isEmpty) return;
  final confirmed = await showNeuConfirm(
    context,
    title: '清理本地缓存',
    message:
        '预计释放 ${formatStorageBytes(bytes)}，共 ${files.length} 个文件。\n下次查看附件时会重新下载。聊天记录、密钥、草稿和已保存文件保留。',
    confirmLabel: '清理',
    danger: true,
  );
  if (!confirmed || !context.mounted) return;
  onStarted?.call();
  try {
    final result = await storageService.clean(selection);
    PaintingBinding.instance.imageCache.clear();
    ref.read(storageLastCleanupProvider.notifier).set(result);
    ref.invalidate(storageSnapshotProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '释放 ${formatStorageBytes(result.releasedBytes)} · 删除 ${result.removedFiles} 个文件'
          '${result.skippedFiles > 0 ? ' · 跳过 ${result.skippedFiles} 个使用中或已变化的文件' : ''}'
          '${result.errors.isNotEmpty ? ' · ${result.errors.length} 个文件清理失败' : ''}',
        ),
      ),
    );
    if (result.errors.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('部分文件未清理'),
          content: SingleChildScrollView(
            child: Text(result.errors.take(10).join('\n')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('清理失败：$error')));
    }
  }
}
