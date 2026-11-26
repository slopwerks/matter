import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/app_update/app_update_service.dart';
import '../../features/app_update/update_dialog.dart';
import 'storage_page.dart';
import '../../features/diagnostics/diagnostic_exporter.dart';
import '../../features/push/push_providers.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/chat_visual_settings_provider.dart';
import '../../providers/app_font_provider.dart';
import '../../providers/interaction_mode_provider.dart';
import '../../providers/startup_page_provider.dart';
import '../../providers/session_credential_store.dart';
import '../../providers/theme_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;

import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/material_root_header.dart';
import '../../widgets/material_search_header.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/material_list_detail.dart';
import '../../widgets/glass.dart';
import '../../widgets/material_press.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/sheets.dart';
import '../login/login_page.dart';
import 'encryption_page.dart';
import 'blur_settings_page.dart';
import 'code_block_settings_page.dart';
import 'composer_keyboard_settings_page.dart';
import 'font_settings_page.dart';
import 'interaction_mode_settings_page.dart';
import 'startup_page_settings_page.dart';
import 'timeline_event_settings_page.dart';
import 'log_viewer_page.dart';
import 'material_color_settings_page.dart';
import 'notification_settings_page.dart';
import 'theme_settings_page.dart';
import 'settings_profile_card.dart';
import 'profile_edit_page.dart';

part 'settings_directory.dart';
part 'settings_sections.dart';

final accountSwitchControllerProvider = Provider(AccountSwitchController.new);
final accountSessionRemoverProvider = Provider<Future<void> Function(String)>(
  (_) => removeSession,
);

class AccountSwitchController {
  final Ref _ref;
  Future<void> _operationTail = Future.value();

  AccountSwitchController(this._ref);

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  String? _appendCleanupWarning(String? current, Object error) {
    final next = '本地会话清理失败: $error';
    return current == null ? next : '$current；$next';
  }

  String? _removalWarning(rust.AccountRemovalResult result) {
    final warnings = <String>[
      ?result.cleanupError,
      if (result.remoteLogoutPending)
        '远端会话撤销失败，服务器上的登录设备可能仍然有效，请从其他已登录客户端删除该设备',
    ];
    return warnings.isEmpty ? null : warnings.join('；');
  }

