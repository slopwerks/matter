import 'package:material_ui/material_ui.dart';

import '../../theme/material_theme.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_surface.dart';

class MaterialEncryptionOverview extends StatelessWidget {
  const MaterialEncryptionOverview({
    super.key,
    required this.verified,
    required this.description,
  });

  final bool? verified;
  final String description;

  @override
  Widget build(BuildContext context) {
    final style = materialProfileCardStyle(Theme.of(context));
    return Card(
      color: style.fill,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              verified == true
                  ? Icons.verified_user_rounded
                  : Icons.shield_outlined,
              color: style.foreground,
              size: 32,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(switch (verified) {
                    true => '当前设备已验证',
                    false => '当前设备尚未验证',
                    null => '正在确认设备验证状态',
                  }, style: style.title),
                  const SizedBox(height: 6),
                  Text(description, style: style.subtitle),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MaterialEncryptionDevices extends StatelessWidget {
  const MaterialEncryptionDevices({
    super.key,
    required this.current,
    required this.others,
    required this.notices,
    required this.emptyText,
  });

  final List<Widget> current;
  final List<Widget> others;
  final List<String> notices;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = materialSettingsSectionStyle(theme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final notice in notices) ...[
          MaterialDetailCard(title: '设备信息', child: Text(notice)),
          const SizedBox(height: 16),
        ],
        if (current.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('当前设备', style: heading),
          ),
          GroupedRows(dividerIndent: 52, children: current),
          const SizedBox(height: 16),
        ],
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('其他设备', style: heading),
              if (others.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '${others.length} 台设备，确认属于你后再验证。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        if (others.isEmpty)
          MaterialDetailCard(
            title: '暂无其他设备',
            child: Text(
              current.isEmpty ? emptyText : '只有这一台设备。在其他设备登录后，会显示在这里。',
            ),
          )
        else
          GroupedRows(dividerIndent: 52, children: others),
      ],
    );
  }
}

class MaterialEncryptionDevice extends StatelessWidget {
  const MaterialEncryptionDevice({
    super.key,
    required this.name,
    required this.deviceId,
    required this.current,
    required this.verified,
    required this.hasVerification,
    required this.onDetails,
    required this.onVerify,
  });

  final String name;
  final String deviceId;
  final bool current;
  final bool? verified;
  final bool hasVerification;
  final VoidCallback? onDetails;
  final VoidCallback? onVerify;

  @override
  Widget build(BuildContext context) => NeuAction(
    label: name,
    onTap: onDetails,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(current ? Icons.phone_android_rounded : Icons.devices_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: materialListTitleStyle(Theme.of(context)),
                ),
                const SizedBox(height: 4),
                Text(
                  deviceId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (current) const Text('本机'),
              ],
            ),
          ),
          if (hasVerification)
            if (current || verified == true)
              Icon(
                verified == true
                    ? Icons.verified_rounded
                    : Icons.circle_outlined,
                semanticLabel: switch (verified) {
                  true => '已验证',
                  false => '尚未验证',
                  null => '正在确认设备验证状态',
                },
              )
            else
              NeuButton(
                accent: true,
                onPressed: onVerify,
                child: const Text('验证'),
              ),
          if (onDetails != null) const Icon(Icons.chevron_right_rounded),
        ],
      ),
    ),
  );
}

class MaterialEncryptionRecovery extends StatelessWidget {
  const MaterialEncryptionRecovery({
    super.key,
    required this.controller,
    required this.hidden,
    required this.canCreate,
    required this.onVisibilityChanged,
    required this.onRecover,
    required this.onCreate,
  });

  final TextEditingController controller;
  final bool hidden;
  final bool canCreate;
  final VoidCallback onVisibilityChanged;
  final VoidCallback? onRecover;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) => MaterialDetailCard(
    title: '加密恢复',
    description: '输入 Matrix 恢复密钥或设置恢复时使用的口令。内容只会交给本机加密存储处理。',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          obscureText: hidden,
          decoration: InputDecoration(
            labelText: '恢复密钥或恢复口令',
            suffixIcon: NeuIconButton(
              size: 36,
              icon: hidden
                  ? Icons.visibility_rounded
                  : Icons.visibility_off_rounded,
              tooltip: hidden ? '显示' : '隐藏',
              onPressed: onVisibilityChanged,
            ),
          ),
        ),
        const SizedBox(height: 16),
        NeuButton(
          accent: true,
          onPressed: onRecover,
          child: const Text('恢复加密数据'),
        ),
        if (canCreate) ...[
          const SizedBox(height: 8),
          NeuButton(onPressed: onCreate, child: const Text('新建恢复密钥')),
        ],
      ],
    ),
  );
}
