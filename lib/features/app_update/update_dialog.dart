import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/neu_colors.dart';
import 'app_update_service.dart';
import 'update_exception.dart';

Future<void> showAvailableUpdateDialog(
  BuildContext context, {
  required AppUpdateService service,
  required InstalledAppVersion current,
  required ReleaseUpdate update,
}) async {
  final notesSummary = summarizeReleaseNotes(update.notes);
  final shouldDownload = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final neu = dialogContext.neu;
      final textTheme = Theme.of(dialogContext).textTheme;
      return AlertDialog(
        title: const Text('发现新版本'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'v${update.version}',
                style: textTheme.titleLarge?.copyWith(color: neu.accent),
              ),
              const SizedBox(height: 4),
              Text(
                '${current.displayName} → v${update.version} · '
                'Android arm64 · ${formatByteSize(update.assetSize)}',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Text('本次更新', style: textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                notesSummary,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () =>
                    _openReleasePage(dialogContext, update.releasePage),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 36),
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text(
                  '查看完整发布说明',
                  style: TextStyle(decoration: TextDecoration.underline),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('下载并安装'),
          ),
        ],
      );
    },
  );
  if (shouldDownload != true || !context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadUpdateDialog(service: service, update: update),
  );
}

String summarizeReleaseNotes(String notes) {
  final lines = notes
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map(
        (line) => line
            .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
            .replaceFirst(RegExp(r'^[-*+]\s+'), '• ')
            .replaceAllMapped(
              RegExp(r'\[([^\]]+)\]\([^)]+\)'),
              (match) => match.group(1)!,
            )
            .replaceAll('**', '')
            .replaceAll('__', '')
            .replaceAll('`', ''),
      )
      .toList();
  if (lines.isEmpty) return '本次发布未提供简要说明。';

  final hasMoreLines = lines.length > 3;
  var summary = lines.take(3).join('\n');
  const maximumLength = 220;
  if (summary.length > maximumLength) {
    summary = '${summary.substring(0, maximumLength - 1).trimRight()}…';
  } else if (hasMoreLines) {
    summary = '$summary\n…';
  }
  return summary;
}

Future<void> _openReleasePage(BuildContext context, Uri releasePage) async {
  try {
    final opened = await launchUrl(
      releasePage,
      mode: LaunchMode.externalApplication,
    );
    if (opened || !context.mounted) return;
  } catch (_) {
    if (!context.mounted) return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('无法打开发布说明'),
      duration: Duration(milliseconds: 1500),
    ),
  );
}

String formatByteSize(int bytes) {
  if (bytes <= 0) return '大小未知';
  final megabytes = bytes / (1024 * 1024);
  return '${megabytes.toStringAsFixed(megabytes >= 10 ? 1 : 2)} MB';
}

class _DownloadUpdateDialog extends StatefulWidget {
  final AppUpdateService service;
  final ReleaseUpdate update;

  const _DownloadUpdateDialog({required this.service, required this.update});

  @override
  State<_DownloadUpdateDialog> createState() => _DownloadUpdateDialogState();
}

class _DownloadUpdateDialogState extends State<_DownloadUpdateDialog> {
  int _received = 0;
  int _total = 0;
  String _status = '正在连接 GitHub…';
  String? _error;
  String? _downloadedPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    setState(() {
      _received = 0;
      _total = 0;
      _status = '正在连接 GitHub…';
      _error = null;
    });
    try {
      final path =
          _downloadedPath ??
          await widget.service.downloadUpdate(
            widget.update,
            onProgress: (received, total) {
              if (!mounted) return;
              setState(() {
                _received = received;
                _total = total;
                _status = '正在下载安装包…';
              });
            },
          );
      _downloadedPath = path;
      if (!mounted) return;
      setState(() => _status = '正在打开系统安装器…');
      await widget.service.installUpdate(path);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is AppUpdateException ? error.message : error.toString();
        _status = '更新失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? _received / _total : null;
    final percent = progress == null
        ? null
        : '${(progress.clamp(0.0, 1.0) * 100).round()}%';

    return PopScope(
      canPop: _error != null,
      child: AlertDialog(
        title: Text(_status),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error == null) ...[
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 12),
                Text(
                  percent == null
                      ? '请稍候'
                      : '$percent · ${formatByteSize(_received)} / ${formatByteSize(_total)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ] else
                Text(_error!),
            ],
          ),
        ),
        actions: _error == null
            ? null
            : [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(onPressed: _start, child: const Text('重试')),
              ],
      ),
    );
  }
}