  Future<T> _runWithPersistedRemovalIntent<T>(
    String userId,
    Future<T> Function() removeFromRust,
  ) async {
    await markSessionRemoved(userId);
    try {
      await _ref
          .read(pushRegistrationManagerProvider)
          .prepareAccountRemoval(userId);
    } catch (error) {
      // Remote logout still revokes session-owned pushers when it succeeds.
      // Local delivery already stops at the persisted removal tombstone.
      debugPrint(
        'Push cleanup before account removal failed: ${error.runtimeType}',
      );
    }
    try {
      return await removeFromRust();
    } catch (error, stackTrace) {
      try {
        await unmarkSessionRemoved(userId);
      } catch (rollbackError) {
        throw StateError('账号删除失败：$error；本地删除状态回滚失败：$rollbackError');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<String?> _commitLocalAccountRemoval(
    String userId,
    rust.AccountRemovalResult result,
  ) async {
    var warning = _removalWarning(result);
    var localCleanupSucceeded = false;
    try {
      await _ref.read(accountSessionRemoverProvider)(userId);
      localCleanupSucceeded = true;
    } catch (error) {
      warning = _appendCleanupWarning(warning, error);
    }

    // The account is gone from the running client even if a best-effort local
    // cache cleanup warned. Remove only its room-scoped composer state; the
    // account switched to above keeps its drafts intact.
    clearAccountComposerStateFromRef(_ref, userId);

    if (localCleanupSucceeded && result.cleanupError == null) {
      try {
        await unmarkSessionRemoved(userId);
      } catch (error) {
        warning = _appendCleanupWarning(warning, error);
      }
    }

    final current = _ref
        .read(sessionsProvider)
        .where((session) => session.userId != userId)
        .toList();
    try {
      _ref.read(sessionsProvider.notifier).value = (await loadAllSessions())
          .where((session) => session.userId != userId)
          .toList();
    } catch (error) {
      _ref.read(sessionsProvider.notifier).value = current;
      warning = _appendCleanupWarning(warning, error);
    }
    return warning;
  }

  Future<void> switchTo(String userId) => _serialize(() => _switchTo(userId));

  Future<String?> removeAccount(String userId) =>
      _serialize(() => _removeAccount(userId));

  Future<void> _switchTo(String userId) async {
    final activeId = _ref.read(activeUserIdProvider);
    if (userId == activeId) return;

    final sessions = await loadAllSessions();
    rust.StoredSession? sessionFor(String id) => sessions
        .cast<rust.StoredSession?>()
        .firstWhere((session) => session?.userId == id, orElse: () => null);

    final targetSession = sessionFor(userId);
    if (targetSession == null) {
      throw StateError('找不到已保存的账号会话');
    }
    final targetDisplayName = await loadDisplayName(userId);
    final previousSession = activeId == null ? null : sessionFor(activeId);
    if (activeId != null && previousSession == null) {
      throw StateError('找不到当前账号的已保存会话');
    }
    final previousDisplayName = activeId == null
        ? null
        : await loadDisplayName(activeId);

    var switchedClient = false;
    if (activeId != null) {
      // Invalidate outgoing async work before the process-wide Rust client
      // changes accounts.
      resetIgnoredListAccountState(activeId);
    }
    _ref.read(sessionReadyProvider.notifier).value = false;
    var restoreSessionGate = false;
    try {
      final success = await rust.switchAccount(userId: userId);
      if (!success) throw StateError('账号切换未生效');
      switchedClient = true;

      await applyActiveSessionStateFromRef(
        _ref,
        userId: userId,
        displayName: targetDisplayName,
        homeserver: targetSession.homeserverUrl,
        persistActiveUser: false,
        refreshStoredSessions: true,
      );
      await bootstrapActiveSessionSyncFromRef(
        _ref,
        attemptLabel: 'syncOnce after switch attempt',
        startSyncLabel: 'startSync after switch failed',
        requireSyncLoop: true,
      );
      await saveActiveUserId(userId);
      restoreSessionGate = true;
    } catch (error, stackTrace) {
      if (switchedClient &&
          activeId != null &&
          previousSession != null &&
          previousDisplayName != null) {
        try {
          final reverted = await rust.switchAccount(userId: activeId);
          if (!reverted) throw StateError('原账号回滚未生效');
          await applyActiveSessionStateFromRef(
            _ref,
            userId: activeId,
            displayName: previousDisplayName,
            homeserver: previousSession.homeserverUrl,
            persistActiveUser: false,
            refreshStoredSessions: true,
          );
          await bootstrapActiveSessionSyncFromRef(
            _ref,
            attemptLabel: 'syncOnce after switch rollback attempt',
            startSyncLabel: 'startSync after switch rollback failed',
            requireSyncLoop: true,
          );
          await saveActiveUserId(activeId);
          restoreSessionGate = true;
        } catch (rollbackError) {
          clearActiveSessionStateFromRef(_ref, markSessionReady: true);
          restoreSessionGate = true;
          throw StateError('账号切换失败：$error；回滚失败：$rollbackError');
        }
      } else {
        restoreSessionGate = true;
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _ref.read(sessionReadyProvider.notifier).value = restoreSessionGate;
    }
  }

  Future<String?> _removeAccount(String userId) async {
    final activeId = _ref.read(activeUserIdProvider);
    final isCurrentAccount = userId == activeId;
    final remaining = isCurrentAccount
        ? (await loadAllSessions())
              .where((session) => session.userId != userId)
              .toList()
        : const <rust.StoredSession>[];

    if (remaining.isNotEmpty) {
      // This whole switch-and-remove sequence stays inside the same queue, so
      // no later account action can reactivate the account being deleted.
      await _switchTo(remaining.first.userId);
      final result = await _runWithPersistedRemovalIntent(
        userId,
        () => rust.removeAccount(userId: userId),
      );
      return _commitLocalAccountRemoval(userId, result);
    } else if (isCurrentAccount) {
      _ref.read(sessionReadyProvider.notifier).value = false;
      late final rust.AccountRemovalResult result;
      try {
        result = await _runWithPersistedRemovalIntent(userId, rust.logout);
      } catch (error, stackTrace) {
        try {
          await bootstrapActiveSessionSyncFromRef(
            _ref,
            attemptLabel: 'syncOnce after logout failure attempt',
            startSyncLabel: 'startSync after logout failure failed',
            requireSyncLoop: true,
          );
          _ref.read(sessionReadyProvider.notifier).value = true;
        } catch (recoveryError) {
          clearActiveSessionStateFromRef(_ref, markSessionReady: true);
          throw StateError('退出失败：$error；恢复同步失败：$recoveryError');
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      final warning = await _commitLocalAccountRemoval(userId, result);
      try {
        return warning;
      } finally {
        _ref.read(sessionsProvider.notifier).value =
            const <rust.StoredSession>[];
        clearActiveSessionStateFromRef(_ref, markSessionReady: true);
      }
    } else {
      // Same ignore-list hygiene as the switch path (`_switchTo`): dropping
      // this account's in-memory state stops a draining queued write from
      // re-persisting the snapshot that is being deleted.
      resetIgnoredListAccountState(userId);
      final result = await _runWithPersistedRemovalIntent(
        userId,
        () => rust.removeAccount(userId: userId),
      );
      return _commitLocalAccountRemoval(userId, result);
    }
  }
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  List<rust.AccountInfo> _accounts = [];
  final _searchController = TextEditingController();
  String _query = '';
  void _setSettingsQuery(String value) => setState(() => _query = value);
  Object? _accountsLoadError;
  String _versionLabel = '读取中…';
  bool _checkingForUpdate = false;
  bool _exportingLogs = false;
  bool _credentialCompatibilityMode = false;
  bool _updatingCredentialCompatibilityMode = false;
  // The account being switched to (if any): shows progress on its tile and
  // blocks further switches. The Rust-side switch waits for the lifecycle
  // write lock, which in-flight P0 operations can hold for up to ~90s, so
  // the tap must give feedback instead of appearing dead.
  String? _switchingAccountId;
  // The account being removed (if any): same progress/blocking discipline
  // for the removal flow.
  String? _removingAccountId;
  bool _addingAccount = false;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _loadAppVersion();
    _loadCredentialCompatibilityMode();
    unawaited(refreshCurrentUserProfile(ref));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  Future<void> _loadCredentialCompatibilityMode() async {
    final enabled = await isSessionCredentialCompatibilityModeEnabled();
    if (mounted) {
      setState(() => _credentialCompatibilityMode = enabled);
    }
  }

  Future<void> _disableCredentialCompatibilityMode() async {
    if (_updatingCredentialCompatibilityMode) return;
    final confirmed = await showNeuConfirm(
      context,
      title: '关闭凭据兼容模式',
      message:
          '关闭后将删除兼容模式保存的登录凭据。由于当前设备的系统密钥库不可用，'
          '下次启动可能需要重新登录。\n\n确定继续吗？',
      confirmLabel: '关闭并删除凭据',
      danger: true,
    );
    if (!confirmed) return;

    setState(() => _updatingCredentialCompatibilityMode = true);
    try {
      await disableSessionCredentialCompatibilityMode();
      if (mounted) {
        setState(() => _credentialCompatibilityMode = false);
        neuToast(context, '兼容模式已关闭，下次启动可能需要重新登录');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('关闭兼容模式失败：$error')));
      }
    } finally {
      if (mounted) {
        setState(() => _updatingCredentialCompatibilityMode = false);
      }
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
          neuToast(context, '${result.current.displayName} 已是最新版本');
        case UpdateCheckStatus.unsupported:
          neuToast(context, '当前平台暂不支持应用内更新');
        case UpdateCheckStatus.skipped:
          break;
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('检查更新失败：$error')));
    } finally {
      if (mounted) setState(() => _checkingForUpdate = false);
    }
  }

  Future<void> _exportLogs() async {
    if (_exportingLogs) return;
    setState(() => _exportingLogs = true);
    try {
      final saved = await const DiagnosticExporter().exportLogsZip();
      if (!mounted) return;
      neuToast(context, saved ? '日志包已导出' : '已取消导出');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出日志包失败：$error')));
    } finally {
      if (mounted) setState(() => _exportingLogs = false);
    }
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await rust.listAccounts();
      if (mounted) {
        setState(() {
          _accounts = accounts;
          _accountsLoadError = null;
        });
      }
    } catch (e) {
      debugPrint('Failed to load accounts: $e');
      if (mounted) {
        setState(() {
          // Keep previously loaded accounts visible; only flag the error.
          _accountsLoadError = e;
        });
      }
    }
  }

  Future<void> _addAccount() async {
    if (_addingAccount ||
        _switchingAccountId != null ||
        _removingAccountId != null ||
        !ref.read(sessionReadyProvider)) {
      return;
    }
    final homeserver = ref.read(currentUserProvider)?.homeserver;
    setState(() => _addingAccount = true);
    try {
      // Activating the new account replaces the tab tree before its first
      // sync completes. Keep the login route alive above that tree.
      final added = await Navigator.of(context, rootNavigator: true).push<bool>(
        MaterialPageRoute(
          builder: (_) =>
              LoginPage(initialHomeserver: homeserver, addingAccount: true),
        ),
      );
      if (added != true) await rust.cancelPendingLogin();
      if (mounted) await _loadAccounts();
    } catch (error) {
      if (mounted) neuToast(context, '添加账号失败：$error');
    } finally {
      if (mounted) setState(() => _addingAccount = false);
    }
  }

  Future<void> _switchAccount(String userId) async {
    final controller = ref.read(accountSwitchControllerProvider);
    setState(() => _switchingAccountId = userId);
    try {
      await controller.switchTo(userId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('切换账号失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _switchingAccountId = null);
    }
  }

  Future<void> _removeAccount(String userId) async {
    final activeId = ref.read(activeUserIdProvider);
    final isCurrentAccount = userId == activeId;
    final accountController = ref.read(accountSwitchControllerProvider);

    final confirmed = await showNeuConfirm(
      context,
      title: isCurrentAccount ? '退出登录' : '移除账号',
      message: isCurrentAccount ? '确定要退出当前账号吗？' : '确定要移除这个账号吗？',
      confirmLabel: '确定',
      danger: true,
    );

    if (!confirmed) return;
    if (!mounted) return;
    // The Rust-side removal waits for the lifecycle write lock, which
    // in-flight P0 operations can hold for up to ~90s; show progress and
    // block further account actions instead of a frozen-looking UI.
    setState(() => _removingAccountId = userId);
    try {
      final warning = await accountController.removeAccount(userId);
      await _loadAccounts();
      if (warning != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('账号已从本机移除，但操作未完整完成: $warning'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
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
    } finally {
      if (mounted) setState(() => _removingAccountId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final currentUser = ref.watch(currentUserProvider);
    final activeUserId = ref.watch(activeUserIdProvider);
    final currentAccountId = activeUserId ?? currentUser?.id;
    final profile = SettingsProfileCard(
      user: currentUser,
      onTap: () {
        MaterialListDetail.push(
          context,
          MaterialPageRoute(builder: (_) => const ProfileEditPage()),
        );
      },
    );
    final sections = _sections(currentUser, activeUserId);
    if (context.isMaterial) {
      final groups = <_SettingsCategory, List<_SettingItem>>{};
      for (final section in sections) {
        for (final item in section.items) {
          (groups[item.category ?? section.category] ??= []).add(item);
        }
      }
      if (currentAccountId != null) {
        final busy =
            _addingAccount ||
            _removingAccountId != null ||
            _switchingAccountId != null;
        final accountItems = groups.putIfAbsent(
          _SettingsCategory.account,
          () => [],
        );
        for (final account in _accounts.where(
          (account) => account.userId != currentAccountId,
        )) {
          accountItems.add(
            _SettingItem(
              icon: Icons.person_remove_outlined,
              title: '移除 ${_formatUserId(account.userId)}',
              subtitle: '',
              onTap: busy ? null : () => _removeAccount(account.userId),
            ),
          );
        }
        accountItems.add(
          _SettingItem(
            icon: Icons.logout_rounded,
            iconColor: colors.error,
            title: '退出登录',
            subtitle: '',
            onTap: busy ? null : () => _removeAccount(currentAccountId),
          ),
        );
      }
      return _materialDirectory(profile, groups);
    }
    final accountActions = <Widget>[
      if (currentAccountId != null) ...[
        const SizedBox(height: NeuSpacing.xl),
        // Remove other accounts (not current)
        for (final account in _accounts.where(
          (a) => a.userId != currentAccountId,
        ))
          Padding(
            padding: const EdgeInsets.only(bottom: NeuSpacing.md),
            child: SizedBox(
              width: double.infinity,
              child: NeuButton(
                padding: const EdgeInsets.symmetric(vertical: 12),
                onPressed:
                    (_addingAccount ||
                        _removingAccountId != null ||
                        _switchingAccountId != null)
                    ? null
                    : () => _removeAccount(account.userId),
                icon: _removingAccountId == account.userId
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.remove_circle_outline_rounded),
                child: Text('移除 ${_formatUserId(account.userId)}'),
              ),
            ),
          ),
        // Logout current account
        SizedBox(
          width: double.infinity,
          child: NeuButton(
            padding: const EdgeInsets.symmetric(vertical: 14),
            onPressed:
                (_addingAccount ||
                    _removingAccountId != null ||
                    _switchingAccountId != null)
                ? null
                : () => _removeAccount(currentAccountId),
            icon: _removingAccountId == currentAccountId
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.logout_rounded, color: colors.error),
            child: Text('退出登录', style: TextStyle(color: colors.error)),
          ),
        ),
      ],
    ];
    final header = MaterialRootHeader(
      title: '设置',
      compact: MaterialRootHeader.isCompact(context),
    );

    return Scaffold(
      backgroundColor: colors.base,
      extendBodyBehindAppBar: context.isMaterial,
      appBar: context.isMaterial ? header : null,
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              // 标题栏移到上方浮层,这里只预留其高度。
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  NeuSpacing.lg,
                  MediaQuery.viewPaddingOf(context).top +
                      (context.isMaterial
                          ? header.preferredSize.height
                          : kToolbarHeight) +
                      NeuSpacing.lg,
                  NeuSpacing.lg,
                  context.isMaterial
                      ? NeuSpacing.floatingDockClearance +
                            MediaQuery.paddingOf(context).bottom
                      : NeuSpacing.navClearance,
                ),
                sliver: SliverList.list(
                  children: [
                    profile,
                    for (final section in sections) ...[
                      const SizedBox(height: NeuSpacing.xl),
                      _buildGroup(title: section.title, items: section.items),
                    ],
                    ...accountActions,
                  ],
                ),
              ),
            ],
          ),
          // 渐变模糊层:柔和过渡从标题栏下方滚过的内容。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.viewPaddingOf(context).top + kToolbarHeight,
              child: const TopFadeBlur(useShader: true),
            ),
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: kToolbarHeight,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '设置',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ),
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
          padding: const EdgeInsets.fromLTRB(4, 0, 4, NeuSpacing.sm),
          child: Text(
            title,
            style: context.isMaterial
                ? materialSettingsSectionStyle(Theme.of(context))
                : Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
          ),
        ),
        // 分组是一张卡:每行自带卡片填充,首行只圆上角、末行只圆下角,
        // 行与行零间距,于是连续的几行看上去是一整块。行间细线是卡内部的
        // 分割,不是两道边界。新拟物的行本身就是凸起块,走同组件的另一分支。
        if (context.isMaterial)
          GroupedRows(children: items)
        else
          NeuSurface(
            color: context.neu.card,
            radius: NeuRadius.surface,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (var index = 0; index < items.length; index++) ...[
                  if (index > 0) const _Hairline(),
                  items[index],
                ],
              ],
            ),
          ),
      ],
    );
  }

  _SettingItem _buildChatVisualSwitch({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _SettingItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch.adaptive(value: value, onChanged: onChanged),
    );
  }
}

