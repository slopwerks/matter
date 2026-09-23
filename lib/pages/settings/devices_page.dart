import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

/// 账号设备会话管理:服务器侧设备列表、活动详情与重命名。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<rust.AccountDevice> _devices = [];
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final devices = await rust.listAccountDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  String _deviceLabel(rust.AccountDevice device) {
    final name = device.displayName?.trim() ?? '';
    return name.isEmpty ? '未命名设备' : name;
  }

  String _formatLastSeen(rust.AccountDevice device) {
    final timestamp = device.lastSeenTs;
    if (timestamp == null) return '无活动记录';
    final time = DateTime.fromMillisecondsSinceEpoch(
      timestamp.toInt(),
    ).toLocal();
    return DateFormat('yyyy-MM-dd HH:mm').format(time);
  }

  Future<void> _rename(rust.AccountDevice device) async {
    if (_busy) return;
    final name = await showNeuPrompt(
      context,
      title: '重命名设备',
      message: '该名称会显示在账号的设备列表中。',
      hint: '设备名称',
      initial: device.displayName ?? '',
      confirmLabel: '保存',
    );
    if (name == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await rust.renameAccountDevice(
        deviceId: device.deviceId,
        displayName: name,
      );
      await _load();
      if (mounted) neuToast(context, '设备名称已更新');
    } catch (error) {
      if (mounted) neuToast(context, '重命名失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDetails(rust.AccountDevice device) async {
    await showNeuSheet<void>(
      context: context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text(
              _deviceLabel(device),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          _DetailRow(label: 'Device ID', value: device.deviceId),
          _DetailRow(label: 'IP 地址', value: device.lastSeenIp ?? '未知'),
          _DetailRow(label: '上次活动', value: _formatLastSeen(device)),
          if (device.isCurrent) const _DetailRow(label: '状态', value: '当前设备'),
          const SizedBox(height: 4),
          NeuSheetItem(
            icon: Icons.edit_rounded,
            label: '重命名',
            onTap: () async {
              Navigator.of(context).pop();
              await _rename(device);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
    return Scaffold(
      backgroundColor: colors.base,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    edgeOffset: viewPaddingTop + kToolbarHeight,
                    child: MaxContentWidth(
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          NeuSpacing.lg,
                          viewPaddingTop + kToolbarHeight + NeuSpacing.sm,
                          NeuSpacing.lg,
                          32,
                        ),
                        children: _buildBody(),
                      ),
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: viewPaddingTop + kToolbarHeight,
            child: const TopFadeBlur(useShader: true),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: kToolbarHeight,
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: NeuSpacing.sm,
                    right: NeuSpacing.md,
                  ),
                  child: Row(
                    children: [
                      NeuIconButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        size: 40,
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: NeuSpacing.sm),
                      Expanded(
                        child: Text(
                          '设备与会话',
                          style: Theme.of(context).textTheme.titleLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBody() {
    final error = _error;
    if (error != null && _devices.isEmpty) {
      return [
        NeuSurface(
          color: context.neu.card,
          radius: NeuRadius.content,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('设备列表加载失败', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(error, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              NeuButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                onPressed: _load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ];
    }
    if (_devices.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Center(
            child: Text(
              '暂无登录设备',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      ];
    }
    return [
      for (var index = 0; index < _devices.length; index++) ...[
        if (index > 0) const SizedBox(height: NeuSpacing.md),
        _buildDevice(_devices[index]),
      ],
    ];
  }

  Widget _buildDevice(rust.AccountDevice device) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: () => _openDetails(device),
      child: NeuSurface(
        color: colors.card,
        radius: NeuRadius.content,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              device.isCurrent
                  ? Icons.phone_android_rounded
                  : Icons.devices_rounded,
              size: 22,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _deviceLabel(device),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall,
                        ),
                      ),
                      if (device.isCurrent) ...[
                        const SizedBox(width: 8),
                        NeuSurface(
                          depth: NeuDepth.flat,
                          color: colors.accentSoft,
                          radius: NeuRadius.tag,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            '本机',
                            style: textTheme.labelSmall?.copyWith(
                              color: colors.accent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    device.deviceId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: colors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹层里的「标签 + 值」明细行。
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(child: Text(value, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
