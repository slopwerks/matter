import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class DesktopFileDrop extends StatefulWidget {
  const DesktopFileDrop({
    super.key,
    required this.child,
    required this.onFiles,
    this.enabled = true,
  });
  final Widget child;
  final Future<void> Function(List<XFile>) onFiles;
  final bool enabled;

  @override
  State<DesktopFileDrop> createState() => _DesktopFileDropState();
}

class _DesktopFileDropState extends State<DesktopFileDrop> {
  bool _hovering = false;
  bool get _enabled =>
      widget.enabled && (ModalRoute.isCurrentOf(context) ?? true);

  Future<void> _drop(DropDoneDetails details) async {
    if (!_enabled) return;
    setState(() => _hovering = false);
    final accessed = <Uint8List>[];
    try {
      final files = <XFile>[];
      var folders = false;
      for (final file in details.files) {
        final bookmark = file.extraAppleBookmark;
        if (Platform.isMacOS &&
            bookmark != null &&
            await DesktopDrop.instance.startAccessingSecurityScopedResource(
              bookmark: bookmark,
            )) {
          accessed.add(bookmark);
        }
        if (file is DropItemDirectory ||
            await FileSystemEntity.type(file.path) ==
                FileSystemEntityType.directory) {
          folders = true;
        } else {
          files.add(file);
        }
      }
      if (!mounted || !_enabled) return;
      if (folders) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂不支持发送文件夹，请选择文件')));
      }
      if (files.isNotEmpty) await widget.onFiles(files);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法读取拖入的文件: $error')));
      }
    } finally {
      for (final bookmark in accessed) {
        await DesktopDrop.instance.stopAccessingSecurityScopedResource(
          bookmark: bookmark,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop =
        !kIsWeb &&
        switch (Theme.of(context).platform) {
          TargetPlatform.linux ||
          TargetPlatform.macOS ||
          TargetPlatform.windows => true,
          _ => false,
        };
    if (!desktop) return widget.child;
    final enabled = _enabled;
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) => unawaited(_drop(details)),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_hovering && enabled)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.primaryContainer
                      .withValues(alpha: .9),
                  child: const Center(child: Text('松开以预览并发送附件')),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
