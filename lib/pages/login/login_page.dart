import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _homeserverController = TextEditingController(
    text: 'http://10.0.2.2:8008',
  );
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _tokenController = TextEditingController(); // registration token
  final _accessTokenController = TextEditingController(); // access token login
  final _userIdController = TextEditingController(); // for access token login
  final _deviceIdController = TextEditingController(); // for access token login

  bool _isPasswordVisible = false;
  bool _isLoading = false;
  String? _error;

  // UIAA state for registration
  String? _uiaaSession;

  // Tab state: 0 = login, 1 = register, 2 = token login
  int _tabIndex = 0;

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

  void _onAuthSuccess(String userId, String displayName) {
    ref.read(isLoggedInProvider.notifier).state = true;
    ref.read(currentUserProvider.notifier).state = CurrentUser(
      id: userId,
      displayName: displayName,
      homeserver: _homeserverController.text,
    );
    ref.read(homeserverProvider.notifier).state = _homeserverController.text;

    // Trigger initial sync in background after login
    _initialSync();
  }

  Future<void> _initialSync() async {
    try {
      await rust.syncOnce();
      // Invalidate chat rooms provider so it refetches with real data
      ref.invalidate(chatRoomsProvider);
    } catch (e) {
      debugPrint('Initial sync failed: $e');
    }
  }

  Future<void> _login() async {
    _clearError();
    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      return;
    }

    setState(() => _isLoading = true);
    try {
      await rust.createClient(homeserverUrl: _homeserverController.text);
      final result = await rust.loginWithPassword(
        username: _usernameController.text,
        password: _passwordController.text,
      );
      if (result.success) {
        _onAuthSuccess(result.userId ?? '', _usernameController.text);
      } else if (mounted) {
        setState(() => _error = result.error ?? '登录失败');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
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
      await rust.createClient(homeserverUrl: _homeserverController.text);

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
        _onAuthSuccess(result.userId ?? '', _usernameController.text);
      } else if (mounted) {
        setState(() => _error = result.error ?? '注册失败');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
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
      await rust.createClient(homeserverUrl: _homeserverController.text);
      final result = await rust.loginWithToken(
        accessToken: _accessTokenController.text,
        userId: _userIdController.text,
        deviceId: _deviceIdController.text.isEmpty
            ? 'MATTER'
            : _deviceIdController.text,
      );
      if (result.success) {
        final userId = result.userId ?? _userIdController.text;
        _onAuthSuccess(userId, userId.split(':').first.replaceFirst('@', ''));
      } else if (mounted) {
        setState(() => _error = result.error ?? 'Token 登录失败');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
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
        _buildTextField(
          controller: _homeserverController,
          hintText: 'http://10.0.2.2:8008',
          prefixIcon: Icons.dns_rounded,
          textInputAction: TextInputAction.next,
        ),
      ],
    );
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
        hintText: '@user:tuwunel.local',
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
          'Powered by Matrix · Tuwunel',
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
