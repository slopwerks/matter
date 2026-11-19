import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_notification_runtime.dart';

String _key(String userId) =>
    'desktop_notifications_${base64Url.encode(utf8.encode(userId))}';

final desktopNotificationsEnabledProvider = FutureProvider.family<bool, String>(
  (ref, userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key(userId)) ?? true;
  },
);

Future<void> saveDesktopNotificationsEnabled(
  String userId,
  bool enabled,
) async {
  final prefs = await SharedPreferences.getInstance();
  if (!await prefs.setBool(_key(userId), enabled)) {
    throw StateError('无法保存桌面通知设置');
  }
}

class DesktopNotificationSettingsTile extends ConsumerWidget {
  const DesktopNotificationSettingsTile({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(desktopNotificationsEnabledProvider(userId))
      .when(
        loading: () => const ListTile(title: Text('正在读取桌面通知设置')),
        error: (error, _) => ListTile(
          title: const Text('读取桌面通知设置失败'),
          subtitle: Text('$error'),
          onTap: () =>
              ref.invalidate(desktopNotificationsEnabledProvider(userId)),
        ),
        data: (enabled) => SwitchListTile.adaptive(
          title: const Text('桌面消息通知'),
          subtitle: const Text('应用运行时接收系统通知；退出后不接收。提醒范围沿用上方账号通知偏好，点击通知打开对应消息。'),
          value: enabled,
          onChanged: (value) async {
            try {
              await saveDesktopNotificationsEnabled(userId, value);
              if (!context.mounted) return;
              ref.invalidate(desktopNotificationsEnabledProvider(userId));
              if (!value) {
                await ref
                    .read(desktopNotificationRuntimeProvider)
                    .cancelAccount(userId);
              }
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('保存桌面通知设置失败：$error')));
              }
            }
          },
        ),
      );
}
