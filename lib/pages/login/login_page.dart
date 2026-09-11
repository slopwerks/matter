import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/session_credential_store.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'homeserver_list.dart';
import 'homeserver_resolver.dart';

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
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
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

  @override
  void initState() {
    super.initState();
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
        ref.read(sessionReadyProvider.notifier).value = true;
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
      ref.read(sessionReadyProvider.notifier).value = true;
      rethrow;
    }
    if (!mounted) return;
    ref.read(isLoggedInProvider.notifier).value = true;
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
      searchIndexKey: _pendingSearchIndexKey,
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
    _clearError();
    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }

    setState(() => _isLoading = true);
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
      final result = await rust.loginWithPassword(
        username: _usernameController.text,
        password: _passwordController.text,
      );
      if (result.success) {
        _hasCompletedRustLogin = true;
        await _onAuthSuccess(result.userId ?? '', _usernameController.text);
      } else if (mounted) {
        _setFriendlyError('登录失败，请稍后重试', result.error);
      }
    } catch (e) {
      await _handleAuthFailure('登录失败，请稍后重试', e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _register() async {
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

    setState(() => _isLoading = true);
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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loginWithAccessToken() async {
    _clearError();
    if (_accessTokenController.text.isEmpty || _userIdController.text.isEmpty) {
      setState(() => _error = '请输入 Access Token 和 User ID');
      return;
    }

    setState(() => _isLoading = true);
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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.neu.base,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      children: [
                        const SizedBox(height: 40),
                        _buildHeader(),
                        const SizedBox(height: 32),
                        _buildModeChips(),
                        const SizedBox(height: 20),
                        _buildFormCard(),
                        const Spacer(),
                        _buildFooter(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final colors = context.neu;
    return Center(
      child: Column(
        children: [
          NeuSurface(
            accent: true,
            width: 88,
            height: 88,
            radius: NeuRadius.nav,
            child: Icon(
              Icons.chat_bubble_rounded,
              size: 40,
              color: colors.onAccent,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Matter',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: NeuSpacing.sm),
          Text('Matrix 客户端', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _buildModeChips() {
    const labels = ['登录', '注册', 'Token'];
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

  Widget _buildFormCard() {
    return NeuSurface(
      radius: NeuRadius.surface,
      color: context.neu.surfaceStrong,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLabel('Homeserver'),
          const SizedBox(height: NeuSpacing.sm),
          _buildHomeserverField(),
          if (_tabIndex == 0) ..._buildLoginFields(),
          if (_tabIndex == 1) ..._buildRegisterFields(),
          if (_tabIndex == 2) ..._buildTokenLoginFields(),
          if (_error != null) ...[
            const SizedBox(height: NeuSpacing.md),
            _buildErrorBanner(),
          ],
          const SizedBox(height: 22),
          _buildActionButton(),
        ],
      ),
    );
  }

  Widget _buildHomeserverField() {
    return NeuTextField(
      controller: _homeserverController,
      hint: 'matrix.org',
      leading: const Icon(Icons.dns_rounded),
      trailing: NeuIconButton(
        size: 32,
        icon: Icons.unfold_more_rounded,
        tooltip: '选择预设服务器',
        onPressed: _homeservers.isEmpty ? null : _showHomeserverSheet,
      ),
      textInputAction: TextInputAction.next,
      onChanged: (_) => _clearError(),
    );
  }

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
          for (final entry in _homeservers)
            NeuSheetItem(
              icon: Icons.dns_rounded,
              label: entry.label,
              trailing: _buildHomeserverTrailing(entry),
              onTap: () => Navigator.of(context).pop(entry),
            ),
          const SizedBox(height: NeuSpacing.sm),
        ],
      ),
    );

    if (selected != null && mounted) {
      _homeserverController.text = selected.domain;
      _clearError();
    }
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

  List<Widget> _buildLoginFields() {
    return [
      _buildLabel('用户名'),
      const SizedBox(height: NeuSpacing.sm),
      NeuTextField(
        controller: _usernameController,
        hint: 'username',
        leading: const Icon(Icons.person_outline_rounded),
        textInputAction: TextInputAction.next,
        onChanged: (_) => _clearError(),
      ),
      const SizedBox(height: NeuSpacing.lg),
      _buildLabel('密码'),
      const SizedBox(height: NeuSpacing.sm),
      NeuTextField(
        controller: _passwordController,
        hint: '你的密码',
        leading: const Icon(Icons.lock_outline_rounded),
        obscureText: !_isPasswordVisible,
        trailing: _buildPasswordToggle(),
        textInputAction: TextInputAction.done,
        onChanged: (_) => _clearError(),
        onSubmitted: (_) => _login(),
      ),
    ];
  }

  List<Widget> _buildRegisterFields() {
    return [
      _buildLabel('用户名'),
      const SizedBox(height: NeuSpacing.sm),
      NeuTextField(
        controller: _usernameController,
        hint: 'username (不含 @ 和域名)',
        leading: const Icon(Icons.person_outline_rounded),
        textInputAction: TextInputAction.next,
        onChanged: (_) => _clearError(),
      ),
      const SizedBox(height: NeuSpacing.lg),
      _buildLabel('密码'),
      const SizedBox(height: NeuSpacing.sm),
      NeuTextField(
        controller: _passwordController,
        hint: '你的密码',
        leading: const Icon(Icons.lock_outline_rounded),
        obscureText: !_isPasswordVisible,
        trailing: _buildPasswordToggle(),
        textInputAction: _uiaaSession != null
            ? TextInputAction.next
            : TextInputAction.done,
        onChanged: (_) => _clearError(),
        onSubmitted: _uiaaSession == null ? (_) => _register() : null,
      ),
      if (_uiaaSession != null) ...[
        const SizedBox(height: NeuSpacing.lg),
        _buildLabel('注册 Token'),
        const SizedBox(height: NeuSpacing.sm),
        NeuTextField(
          controller: _tokenController,
          hint: '输入服务器要求的注册 Token',
          leading: const Icon(Icons.vpn_key_rounded),
          textInputAction: TextInputAction.done,
          onChanged: (_) => _clearError(),
          onSubmitted: (_) => _register(),
        ),
      ],
    ];
  }

  List<Widget> _buildTokenLoginFields() {
    return [
      _buildLabel('User ID'),
      const SizedBox(height: NeuSpacing.sm),
      NeuTextField(
        controller: _userIdController,
        hint: '@user:matrix.local',
        leading: const Icon(Icons.person_outline_rounded),
        textInputAction: TextInputAction.next,
        onChanged: (_) => _clearError(),
      ),
      const SizedBox(height: NeuSpacing.lg),
      _buildLabel('Device ID'),
      const SizedBox(height: NeuSpacing.sm),
      NeuTextField(
        controller: _deviceIdController,
        hint: 'MATTER (可选)',
        leading: const Icon(Icons.devices_rounded),
        textInputAction: TextInputAction.next,
        onChanged: (_) => _clearError(),
      ),
      const SizedBox(height: NeuSpacing.lg),
      _buildLabel('Access Token'),
      const SizedBox(height: NeuSpacing.sm),
      NeuTextField(
        controller: _accessTokenController,
        hint: '你的 Access Token',
        leading: const Icon(Icons.key_rounded),
        textInputAction: TextInputAction.done,
        onChanged: (_) => _clearError(),
        onSubmitted: (_) => _loginWithAccessToken(),
      ),
    ];
  }

  Widget _buildPasswordToggle() {
    return NeuIconButton(
      size: 32,
      icon: _isPasswordVisible
          ? Icons.visibility_off_rounded
          : Icons.visibility_rounded,
      onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible),
    );
  }

  Widget _buildErrorBanner() {
    final colors = context.neu;
    return NeuSurface(
      depth: NeuDepth.flat,
      radius: NeuRadius.content,
      color: colors.error.withValues(alpha: .12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: colors.error, size: 18),
          const SizedBox(width: NeuSpacing.sm),
          Expanded(
            child: Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.error),
            ),
          ),
          const SizedBox(width: NeuSpacing.sm),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              Clipboard.setData(ClipboardData(text: _error!));
              neuToast(context, '已复制到剪贴板');
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                '复制',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    final colors = context.neu;
    final label = switch (_tabIndex) {
      0 => '登录',
      1 => _uiaaSession != null ? '完成注册' : '注册',
      2 => 'Token 登录',
      _ => '',
    };

    final onPressed = _isLoading
        ? null
        : switch (_tabIndex) {
            0 => _login,
            1 => _register,
            2 => _loginWithAccessToken,
            _ => () {},
          };

    return SizedBox(
      width: double.infinity,
      child: NeuButton(
        accent: true,
        padding: const EdgeInsets.symmetric(vertical: 15),
        onPressed: onPressed,
        child: _isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: colors.onAccent,
                  strokeWidth: 2.5,
                ),
              )
            : Text(label),
      ),
    );
  }

  Widget _buildFooter() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(
          'Made with AI by Matter Team',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(text, style: Theme.of(context).textTheme.titleSmall);
  }
}
