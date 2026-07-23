import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/max_content_width.dart';
import 'homeserver_list.dart';
import 'homeserver_resolver.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _homeserverController = TextEditingController();
  final _homeserverFieldKey = GlobalKey();
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

  Future<void> _onAuthSuccess(String userId, String displayName) async {
    // Keep API-backed providers gated until the new crypto store has completed
    // its first sync. Querying rooms while that sync initializes can leave the
    // first room-list request waiting on the store until the app is restarted.
    ref.read(sessionReadyProvider.notifier).value = false;
    await applyActiveSessionState(
      ref,
      userId: userId,
      displayName: displayName,
      homeserver: _effectiveHomeserver,
      markLoggedIn: false,
    );

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
    if (session != null) {
      await persistSession(
        homeserver: _effectiveHomeserver,
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        userId: session.userId,
        deviceId: session.deviceId,
        displayName: displayName,
      );
      await applyActiveSessionState(
        ref,
        userId: session.userId,
        displayName: displayName,
        homeserver: _effectiveHomeserver,
        refreshStoredSessions: true,
        markLoggedIn: false,
      );
    }
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
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('不安全的连接'),
        content: Text(
          '该服务器（${resolved.url}）仅支持未加密的 HTTP 连接。\n\n'
          '你的密码和登录凭证将以明文传输，可能被同一网络中的第三方截获。\n\n'
          '确定要继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续登录'),
          ),
        ],
      ),
    ).then((v) => v ?? false);
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
      await rust.createClient(
        homeserverUrl: homeserverUrl,
        dataDir: await _getDataDir(),
      );
      final result = await rust.loginWithPassword(
        username: _usernameController.text,
        password: _passwordController.text,
      );
      if (result.success) {
        await _onAuthSuccess(result.userId ?? '', _usernameController.text);
      } else if (mounted) {
        _setFriendlyError('登录失败，请稍后重试', result.error);
      }
    } catch (e) {
      _setFriendlyError('登录失败，请稍后重试', e);
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
      await rust.createClient(
        homeserverUrl: homeserverUrl,
        dataDir: await _getDataDir(),
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
        await _onAuthSuccess(result.userId ?? '', _usernameController.text);
      } else if (mounted) {
        _setFriendlyError('注册失败，请稍后重试', result.error);
      }
    } catch (e) {
      _setFriendlyError('注册失败，请稍后重试', e);
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
      await rust.createClient(
        homeserverUrl: homeserverUrl,
        dataDir: await _getDataDir(),
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
        final userId = result.userId ?? _userIdController.text;
        await _onAuthSuccess(
          userId,
          userId.split(':').first.replaceFirst('@', ''),
        );
      } else if (mounted) {
        _setFriendlyError('Token 登录失败，请检查输入信息', result.error);
      }
    } catch (e) {
      _setFriendlyError('Token 登录失败，请检查输入信息', e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: MaxContentWidth(
                maxWidth: 440,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 40),
                      _buildHeader(),
                      const SizedBox(height: 32),
                      _buildTabs(),
                      const SizedBox(height: 24),
                      _buildHomeserverField(),
                      const SizedBox(height: 20),
                      if (_tabIndex == 0) ..._buildLoginFields(),
                      if (_tabIndex == 1) ..._buildRegisterFields(),
                      if (_tabIndex == 2) ..._buildTokenLoginFields(),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        _buildErrorBanner(),
                      ],
                      const SizedBox(height: 24),
                      _buildActionButton(),
                      const Spacer(),
                      _buildFooter(),
                    ],
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
    return Center(
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadii.content),
            ),
            child: const Icon(
              Icons.chat_bubble_rounded,
              color: AppColors.primary,
              size: 36,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Matter',
            style: TextStyle(
              color: AppColors.onBackground,
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Matrix 客户端',
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: Row(
        children: [
          _buildTab('登录', 0),
          _buildTab('注册', 1),
          _buildTab('Token', 2),
        ],
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final isActive = _tabIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _tabIndex = index;
            _uiaaSession = null;
            _clearError();
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isActive ? Colors.white : AppColors.onSurfaceVariant,
              fontSize: 14,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeserverField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel('Homeserver'),
        const SizedBox(height: 8),
        Builder(
          key: _homeserverFieldKey,
          builder: (_) => _buildTextField(
            controller: _homeserverController,
            hintText: 'matrix.org',
            prefixIcon: Icons.dns_rounded,
            suffixIcon: IconButton(
              icon: const Icon(
                Icons.arrow_drop_down_rounded,
                color: AppColors.onSurfaceVariant,
              ),
              tooltip: '选择预设服务器',
              onPressed: _homeservers.isEmpty ? null : _showHomeserverDropdown,
            ),
            textInputAction: TextInputAction.next,
          ),
        ),
      ],
    );
  }

  /// Open the preset-server dropdown below the homeserver field. Triggered by
  /// the trailing arrow button only — focusing the field stays a pure typing
  /// gesture and never opens this menu.
  Future<void> _showHomeserverDropdown() async {
    final fieldContext = _homeserverFieldKey.currentContext;
    if (fieldContext == null) return;
    final renderBox = fieldContext.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final overlay =
        Overlay.of(fieldContext).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final size = renderBox.size;
    final topLeft = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomLeft = renderBox.localToGlobal(
      Offset(0, size.height),
      ancestor: overlay,
    );
    final position = RelativeRect.fromLTRB(
      topLeft.dx,
      bottomLeft.dy,
      overlay.size.width - topLeft.dx - size.width,
      0,
    );

    final selected = await showMenu<HomeserverEntry>(
      context: fieldContext,
      position: position,
      constraints: BoxConstraints(minWidth: size.width, maxWidth: size.width),
      items: [
        for (final entry in _homeservers)
          PopupMenuItem<HomeserverEntry>(
            value: entry,
            child: Row(
              children: [
                Icon(
                  Icons.dns_rounded,
                  size: 18,
                  color: AppColors.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.label,
                        style: const TextStyle(
                          color: AppColors.onSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (entry.domain != entry.label)
                        Text(
                          entry.domain,
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                ),
                if (entry.domain.toLowerCase() ==
                    _homeserverController.text.trim().toLowerCase())
                  const Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
              ],
            ),
          ),
      ],
    );

    if (selected != null && mounted) {
      _homeserverController.text = selected.domain;
      _clearError();
    }
  }

  List<Widget> _buildLoginFields() {
    return [
      _buildLabel('用户名'),
      const SizedBox(height: 8),
      _buildTextField(
        controller: _usernameController,
        hintText: 'username',
        prefixIcon: Icons.person_outline_rounded,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 20),
      _buildLabel('密码'),
      const SizedBox(height: 8),
      _buildTextField(
        controller: _passwordController,
        hintText: '你的密码',
        prefixIcon: Icons.lock_outline_rounded,
        obscureText: !_isPasswordVisible,
        suffixIcon: IconButton(
          icon: Icon(
            _isPasswordVisible
                ? Icons.visibility_off_rounded
                : Icons.visibility_rounded,
            color: AppColors.onSurfaceVariant,
            size: 20,
          ),
          onPressed: () =>
              setState(() => _isPasswordVisible = !_isPasswordVisible),
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _login(),
      ),
    ];
  }

  List<Widget> _buildRegisterFields() {
    return [
      _buildLabel('用户名'),
      const SizedBox(height: 8),
      _buildTextField(
        controller: _usernameController,
        hintText: 'username (不含 @ 和域名)',
        prefixIcon: Icons.person_outline_rounded,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 20),
      _buildLabel('密码'),
      const SizedBox(height: 8),
      _buildTextField(
        controller: _passwordController,
        hintText: '你的密码',
        prefixIcon: Icons.lock_outline_rounded,
        obscureText: !_isPasswordVisible,
        suffixIcon: IconButton(
          icon: Icon(
            _isPasswordVisible
                ? Icons.visibility_off_rounded
                : Icons.visibility_rounded,
            color: AppColors.onSurfaceVariant,
            size: 20,
          ),
          onPressed: () =>
              setState(() => _isPasswordVisible = !_isPasswordVisible),
        ),
        textInputAction: _uiaaSession != null
            ? TextInputAction.next
            : TextInputAction.done,
        onSubmitted: _uiaaSession == null ? (_) => _register() : null,
      ),
      if (_uiaaSession != null) ...[
        const SizedBox(height: 20),
        _buildLabel('注册 Token'),
        const SizedBox(height: 8),
        _buildTextField(
          controller: _tokenController,
          hintText: '输入服务器要求的注册 Token',
          prefixIcon: Icons.vpn_key_rounded,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _register(),
        ),
      ],
    ];
  }

  List<Widget> _buildTokenLoginFields() {
    return [
      _buildLabel('User ID'),
      const SizedBox(height: 8),
      _buildTextField(
        controller: _userIdController,
        hintText: '@user:matrix.local',
        prefixIcon: Icons.person_outline_rounded,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 20),
      _buildLabel('Device ID'),
      const SizedBox(height: 8),
      _buildTextField(
        controller: _deviceIdController,
        hintText: 'MATTER (可选)',
        prefixIcon: Icons.devices_rounded,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 20),
      _buildLabel('Access Token'),
      const SizedBox(height: 8),
      _buildTextField(
        controller: _accessTokenController,
        hintText: '你的 Access Token',
        prefixIcon: Icons.key_rounded,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _loginWithAccessToken(),
      ),
    ];
  }

  Widget _buildErrorBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.red, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: _error!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制到剪贴板'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                '复制',
                style: TextStyle(
                  color: Colors.red,
                  fontSize: 12,
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
      height: 52,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          padding: EdgeInsets.zero,
        ),
        child: _isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              )
            : Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }

  Widget _buildFooter() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(
          'Made with AI by Matter Team',
          style: TextStyle(
            color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.onSurface,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    required IconData prefixIcon,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputAction? textInputAction,
    void Function(String)? onSubmitted,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        onChanged: (_) => _clearError(),
        style: const TextStyle(color: AppColors.onBackground, fontSize: 15),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: const TextStyle(
            color: AppColors.onSurfaceVariant,
            fontSize: 15,
          ),
          prefixIcon: Icon(
            prefixIcon,
            color: AppColors.onSurfaceVariant,
            size: 20,
          ),
          suffixIcon: suffixIcon,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          isDense: true,
        ),
      ),
    );
  }
}