/// 卡片行之间的细分隔线(主题 hairline,与行内文字左缘对齐)。
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: NeuSpacing.rowTitleInset,
      endIndent: NeuSpacing.lg,
      color: context.neu.hairline,
    );
  }
}

class _SettingItem extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String keywords;

  /// 这一行是「在此处选择一个值」(弹出选择),而不是「进入下一层」。
  /// 两者的箭头不同:选择用上下双箭头,进入用右箭头 —— 否则用户在点之前
  /// 不知道会跳转页面还是弹出一个选择器。
  final bool selects;
  final _SettingsCategory? category;

  const _SettingItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.iconColor,
    this.onTap,
    this.trailing,
    this.keywords = '',
    this.selects = false,
    this.category,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    if (context.isMaterial) {
      return MaterialPress(
        builder: (states) => ListTile(
          statesController: states,
          leading: Icon(icon, color: iconColor),
          title: Text(title),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          // 右箭头和行首分隔线缩进沿用新拟物分支的行规则:没有 trailing 时
          // 可点进下一层的行必须画出箭头,否则 Material 模式下这些行看不出能点。
          // 选择类行用上下双箭头,与进入下一层区分开。
          trailing: trailing != null || onTap == null
              ? trailing
              : Icon(
                  selects
                      ? Icons.unfold_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.textSecondary,
                ),
          onTap: onTap,
        ),
      );
    }
    final textTheme = Theme.of(context).textTheme;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor ?? colors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          ?trailing,
          if (trailing == null && onTap != null)
            Icon(
              selects ? Icons.unfold_more_rounded : Icons.chevron_right_rounded,
              size: 20,
              color: colors.textSecondary,
            ),
        ],
      ),
    );
    if (onTap == null) return row;
    return NeuAction(onTap: onTap, radius: NeuRadius.surface, child: row);
  }
}
