import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;

import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentUserProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar(
            floating: true,
            pinned: true,
            title: Text(
              '设置',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.onBackground,
                letterSpacing: -0.5,
              ),
            ),
            backgroundColor: AppColors.background,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 96,
              ),
              child: Column(
                children: [
                  // Profile card
                  AppCard(
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('个人资料功能开发中'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(
                              AppRadii.content,
                            ),
                          ),
                          child: Center(
                            child: currentUser != null
                                ? Text(
                                    currentUser.displayName[0].toUpperCase(),
                                    style: const TextStyle(
                                      color: AppColors.primary,
                                      fontSize: 24,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  )
                                : const Icon(
                                    Icons.person_rounded,
                                    color: AppColors.primary,
                                    size: 28,
                                  ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currentUser?.displayName ?? '未登录',
                                style: const TextStyle(
                                  color: AppColors.onBackground,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                currentUser != null
                                    ? currentUser.id
                                    : '点击登录你的 Matrix 账号',
                                style: const TextStyle(
                                  color: AppColors.onSurfaceVariant,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Settings groups
                  _buildGroup(
                    title: '通用',
                    items: [
                      _SettingItem(
                        icon: Icons.dark_mode_rounded,
                        iconColor: AppColors.secondary,
                        title: '主题',
                        subtitle: '深色模式',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('主题设置开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      _SettingItem(
                        icon: Icons.notifications_rounded,
                        iconColor: AppColors.warning,
                        title: '通知',
                        subtitle: '全部开启',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('通知设置开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      _SettingItem(
                        icon: Icons.language_rounded,
                        iconColor: AppColors.success,
                        title: '语言',
                        subtitle: '简体中文',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('语言设置开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildGroup(
                    title: 'Matrix',
                    items: [
                      _SettingItem(
                        icon: Icons.account_tree_rounded,
                        iconColor: AppColors.primary,
                        title: 'Homeserver',
                        subtitle: 'matrix.org',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Homeserver 设置开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      _SettingItem(
                        icon: Icons.sync_rounded,
                        iconColor: AppColors.primaryVariant,
                        title: '同步设置',
                        subtitle: 'Sliding Sync',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('同步设置开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      _SettingItem(
                        icon: Icons.security_rounded,
                        iconColor: AppColors.success,
                        title: '加密',
                        subtitle: '端到端加密已启用',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('加密设置开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildGroup(
                    title: '关于',
                    items: [
                      _SettingItem(
                        icon: Icons.info_rounded,
                        iconColor: AppColors.onSurfaceVariant,
                        title: '版本',
                        subtitle: 'Matter v0.1.0',
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Matter v0.1.0'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      _SettingItem(
                        icon: Icons.code_rounded,
                        iconColor: AppColors.onSurfaceVariant,
                        title: '开源许可',
                        subtitle: '',
                        onTap: () {
                          showLicensePage(context: context);
                        },
                      ),
                    ],
                  ),
                  if (currentUser != null) ...[
                    const SizedBox(height: 20),
                    AppCard(
                      color: AppColors.error.withValues(alpha: 0.12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      onTap: () async {
                        try {
                          await rust.logout();
                        } catch (_) {}
                        await clearPersistedSession();
                        ref.read(isLoggedInProvider.notifier).state = false;
                        ref.read(currentUserProvider.notifier).state = null;
                      },
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.logout_rounded,
                            color: AppColors.error,
                            size: 18,
                          ),
                          SizedBox(width: 8),
                          Text(
                            '退出登录',
                            style: TextStyle(
                              color: AppColors.error,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroup({required String title, required List<Widget> items}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            title,
            style: const TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: items),
        ),
      ],
    );
  }
}

class _SettingItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadii.tag),
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
