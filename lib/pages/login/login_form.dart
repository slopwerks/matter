import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

/// Shared authentication inputs. Controllers and auth callbacks belong to the host.
class LoginForm extends StatelessWidget {
  const LoginForm({
    super.key,
    required this.mode,
    required this.homeserver,
    required this.username,
    required this.password,
    required this.registrationToken,
    required this.userId,
    required this.deviceId,
    required this.accessToken,
    required this.passwordVisible,
    required this.registrationTokenRequired,
    required this.loading,
    required this.error,
    required this.onChanged,
    required this.onTogglePassword,
    required this.onChooseHomeserver,
    required this.onSubmit,
  });

  final int mode;
  final TextEditingController homeserver;
  final TextEditingController username;
  final TextEditingController password;
  final TextEditingController registrationToken;
  final TextEditingController userId;
  final TextEditingController deviceId;
  final TextEditingController accessToken;
  final bool passwordVisible;
  final bool registrationTokenRequired;
  final bool loading;
  final String? error;
  final VoidCallback onChanged;
  final VoidCallback onTogglePassword;
  final VoidCallback? onChooseHomeserver;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _field(
          context,
          label: 'Homeserver',
          controller: homeserver,
          hint: 'matrix.org',
          icon: Icons.dns_rounded,
          first: true,
          neuGap: false,
          trailing: NeuIconButton(
            size: 32,
            icon: Icons.unfold_more_rounded,
            tooltip: '选择预设服务器',
            onPressed: onChooseHomeserver,
          ),
        ),
        if (mode == 0 || mode == 1) ...[
          _field(
            context,
            label: '用户名',
            controller: username,
            hint: mode == 1 ? 'username (不含 @ 和域名)' : 'username',
            icon: Icons.person_outline_rounded,
            neuGap: false,
          ),
          _field(
            context,
            label: '密码',
            controller: password,
            hint: '你的密码',
            icon: Icons.lock_outline_rounded,
            obscureText: !passwordVisible,
            trailing: NeuIconButton(
              size: 32,
              icon: passwordVisible
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              onPressed: onTogglePassword,
            ),
            textInputAction: mode == 1 && registrationTokenRequired
                ? TextInputAction.next
                : TextInputAction.done,
            onSubmitted: mode == 1 && registrationTokenRequired
                ? null
                : (_) => onSubmit(),
          ),
          if (mode == 1 && registrationTokenRequired)
            _field(
              context,
              label: '注册 Token',
              controller: registrationToken,
              hint: '输入服务器要求的注册 Token',
              icon: Icons.vpn_key_rounded,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onSubmit(),
            ),
        ],
        if (mode == 2) ...[
          _field(
            context,
            label: 'User ID',
            controller: userId,
            hint: '@user:matrix.local',
            icon: Icons.person_outline_rounded,
            neuGap: false,
          ),
          _field(
            context,
            label: 'Device ID',
            controller: deviceId,
            hint: 'MATTER (可选)',
            icon: Icons.devices_rounded,
          ),
          _field(
            context,
            label: 'Access Token',
            controller: accessToken,
            hint: '你的 Access Token',
            icon: Icons.key_rounded,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmit(),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: NeuSpacing.md),
          _errorBanner(context),
        ],
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: NeuButton(
            accent: true,
            padding: const EdgeInsets.symmetric(vertical: 15),
            onPressed: loading ? null : onSubmit,
            child: loading
                ? SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      color: context.neu.onAccent,
                      strokeWidth: 2.5,
                    ),
                  )
                : Text(switch (mode) {
                    0 => '登录',
                    1 => registrationTokenRequired ? '完成注册' : '注册',
                    2 => 'Token 登录',
                    _ => '',
                  }),
          ),
        ),
      ],
    );
    if (context.isMaterial) {
      return MaterialDetailCard(
        title: switch (mode) {
          1 => '创建账号',
          2 => 'Token 登录',
          _ => '欢迎回来',
        },
        description: switch (mode) {
          1 =>
            registrationTokenRequired
                ? '服务器要求注册 Token，请填写后完成注册。'
                : '在所选服务器创建账号，按服务器要求完成验证。',
          2 => '使用已有会话的 User ID 和 Access Token 登录。',
          _ => '填写账号所属服务器，以及用户名和密码。',
        },
        child: content,
      );
    }
    return NeuSurface(
      radius: NeuRadius.surface,
      color: context.neu.surfaceStrong,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      child: content,
    );
  }

  Widget _field(
    BuildContext context, {
    required String label,
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool first = false,
    bool neuGap = true,
    bool obscureText = false,
    Widget? trailing,
    TextInputAction textInputAction = TextInputAction.next,
    ValueChanged<String>? onSubmitted,
  }) {
    if (context.isMaterial) {
      return Padding(
        padding: EdgeInsets.only(top: first ? 0 : 16),
        child: TextField(
          controller: controller,
          obscureText: obscureText,
          textInputAction: textInputAction,
          onChanged: (_) => onChanged(),
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            prefixIcon: Icon(icon),
            suffixIcon: trailing,
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: neuGap ? NeuSpacing.lg : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: NeuSpacing.sm),
          NeuTextField(
            controller: controller,
            hint: hint,
            leading: Icon(icon),
            trailing: trailing,
            obscureText: obscureText,
            textInputAction: textInputAction,
            onChanged: (_) => onChanged(),
            onSubmitted: onSubmitted,
          ),
        ],
      ),
    );
  }

  void _copyError(BuildContext context) {
    Clipboard.setData(ClipboardData(text: error!));
    neuToast(context, '已复制到剪贴板');
  }

  Widget _errorBanner(BuildContext context) {
    if (context.isMaterial) {
      final style = materialAuthStyle(Theme.of(context));
      return Semantics(
        liveRegion: true,
        child: Card(
          color: style.errorFill,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, color: style.errorForeground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error!,
                    style: TextStyle(color: style.errorForeground),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: style.errorForeground,
                  ),
                  onPressed: () => _copyError(context),
                  child: const Text('复制'),
                ),
              ],
            ),
          ),
        ),
      );
    }
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
              error!,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.error),
            ),
          ),
          const SizedBox(width: NeuSpacing.sm),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _copyError(context),
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
}
