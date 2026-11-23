import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/session_credential_store.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_component_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'homeserver_list.dart';
import 'homeserver_resolver.dart';
import 'login_form.dart';
import 'login_layout.dart';

Future<bool> showSessionCredentialCompatibilityDialog(
  BuildContext context, {
  required bool loginAlreadyCompleted,
}) => showNeuConfirm(
  context,
  title: '设备安全存储不可用',
  message:
      '系统密钥库无法读取登录凭据，因此应用重启后会退出登录。\n\n'
      '可以启用兼容模式：登录凭据将改存到应用私有目录。普通应用无法访问，'
      '但 Root 权限、系统备份或取得设备文件访问权的人可能读取凭据。\n\n'
      '${loginAlreadyCompleted ? '启用后将继续当前登录。' : '启用后需要重新登录一次。'}',
  confirmLabel: '启用兼容模式',
  cancelLabel: '保持安全模式',
  barrierDismissible: false,
);

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({
    super.key,
    this.initialHomeserver,
    this.initialUserId,
    this.resumeSession = false,
    this.addingAccount = false,
  });

  final String? initialHomeserver;
  final String? initialUserId;
  final bool resumeSession;
  final bool addingAccount;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  late String _sessionSearchIndexKey;
  CurrentUser? _previousUser;
  final _homeserverController = TextEditingController();
  List<HomeserverEntry> _homeservers = const [];

  /// The resolved homeserver URL actually used to connect and to persist the
  /// session. Kept separate from the input field so the field can keep showing
  /// the user's original input (e.g. `example.com`) while we connect via a
  /// well-known-delegated URL (e.g. `https://matrix.example.com`).
  String _effectiveHomeserver = '';
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _tokenController = TextEditingController(); // registration token
  final _accessTokenController = TextEditingController(); // access token login
  final _userIdController = TextEditingController(); // for access token login
  final _deviceIdController = TextEditingController(); // for access token login

  bool _isPasswordVisible = false;
  bool _isLoading = false;
  bool _compatibilityDialogShown = false;
  bool _hasCompletedRustLogin = false;
  late final String _pendingSearchIndexKey = createSearchIndexKey();
  String? _error;

  // Homeserver inputs that the user has already accepted as insecure (HTTP)
  // this session, so we don't nag on every attempt (e.g. local dev servers).
  final Set<String> _httpConfirmedHosts = {};

  // UIAA state for registration
  String? _uiaaSession;

  // Tab state: 0 = login, 1 = register, 2 = token login
  int _tabIndex = 0;
  bool _choseLoginMethod = false;

  @override
  void initState() {
    super.initState();
    _sessionSearchIndexKey = _pendingSearchIndexKey;
    if (widget.addingAccount) _previousUser = ref.read(currentUserProvider);
    _homeserverController.text = widget.initialHomeserver ?? '';
    _usernameController.text =
        widget.initialUserId?.split(':').first.replaceFirst('@', '') ?? '';
    _userIdController.text = widget.initialUserId ?? '';
    _loadHomeservers();
  }

  Future<void> _loadHomeservers() async {
    final list = await loadHomeservers();
    if (mounted) setState(() => _homeservers = list);
  }

  @override
  void dispose() {
    _homeserverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _tokenController.dispose();
    _accessTokenController.dispose();
    _userIdController.dispose();
    _deviceIdController.dispose();
    super.dispose();
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  void _setFriendlyError(String fallbackMessage, [Object? error]) {
    final message = _friendlyAuthErrorMessage(
      fallbackMessage: fallbackMessage,
      error: error,
    );
    debugPrint('Auth flow failed: ${error ?? message}');
    if (mounted) {
      setState(() => _error = message);
    }
  }

  String _friendlyAuthErrorMessage({
    required String fallbackMessage,
    Object? error,
  }) {
    final raw = '$error';
    final text = raw.toLowerCase();
    if (text.isEmpty || raw == 'null') {
      return fallbackMessage;
    }
    if (text.contains('timed out') || text.contains('timeout')) {
      return '连接超时，请检查网络或服务器地址';
    }
    if (text.contains('network') ||
        text.contains('socket') ||
        text.contains('dns') ||
        text.contains('connection refused')) {
      return '无法连接到服务器，请检查网络或 Homeserver 地址';
    }
    if (text.contains('401') ||
        text.contains('403') ||
        text.contains('forbidden') ||
        text.contains('unauthorized') ||
        text.contains('invalid password') ||
        text.contains('unknown token') ||
        text.contains('access denied')) {
      return '认证失败，请检查账号、密码或 Token';
    }
    if (text.contains('uiaa') ||
        text.contains('registration token') ||
        text.contains('missing token')) {
      return '注册需要有效的注册 Token';
    }
    if (text.contains('already signed in') || text.contains('该账号已登录')) {
      return '该账号已登录，请返回设置切换账号';
    }
    if (text.contains('no client created')) {
      return '客户端初始化失败，请重试';
    }
    return fallbackMessage;
  }

  Future<void> _handleAuthFailure(String fallbackMessage, Object error) async {
    final credentialStoreFailure = _hasCompletedRustLogin
        ? detectSessionCredentialStoreFailure(error)
        : null;
    if (credentialStoreFailure != null) {
      ref.read(sessionCredentialStoreFailureProvider.notifier).value =
          credentialStoreFailure;
      await _offerCredentialCompatibilityMode();
      return;
    }
    if (_hasCompletedRustLogin) {
      debugPrint('Post-login session persistence failed: $error');
      final message = await _discardCompletedRustLogin('认证已成功，但本地会话保存失败');
      if (mounted) {
        setState(() => _error = message);
      }
      return;
    }
    _setFriendlyError(fallbackMessage, error);
  }

  Future<String> _discardCompletedRustLogin(String reason) async {
    final result = await discardUnpersistedLoginSession();
    if (result.rustSessionDiscarded) {
      _hasCompletedRustLogin = false;
      if (mounted) {
        if (_previousUser != null) {
          try {
            await _restorePreviousAccount();
          } catch (error) {
            clearActiveSessionState(ref, markSessionReady: true);
            return '$reason。本次登录已撤销，但恢复原账号失败，请重启应用：$error';
          }
        } else {
          ref.read(sessionReadyProvider.notifier).value = true;
        }
      }
    }
    final warning = result.warning;
    if (!result.rustSessionDiscarded) {
      return warning == null
          ? '$reason。无法撤销本次登录，请重启应用'
          : '$reason。无法完整撤销本次登录，请重启应用：$warning';
    }
    return warning == null
        ? '$reason。本次登录已撤销，请重试'
        : '$reason。本地登录状态已清理，但操作未完整完成：$warning';
  }

  Future<void> _offerCredentialCompatibilityMode() async {
    if (_compatibilityDialogShown || !mounted) return;
    final failure = ref.read(sessionCredentialStoreFailureProvider);
    if (failure == null) return;
    _compatibilityDialogShown = true;

    final enabled = await showSessionCredentialCompatibilityDialog(
      context,
      loginAlreadyCompleted: _hasCompletedRustLogin,
    );
    if (!mounted) {
      if (_hasCompletedRustLogin) {
        await discardUnpersistedLoginSession();
      }
      return;
    }
    if (!enabled) {
      _compatibilityDialogShown = false;
      final message = _hasCompletedRustLogin
          ? await _discardCompletedRustLogin('未启用兼容模式')
          : '设备安全存储不可用，关闭应用后可能需要重新登录';
      if (mounted) {
        setState(() => _error = message);
      }
      return;
    }

    setState(() => _isLoading = true);
    try {
      await enableSessionCredentialCompatibilityModeAfterFailure();
      ref.read(sessionCredentialStoreFailureProvider.notifier).value = null;
      if (_hasCompletedRustLogin) {
        final session = await rust.getSession();
        if (session == null) {
          throw StateError('无法获取已完成的登录会话');
        }
        final displayName = _tabIndex == 2
            ? session.userId.split(':').first.replaceFirst('@', '')
            : _usernameController.text;
        await _onAuthSuccess(session.userId, displayName);
      } else if (mounted) {
        setState(() => _error = '兼容模式已启用，请重新登录');
      }
    } catch (error) {
      _compatibilityDialogShown = false;
      final message = _hasCompletedRustLogin
          ? await _discardCompletedRustLogin('启用兼容模式失败')
          : '启用兼容模式失败';
      debugPrint('Credential compatibility recovery failed: $error');
      if (mounted) setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _onAuthSuccess(String userId, String displayName) async {
    // Keep API-backed providers gated until the new crypto store has completed
    // its first sync. Querying rooms while that sync initializes can leave the
    // first room-list request waiting on the store until the app is restarted.
    ref.read(sessionReadyProvider.notifier).value = false;

    try {
      await _persistAndSync(userId, displayName);
    } catch (_) {
      if (!widget.addingAccount) {
        ref.read(sessionReadyProvider.notifier).value = true;
      }
      rethrow;
    }
    if (!mounted) return;
    ref.read(isLoggedInProvider.notifier).value = true;
    if (widget.addingAccount) Navigator.of(context).pop(true);
  }

  Future<void> _restorePreviousAccount() async {
    final previous = _previousUser!;
    if (!await rust.switchAccount(userId: previous.id)) {
      throw StateError('原账号会话不可用');
    }
    if (!mounted) return;
    await applyActiveSessionState(
      ref,
      userId: previous.id,
      displayName: previous.displayName,
      homeserver: previous.homeserver,
      persistActiveUser: true,
      refreshStoredSessions: true,
    );
    await bootstrapActiveSessionSync(
      ref,
      attemptLabel: 'Restore original account sync attempt',
      startSyncLabel: 'Restore original account sync failed',
    );
    ref.read(sessionReadyProvider.notifier).value = true;
  }

  void _beginAuthAttempt() {
    setState(() => _isLoading = true);
    if (widget.addingAccount) {
      resetIgnoredListAccountState(_previousUser?.id ?? '');
      ref.read(sessionReadyProvider.notifier).value = false;
    }
  }

  void _finishAuthAttempt() {
    if (!mounted) return;
    if (widget.addingAccount && !_hasCompletedRustLogin) {
      ref.read(sessionReadyProvider.notifier).value = true;
    }
    setState(() => _isLoading = false);
  }

  Future<void> _persistAndSync(String userId, String displayName) async {
    // Persist session
    final session = await rust.getSession();
    if (session == null) {
      throw StateError('登录成功后无法获取最终会话');
    }
    await persistSession(
      homeserver: _effectiveHomeserver,
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      userId: session.userId,
      deviceId: session.deviceId,
      displayName: displayName,
      searchIndexKey: _sessionSearchIndexKey,
    );
    await applyActiveSessionState(
      ref,
      userId: session.userId,
      displayName: displayName,
      homeserver: _effectiveHomeserver,
      refreshStoredSessions: true,
      markLoggedIn: false,
    );
    try {
      await bootstrapActiveSessionSync(
        ref,
        attemptLabel: 'Initial sync attempt',
        startSyncLabel: 'startSync failed',
      );
    } catch (e) {
      debugPrint('Initial sync after login failed: $e');
    }
    // Signal that Rust APIs are safe to call before building the main app.
    ref.read(sessionReadyProvider.notifier).value = true;
  }

  Future<String> _getDataDir() async {
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  }

  /// Resolve the homeserver input to a full URL, preferring HTTPS and
  /// falling back to HTTP only after the user acknowledges the risk. Returns
  /// null (and surfaces an error) if resolution fails or is cancelled.
  Future<String?> _resolveHomeserverUrl() async {
    final raw = _homeserverController.text;
    try {
      final resolved = await resolveHomeserver(raw);
      if (resolved.isHttp && !_httpConfirmedHosts.contains(resolved.url)) {
        if (!mounted) return null;
        final confirmed = await _confirmInsecure(resolved);
        if (!confirmed) return null;
        _httpConfirmedHosts.add(resolved.url);
      }
      _effectiveHomeserver = resolved.url;
      return resolved.url;
    } catch (e) {
      _setFriendlyError('无法连接到 Homeserver，请检查地址', e);
      return null;
    }
  }

  Future<bool> _confirmInsecure(ResolvedHomeserver resolved) {
    return showNeuConfirm(
      context,
      title: '不安全的连接',
      message:
          '该服务器（${resolved.url}）仅支持未加密的 HTTP 连接。\n\n'
          '你的密码和登录凭证将以明文传输，可能被同一网络中的第三方截获。\n\n'
          '确定要继续吗？',
      confirmLabel: '继续登录',
    );
  }

  Future<void> _login() async {
    if (_isLoading) return;
    _clearError();
    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }

    _beginAuthAttempt();
    try {
      final homeserverUrl = await _resolveHomeserverUrl();
      if (homeserverUrl == null) return;
      if (_hasCompletedRustLogin) {
        throw StateError('登录已成功，但本地凭据保存失败；请重启应用后再试');
      }
      final originalUser = widget.initialUserId;
      final username = _usernameController.text.trim();
      final resume =
          widget.resumeSession &&
          originalUser != null &&
          (username == originalUser ||
              username ==
                  originalUser.split(':').first.replaceFirst('@', '')) &&
          homeserverUrl.replaceFirst(RegExp(r'/$'), '') ==
              widget.initialHomeserver?.replaceFirst(RegExp(r'/$'), '');
      final rust.AuthResult result;
      if (resume) {
        final indexKey = await loadOrCreateSearchIndexKey(originalUser);
        _sessionSearchIndexKey = indexKey.key.isEmpty
            ? _pendingSearchIndexKey
            : indexKey.key;
        result = await rust.resumeSessionWithPassword(
          accountUserId: originalUser,
          password: _passwordController.text,
          searchIndexKey: indexKey.key,
          resetSearchIndex: indexKey.created,
          useInMemorySearchIndex: indexKey.key.isEmpty,
        );
      } else {
        _sessionSearchIndexKey = _pendingSearchIndexKey;
        final useInMemorySearchIndex =
            await isSessionCredentialCompatibilityModeEnabled();
        await rust.createClient(
          homeserverUrl: homeserverUrl,
          dataDir: await _getDataDir(),
          searchIndexKey: useInMemorySearchIndex ? '' : _pendingSearchIndexKey,
          useInMemorySearchIndex: useInMemorySearchIndex,
        );
        result = await rust.loginWithPassword(
          username: username,
          password: _passwordController.text,
        );
      }
      if (result.success) {
        _hasCompletedRustLogin = true;
        await _onAuthSuccess(result.userId ?? '', _usernameController.text);
      } else if (mounted) {
        _setFriendlyError('登录失败，请稍后重试', result.error);
      }
    } catch (e) {
      await _handleAuthFailure('登录失败，请稍后重试', e);
    } finally {
      _finishAuthAttempt();
    }
  }

  Future<void> _register() async {
    if (_isLoading) return;
    _sessionSearchIndexKey = _pendingSearchIndexKey;
    _clearError();

    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }

    // If we have a UIAA session, we need the registration token
    if (_uiaaSession != null && _tokenController.text.isEmpty) {
      setState(() => _error = '请输入注册 Token');
      return;
    }

    _beginAuthAttempt();
    try {
      final homeserverUrl = await _resolveHomeserverUrl();
      if (homeserverUrl == null) return;
      if (_hasCompletedRustLogin) {
        throw StateError('注册已成功，但本地凭据保存失败；请重启应用后再试');
      }
      final useInMemorySearchIndex =
          await isSessionCredentialCompatibilityModeEnabled();
      await rust.createClient(
        homeserverUrl: homeserverUrl,
        dataDir: await _getDataDir(),
        searchIndexKey: useInMemorySearchIndex ? '' : _pendingSearchIndexKey,
        useInMemorySearchIndex: useInMemorySearchIndex,
      );

      rust.AuthResult result;

      if (_uiaaSession != null) {
        // Step 2: complete registration with token + session
        result = await rust.registerCompleteUiaa(
          username: _usernameController.text,
          password: _passwordController.text,
          registrationToken: _tokenController.text,
          session: _uiaaSession!,
        );
      } else {
        // Step 1: get UIAA session from server
        result = await rust.registerGetUiaaSession(
          username: _usernameController.text,
          password: _passwordController.text,
        );
      }

      if (result.needsUiaa) {
        // Server requires UIAA — show the token input field
        setState(() {
          _uiaaSession = result.session;
          _isLoading = false;
        });
        return;
      }

      if (result.success) {
        _hasCompletedRustLogin = true;
        await _onAuthSuccess(result.userId ?? '', _usernameController.text);
      } else if (mounted) {
        _setFriendlyError('注册失败，请稍后重试', result.error);
      }
    } catch (e) {
      await _handleAuthFailure('注册失败，请稍后重试', e);
    } finally {
      _finishAuthAttempt();
    }
  }

  Future<void> _loginWithAccessToken() async {
    if (_isLoading) return;
    _sessionSearchIndexKey = _pendingSearchIndexKey;
    _clearError();
    if (_accessTokenController.text.isEmpty || _userIdController.text.isEmpty) {
      setState(() => _error = '请输入 Access Token 和 User ID');
      return;
    }

    _beginAuthAttempt();
    try {
      final homeserverUrl = await _resolveHomeserverUrl();
      if (homeserverUrl == null) return;
      if (_hasCompletedRustLogin) {
        throw StateError('登录已成功，但本地凭据保存失败；请重启应用后再试');
      }
      final useInMemorySearchIndex =
          await isSessionCredentialCompatibilityModeEnabled();
      await rust.createClient(
        homeserverUrl: homeserverUrl,
        dataDir: await _getDataDir(),
        searchIndexKey: useInMemorySearchIndex ? '' : _pendingSearchIndexKey,
        useInMemorySearchIndex: useInMemorySearchIndex,
      );
      final result = await rust.loginWithToken(
        accessToken: _accessTokenController.text,
        userId: _userIdController.text,
        deviceId: _deviceIdController.text.isEmpty
            ? 'MATTER'
            : _deviceIdController.text,
        refreshToken: null,
      );
      if (result.success) {
        _hasCompletedRustLogin = true;
        final userId = result.userId ?? _userIdController.text;
        await _onAuthSuccess(
          userId,
          userId.split(':').first.replaceFirst('@', ''),
        );
      } else if (mounted) {
        _setFriendlyError('Token 登录失败，请检查输入信息', result.error);
      }
    } catch (e) {
      await _handleAuthFailure('Token 登录失败，请检查输入信息', e);
    } finally {
      _finishAuthAttempt();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasWelcome =
        context.isMaterial &&
        !widget.addingAccount &&
        !widget.resumeSession &&
        widget.initialUserId == null &&
        widget.initialHomeserver == null;
    final welcome = hasWelcome && !_choseLoginMethod;
    void choose(int mode) => setState(() {
      _tabIndex = mode;
      _choseLoginMethod = true;
      _uiaaSession = null;
      _clearError();
    });
    void backToWelcome() => setState(() => _choseLoginMethod = false);
    return PopScope(
      canPop:
          (!hasWelcome || welcome) &&
          (!widget.addingAccount || (!_isLoading && !_hasCompletedRustLogin)),
      onPopInvokedWithResult: (popped, _) {
        if (!popped && hasWelcome && !_isLoading && !_hasCompletedRustLogin) {
          backToWelcome();
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: widget.addingAccount && !context.isMaterial,
        appBar: widget.addingAccount
            ? buildFloatingAppBar(title: const Text('添加账号'))
            : hasWelcome && !welcome
            ? buildFloatingAppBar(
                title: Text(['登录', '创建账号', 'Token 登录'][_tabIndex]),
                leading: IconButton(
                  onPressed: _isLoading || _hasCompletedRustLogin
                      ? null
                      : backToWelcome,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回',
                ),
              )
            : null,
        backgroundColor: context.neu.base,
        body: LoginLayout(
          addingAccount: widget.addingAccount,
          resumeSession: widget.resumeSession,
          modeSelector: hasWelcome
              ? const SizedBox.shrink()
              : _buildModeChips(),
          form: welcome
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton(
                      onPressed: () => choose(0),
                      child: const Text('登录已有账号'),
                    ),
                    const SizedBox(height: NeuSpacing.sm),
                    FilledButton.tonal(
                      onPressed: () => choose(1),
                      child: const Text('创建账号'),
                    ),
                    TextButton(
                      onPressed: () => choose(2),
                      child: const Text('其他登录方式 · Token'),
                    ),
                  ],
                )
              : _buildFormCard(),
        ),
      ),
    );
  }

  Widget _buildModeChips() {
    const labels = ['登录', '注册', 'Token'];
    if (context.isMaterial) {
      return SegmentedButton<int>(
        showSelectedIcon: false,
        segments: [
          for (var i = 0; i < labels.length; i++)
            ButtonSegment(value: i, label: Text(labels[i])),
        ],
        selected: {_tabIndex},
        onSelectionChanged: _isLoading || _hasCompletedRustLogin
            ? null
            : (selection) {
                setState(() {
                  _tabIndex = selection.first;
                  _uiaaSession = null;
                  _clearError();
                });
              },
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: NeuSpacing.sm,
      runSpacing: NeuSpacing.sm,
      children: [
        for (var i = 0; i < labels.length; i++)
          NeuChip(
            label: labels[i],
            selected: _tabIndex == i,
            onTap: () {
              if (_isLoading || _hasCompletedRustLogin) return;
              setState(() {
                _tabIndex = i;
                _uiaaSession = null;
                _clearError();
              });
            },
          ),
      ],
    );
  }

  Widget _buildFormCard() => LoginForm(
    mode: _tabIndex,
    homeserver: _homeserverController,
    username: _usernameController,
    password: _passwordController,
    registrationToken: _tokenController,
    userId: _userIdController,
    deviceId: _deviceIdController,
    accessToken: _accessTokenController,
    passwordVisible: _isPasswordVisible,
    registrationTokenRequired: _uiaaSession != null,
    loading: _isLoading,
    error: _error,
    onChanged: _clearError,
    onTogglePassword: () =>
        setState(() => _isPasswordVisible = !_isPasswordVisible),
    onChooseHomeserver: _homeservers.isEmpty ? null : _showHomeserverSheet,
    onSubmit: switch (_tabIndex) {
      1 => _register,
      2 => _loginWithAccessToken,
      _ => _login,
    },
  );

  /// Open the preset-server list as a bottom sheet. Triggered by the trailing
  /// arrow button only — focusing the field stays a pure typing gesture and
  /// never opens this sheet.
  Future<void> _showHomeserverSheet() async {
    final selected = await showNeuSheet<HomeserverEntry>(
      context: context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '选择 Homeserver',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          for (final entry in _homeservers) _buildHomeserverItem(entry),
          const SizedBox(height: NeuSpacing.sm),
        ],
      ),
    );

    if (selected != null && mounted) {
      _homeserverController.text = selected.domain;
      _clearError();
    }
  }

  Widget _buildHomeserverItem(HomeserverEntry entry) {
    if (context.isMaterial) {
      final selected =
          entry.domain.toLowerCase() ==
          _homeserverController.text.trim().toLowerCase();
      return ListTile(
        leading: const Icon(Icons.dns_rounded),
        title: Text(entry.label),
        subtitle: entry.domain == entry.label ? null : Text(entry.domain),
        selected: selected,
        selectedTileColor: AppComponentTheme.of(context).selectedRowFill,
        trailing: selected ? const Icon(Icons.check_rounded) : null,
        onTap: () => Navigator.of(context).pop(entry),
      );
    }
    return NeuSheetItem(
      icon: Icons.dns_rounded,
      label: entry.label,
      trailing: _buildHomeserverTrailing(entry),
      onTap: () => Navigator.of(context).pop(entry),
    );
  }

  Widget? _buildHomeserverTrailing(HomeserverEntry entry) {
    final colors = context.neu;
    final isSelected =
        entry.domain.toLowerCase() ==
        _homeserverController.text.trim().toLowerCase();
    if (entry.domain == entry.label && !isSelected) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (entry.domain != entry.label)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              entry.domain,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (isSelected) ...[
          if (entry.domain != entry.label) const SizedBox(width: NeuSpacing.sm),
          Icon(Icons.check_rounded, size: 18, color: colors.accent),
        ],
      ],
    );
  }
}
