import 'package:material_ui/material_ui.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../widgets/material_detail_card.dart';

/// Device presentation only; the encryption page owns account and write guards.
class MaterialDeviceDetailsSheet extends StatelessWidget {
  const MaterialDeviceDetailsSheet({
    super.key,
    required this.device,
    required this.lastSeen,
    required this.onRename,
    required this.onVerify,
  });

  final rust.AccountDevice device;
  final String lastSeen;
  final VoidCallback onRename;
  final VoidCallback? onVerify;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final name = device.displayName?.trim().isNotEmpty == true
        ? device.displayName!
        : '未命名设备';
    final fields = [
      ('Device ID', device.deviceId),
      ('IP 地址', device.lastSeenIp ?? '未知'),
      ('上次活动', lastSeen),
      if (device.isCurrent) ('状态', '当前设备'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(name, style: textTheme.headlineSmall)),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 16),
          MaterialDetailCard(
            title: '设备信息',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < fields.length; index++) ...[
                  if (index > 0) const SizedBox(height: 16),
                  Text(fields[index].$1, style: textTheme.labelMedium),
                  const SizedBox(height: 4),
                  SelectableText(fields[index].$2, style: textTheme.bodyMedium),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          MaterialDetailCard(
            title: '设备操作',
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('重命名'),
                  onTap: onRename,
                ),
                if (!device.isCurrent) ...[
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.shield_outlined),
                    title: const Text('验证'),
                    onTap: onVerify,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
