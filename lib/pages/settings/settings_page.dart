import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/app_update/app_update_service.dart';
import '../../features/app_update/update_dialog.dart';
import '../../features/diagnostics/diagnostic_exporter.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;

import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/app_card.dart';
import 'encryption_page.dart';
import 'log_viewer_page.dart';
import 'profile_edit_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  List<rust.AccountInfo> _accounts = [];
  String _versionLabel = '读取中…';
  bool _checkingForUpdate = false;
  bool _exportingDiagnostics = false;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final version = await appUpdateService.getCurrentVersion();
      if (mounted) setState(() => _versionLabel = version.displayName);
    } catch (error) {
      debugPrint('Failed to load app version: $error');
      if (mounted) setState(() => _versionLabel = '版本信息不可用');
    }
  }

  Future<void> _checkForUpdate() async {
    if (_checkingForUpdate) return;
    setState(() => _checkingForUpdate = true);
    try {
      final result = await appUpdateService.checkForUpdate(force: true);
      if (!mounted) return;
      switch (result.status) {
        case UpdateCheckStatus.available:
          await showAvailableUpdateDialog(
            context,
            service: appUpdateService,
            current: result.current,
            update: result.update!,
          );
        case UpdateCheckStatus.upToDate:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${result.current.displayName} 已是最新版本'),
              duration: const Duration(milliseconds: 1200),
            ),
          );
        case UpdateCheckStatus.unsupported:
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前平台暂不支持应用内更新')));
        case UpdateCheckStatus.skipped:
          break;
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('检查更新失败：$error')));
    } finally {
      if (mounted) setState(() => _checkingForUpdate = false);
    }
  }

  Future<void> _exportDiagnostics() async {
    if (_exportingDiagnostics) return;
    setState(() => _exportingDiagnostics = true);
    try {
      final saved = await const DiagnosticExporter().export();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '诊断报告已导出' : '已取消导出')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出诊断报告失败：$error')));
    } finally {
      if (mounted) setState(() => _exportingDiagnostics = false);
    }
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await rust.listAccounts();
      if (mounted) {
        setState(() {
          _accounts = accounts;
        });
      }
    } catch (e) {
      debugPrint('Failed to load accounts: $e');
    }
  }

  Future<void> _switchAccount(String userId) async {
    final activeId = ref.read(activeUserIdProvider);
    if (userId == activeId) return;

    var switchedClient = false;
    try {
      ref.read(sessionReadyProvider.notifier).value = false;
      final success = await rust.switchAccount(userId: userId);
      if (!success) {
        throw StateError('账号切换未生效');
      }
      switchedClient = true;
      if (mounted) {
        final sessions = await loadAllSessions();
        final session = sessions.cast<rust.StoredSession?>().firstWhere(
          (s) => s?.userId == userId,
          orElse: () => null,
        );
        if (session == null) {
          throw StateError('找不到已保存的账号会话');
        }

        final displayName = await loadDisplayName(userId);
        await applyActiveSessionState(
          ref,
          userId: userId,
          displayName: displayName,
          homeserver: session.homeserverUrl,
          persistActiveUser: true,
          refreshStoredSessions: true,
        );
        await bootstrapActiveSessionSync(
          ref,
          attemptLabel: 'syncOnce after switch attempt',
          startSyncLabel: 'startSync after switch failed',
        );
      }
    } catch (e) {
      if (switchedClient && activeId != null) {
        try {
          final reverted = await rust.switchAccount(userId: activeId);
          if (reverted) {
            final sessions = await loadAllSessions();
            final activeSession = sessions
                .cast<rust.StoredSession?>()
                .firstWhere((s) => s?.userId == activeId, orElse: () => null);
            if (activeSession != null) {
              final displayName = await loadDisplayName(activeId);
              await applyActiveSessionState(
                ref,
                userId: activeId,
                displayName: displayName,
                homeserver: activeSession.homeserverUrl,
                refreshStoredSessions: true,
              );
            }
          }
        } catch (rollbackError) {
          debugPrint('Failed to roll back account switch: $rollbackError');
        }
      }
      ref.read(sessionReadyProvider.notifier).value = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('切换账号失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    ref.read(sessionReadyProvider.notifier).value = true;
  }

  Future<void> _removeAccount(String userId) async {
    final activeId = ref.read(activeUserIdProvider);
    final isCurrentAccount = userId == activeId;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          isCurrentAccount ? '退出登录' : '移除账号',
          style: const TextStyle(color: AppColors.onBackground),
        ),
        content: Text(
          isCurrentAccount ? '确定要退出当前账号吗？' : '确定要移除这个账号吗？',
          style: const TextStyle(color: AppColors.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      if (isCurrentAccount) {
        await rust.logout();
      } else {
        await rust.removeAccount(userId: userId);
      }
      await removeSession(userId);
      await _loadAccounts();

      if (isCurrentAccount) {
        // Check if there are other accounts
        final remaining = await loadAllSessions();
        if (remaining.isNotEmpty) {
          // Switch to the first remaining account
          final nextSession = remaining.first;
          await _switchAccount(nextSession.userId);
        } else {
          // No accounts left, go to login
          clearActiveSessionState(ref, markSessionReady: true);
        }
      }

      ref.read(sessionsProvider.notifier).value = await loadAllSessions();
    } catch (e) {
      debugPrint('Failed to remove account: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentUserProvider);
    final activeUserId = ref.watch(activeUserIdProvider);

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
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ProfileEditPage(),
                        ),
                      );
                    },
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        AppAvatar(
                          fallback: currentUser?.displayName ?? '我',
                          size: 60,
                          url: currentUser?.avatarUrl,
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

                  // ── Account switcher ────────────────────────────────
                  if (_accounts.length > 1) ...[
                    const SizedBox(height: 20),
                    _buildGroup(
                      title: '账号切换',
                      items: _accounts.map((account) {
                        final isActive = account.userId == activeUserId;
                        return _SettingItem(
                          icon: Icons.person_outline_rounded,
                          iconColor: isActive
                              ? AppColors.primary
                              : AppColors.onSurfaceVariant,
                          title: _formatUserId(account.userId),
                          subtitle: account.homeserverUrl.replaceAll(
                            RegExp(r'https?://'),
                            '',
                          ),
                          trailing: isActive
                              ? const Icon(
                                  Icons.check_circle_rounded,
                                  color: AppColors.primary,
                                  size: 20,
                                )
                              : null,
                          onTap: isActive
                              ? null
                              : () => _switchAccount(account.userId),
                        );
                      }).toList(),
                    ),
                  ],

                  const SizedBox(height: 20),
                  // Settings groups
                  _buildGroup(
                    title: '通用',
                    items: [
                      _SettingItem(
                        icon: Icons.dark_mode_rounded,
                        iconColor: AppColors.secondary,
                        title: '主题',
                        subtitle: '当前固定为深色',
                      ),
                      _SettingItem(
                        icon: Icons.notifications_rounded,
                        iconColor: AppColors.warning,
                        title: '通知',
                        subtitle: '暂未提供应用内设置',
                      ),
                      _SettingItem(
                        icon: Icons.language_rounded,
                        iconColor: AppColors.success,
                        title: '语言',
                        subtitle: '当前固定为简体中文',
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
                        subtitle:
                            currentUser?.homeserver.replaceAll(
                              RegExp(r'https?://'),
                              '',
                            ) ??
                            'matrix.org',
                      ),
                      _SettingItem(
                        icon: Icons.sync_rounded,
                        iconColor: AppColors.primaryVariant,
                        title: '同步设置',
                        subtitle: '自动管理，无手动配置项',
                      ),
                      _SettingItem(
                        icon: Icons.security_rounded,
                        iconColor: AppColors.success,
                        title: '加密',
                        subtitle: '设备验证与加密恢复',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const EncryptionPage(),
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
                        title: '当前版本',
                        subtitle: _versionLabel,
                        onTap:
                            appUpdateService.isSupported && !_checkingForUpdate
                            ? _checkForUpdate
                            : null,
                        trailing: _checkingForUpdate
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
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
                      _SettingItem(
                        icon: Icons.terminal_rounded,
                        iconColor: AppColors.warning,
                        title: '查看日志',
                        subtitle: '调试连接、同步问题',
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const LogViewerPage(),
                            ),
                          );
                        },
                      ),
                      _SettingItem(
                        icon: Icons.file_download_outlined,
                        iconColor: AppColors.primary,
                        title: '导出诊断报告',
                        subtitle: '包含日志、设备及版本信息',
                        trailing: _exportingDiagnostics
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                        onTap: _exportingDiagnostics
                            ? null
                            : _exportDiagnostics,
                      ),
                    ],
                  ),
                  if (currentUser != null) ...[
                    const SizedBox(height: 20),
                    // Remove other accounts (not current)
                    ..._accounts
                        .where((a) => a.userId != activeUserId)
                        .map(
                          (account) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: AppCard(
                              color: AppColors.onSurfaceVariant.withValues(
                                alpha: 0.06,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              onTap: () => _removeAccount(account.userId),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.remove_circle_outline_rounded,
                                    color: AppColors.onSurfaceVariant,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '移除 ${_formatUserId(account.userId)}',
                                    style: TextStyle(
                                      color: AppColors.onSurfaceVariant,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    const SizedBox(height: 8),
                    // Logout current account
                    AppCard(
                      color: AppColors.error.withValues(alpha: 0.12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      onTap: () =>
                          _removeAccount(activeUserId ?? currentUser.id),
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

  String _formatUserId(String userId) {
    // @aka:matrix.local -> aka (matrix.local)
    final parts = userId.split(':');
    final local = parts.first.replaceFirst('@', '');
    final server = parts.length > 1 ? parts.sublist(1).join(':') : '';
    return server.isNotEmpty ? '$local ($server)' : local;
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
  final VoidCallback? onTap;
  final Widget? trailing;

  const _SettingItem({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
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
                    style: TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 15,
                      fontWeight: onTap != null
                          ? FontWeight.w600
                          : FontWeight.w500,
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
            if (trailing != null)
              trailing!
            else if (onTap != null)
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
