import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/app_update/app_update_service.dart';
import '../../features/app_update/update_dialog.dart';
import '../../features/cache/image_cache_control.dart';
import '../../features/diagnostics/diagnostic_exporter.dart';
import '../../providers/auth_provider.dart';
import '../../providers/authenticated_media_cache.dart';
import '../../providers/chat_provider.dart';
import '../../providers/session_credential_store.dart';
import '../../providers/theme_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;

import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'encryption_page.dart';
import 'log_viewer_page.dart';
import 'profile_edit_page.dart';

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
  Object? _accountsLoadError;
  String _versionLabel = '读取中…';
  String _cacheSizeLabel = '计算中…';
  bool _checkingForUpdate = false;
  bool _exportingLogs = false;
  bool _clearingCache = false;
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

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _loadAppVersion();
    _loadCredentialCompatibilityMode();
    if (!kIsWeb) _loadCacheSize();
    unawaited(refreshCurrentUserProfile(ref));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('关闭兼容模式失败：$error')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('检查更新失败：$error')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出日志包失败：$error')));
    } finally {
      if (mounted) setState(() => _exportingLogs = false);
    }
  }

  Future<void> _loadCacheSize() async {
    try {
      final bytes = await imageCacheSizeBytes();
      if (mounted) setState(() => _cacheSizeLabel = _formatCacheSize(bytes));
    } catch (error) {
      debugPrint('Failed to measure cache size: $error');
      if (mounted) setState(() => _cacheSizeLabel = '大小未知');
    }
  }

  Future<void> _clearCache() async {
    if (_clearingCache) return;
    final confirmed = await showNeuConfirm(
      context,
      title: '清理缓存',
      message: '将删除已下载的图片与媒体缓存，下次查看时会重新加载。确定继续吗？',
      confirmLabel: '清理',
      danger: true,
    );
    if (!confirmed) return;

    setState(() => _clearingCache = true);
    try {
      imageCache.clear();
      await resetAuthenticatedMediaCacheManagers();
      await clearImageCacheFiles();
      if (!mounted) return;
      neuToast(context, '缓存已清理');
      await _loadCacheSize();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('清理缓存失败：$error')));
    } finally {
      if (mounted) setState(() => _clearingCache = false);
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

    return Scaffold(
      backgroundColor: colors.base,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            pinned: true,
            title: Text('设置', style: Theme.of(context).textTheme.titleLarge),
            backgroundColor: colors.base,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                NeuSpacing.lg,
                NeuSpacing.lg,
                NeuSpacing.lg,
                NeuSpacing.navClearance,
              ),
              child: Column(
                children: [
                  // Profile card
                  NeuAction(
                    radius: NeuRadius.surface,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ProfileEditPage(),
                        ),
                      );
                    },
                    child: NeuSurface(
                      color: colors.card,
                      radius: NeuRadius.surface,
                      padding: const EdgeInsets.all(NeuSpacing.lg),
                      child: Row(
                        children: [
                          AppAvatar(
                            fallback: currentUser?.displayName ?? '我',
                            size: 60,
                            url: currentUser?.avatarUrl,
                          ),
                          const SizedBox(width: NeuSpacing.lg),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentUser?.displayName ?? '未登录',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  currentUser != null
                                      ? currentUser.id
                                      : '点击登录你的 Matrix 账号',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── Account switcher ────────────────────────────────
                  if (_accountsLoadError != null) ...[
                    const SizedBox(height: NeuSpacing.xl),
                    _buildGroup(
                      title: '账号',
                      items: [
                        _SettingItem(
                          icon: Icons.error_outline_rounded,
                          iconColor: colors.error,
                          title: '账号列表加载失败',
                          subtitle: '$_accountsLoadError',
                          onTap: _loadAccounts,
                        ),
                      ],
                    ),
                  ],
                  if (_accounts.length > 1) ...[
                    const SizedBox(height: NeuSpacing.xl),
                    _buildGroup(
                      title: '账号切换',
                      items: _accounts.map((account) {
                        final isActive = account.userId == activeUserId;
                        return _SettingItem(
                          icon: Icons.person_outline_rounded,
                          iconColor: isActive ? colors.accent : null,
                          title: _formatUserId(account.userId),
                          subtitle: account.homeserverUrl.replaceAll(
                            RegExp(r'https?://'),
                            '',
                          ),
                          trailing: isActive
                              ? Icon(
                                  Icons.check_circle_rounded,
                                  color: colors.accent,
                                  size: 20,
                                )
                              : _switchingAccountId == account.userId
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                          // Removal internally switches accounts (see
                          // `_removeAccount`); during that window a switch
                          // tile must stay disabled like the remove buttons,
                          // or a queued tap can target the account being
                          // deleted.
                          onTap:
                              (isActive ||
                                  _switchingAccountId != null ||
                                  _removingAccountId != null)
                              ? null
                              : () => _switchAccount(account.userId),
                        );
                      }).toList(),
                    ),
                  ],

                  const SizedBox(height: NeuSpacing.xl),
                  // Settings groups
                  _buildGroup(
                    title: '通用',
                    items: [
                      _SettingItem(
                        icon: Icons.dark_mode_rounded,
                        title: '主题',
                        subtitle: _themeStyleLabel(
                          ref.watch(appThemeStyleProvider),
                        ),
                        onTap: _showThemeStylePicker,
                      ),
                      _SettingItem(
                        icon: Icons.notifications_rounded,
                        title: '通知',
                        subtitle: '免打扰请在房间管理中设置',
                      ),
                      _SettingItem(
                        icon: Icons.language_rounded,
                        title: '语言',
                        subtitle: '当前固定为简体中文',
                      ),
                    ],
                  ),
                  const SizedBox(height: NeuSpacing.xl),
                  _buildGroup(
                    title: 'Matrix',
                    items: [
                      _SettingItem(
                        icon: Icons.account_tree_rounded,
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
                        title: '同步设置',
                        subtitle: '自动管理，无手动配置项',
                      ),
                      _SettingItem(
                        icon: Icons.security_rounded,
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
                  // On web there is no app-managed disk cache to clear; the
                  // browser owns the HTTP cache.
                  if (!kIsWeb) ...[
                    const SizedBox(height: NeuSpacing.xl),
                    _buildGroup(
                      title: '存储',
                      items: [
                        if (_credentialCompatibilityMode)
                          _SettingItem(
                            icon: Icons.warning_amber_rounded,
                            iconColor: colors.warning,
                            title: '凭据兼容模式',
                            subtitle: '已启用 · Root 权限可读取登录凭据',
                            trailing: _updatingCredentialCompatibilityMode
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : null,
                            onTap: _updatingCredentialCompatibilityMode
                                ? null
                                : _disableCredentialCompatibilityMode,
                          ),
                        _SettingItem(
                          icon: Icons.cleaning_services_rounded,
                          title: '清理缓存',
                          subtitle: '图片与媒体缓存 · $_cacheSizeLabel',
                          trailing: _clearingCache
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                          onTap: _clearingCache ? null : _clearCache,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: NeuSpacing.xl),
                  _buildGroup(
                    title: '关于',
                    items: [
                      _SettingItem(
                        icon: Icons.info_rounded,
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
                        title: '开源许可',
                        subtitle: '',
                        onTap: () {
                          showLicensePage(context: context);
                        },
                      ),
                      _SettingItem(
                        icon: Icons.terminal_rounded,
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
                        icon: Icons.folder_zip_outlined,
                        title: '导出日志',
                        subtitle: '完整日志 zip，含设备信息，已脱敏',
                        trailing: _exportingLogs
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                        onTap: _exportingLogs ? null : _exportLogs,
                      ),
                    ],
                  ),
                  if (currentUser != null) ...[
                    const SizedBox(height: NeuSpacing.xl),
                    // Remove other accounts (not current)
                    for (final account in _accounts.where(
                      (a) => a.userId != activeUserId,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(bottom: NeuSpacing.md),
                        child: SizedBox(
                          width: double.infinity,
                          child: NeuButton(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            onPressed:
                                (_removingAccountId != null ||
                                    _switchingAccountId != null)
                                ? null
                                : () => _removeAccount(account.userId),
                            icon: _removingAccountId == account.userId
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.remove_circle_outline_rounded,
                                  ),
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
                            (_removingAccountId != null ||
                                _switchingAccountId != null)
                            ? null
                            : () => _removeAccount(
                                activeUserId ?? currentUser.id,
                              ),
                        icon:
                            _removingAccountId ==
                                (activeUserId ?? currentUser.id)
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(Icons.logout_rounded, color: colors.error),
                        child: Text(
                          '退出登录',
                          style: TextStyle(color: colors.error),
                        ),
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

  String _formatCacheSize(int bytes) {
    const kilobyte = 1024;
    const megabyte = kilobyte * 1024;
    const gigabyte = megabyte * 1024;
    if (bytes >= gigabyte) {
      return '${(bytes / gigabyte).toStringAsFixed(1)} GB';
    }
    if (bytes >= megabyte) {
      return '${(bytes / megabyte).toStringAsFixed(1)} MB';
    }
    if (bytes >= kilobyte) {
      return '${(bytes / kilobyte).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  String _formatUserId(String userId) {
    // @aka:matrix.local -> aka (matrix.local)
    final parts = userId.split(':');
    final local = parts.first.replaceFirst('@', '');
    final server = parts.length > 1 ? parts.sublist(1).join(':') : '';
    return server.isNotEmpty ? '$local ($server)' : local;
  }

  String _themeStyleLabel(AppThemeStyle style) => switch (style) {
    AppThemeStyle.neuLight => '新拟物 · 浅色',
    AppThemeStyle.neuDark => '新拟物 · 深色',
    AppThemeStyle.neuSystem => '新拟物 · 跟随系统',
  };

  Future<void> _showThemeStylePicker() async {
    final current = ref.read(appThemeStyleProvider);
    await showNeuSheet<void>(
      context: context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final style in AppThemeStyle.values)
            NeuSheetItem(
              icon: style == current
                  ? Icons.check_circle_rounded
                  : Icons.circle_outlined,
              label: _themeStyleLabel(style),
              onTap: () {
                ref.read(appThemeStyleProvider.notifier).setStyle(style);
                Navigator.of(context).pop();
              },
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
          padding: const EdgeInsets.fromLTRB(4, 0, 4, NeuSpacing.sm),
          child: Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ),
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
}

/// 卡片行之间的细分隔线(主题 hairline,与行内文字左缘对齐)。
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 16,
      endIndent: 16,
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

  const _SettingItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.iconColor,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
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
              Icons.chevron_right_rounded,
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
