import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/push/fcm_push_runtime.dart';
import '../../features/push/firebase_client_config.dart';
import '../../features/push/push_providers.dart';
import '../../features/push/push_runtime.dart';
import '../../features/push/push_settings.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_visual_settings_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/glass.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

class NotificationSettingsPage extends ConsumerStatefulWidget {
  const NotificationSettingsPage({super.key, required this.userId});
  final String userId;

  @override
  ConsumerState<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState
    extends ConsumerState<NotificationSettingsPage> {
  final _form = GlobalKey<FormState>();
  final _gateway = TextEditingController();
  final _appId = TextEditingController();
  final _vapid = TextEditingController();
  bool _loaded = false;
  bool _enabled = false;
  bool _busy = false;
  PushBackend _backend = PushBackend.android;
  String? _error;

  @override
  void dispose() {
    _gateway.dispose();
    _appId.dispose();
    _vapid.dispose();
    super.dispose();
  }

  Future<void> _importFirebase() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'google-services.json',
            extensions: ['json'],
            mimeTypes: ['application/json'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final config = FirebaseClientConfig.fromGoogleServices(
        await file.readAsString(),
      );
      if (!mounted) return;
      final previous = ref.read(firebaseClientConfigProvider).asData?.value;
      if (previous != null && previous.matches(config)) return;
      final manager = ref.read(pushRegistrationManagerProvider);
      // Preserve the gateway draft across the required process restart. A
      // blank field must never overwrite an existing value with an empty one.
      final current = await manager.store.load(widget.userId);
      if (!mounted) return;
      await manager.configure(
        widget.userId,
        enabled: false,
        gatewayUrl: _gateway.text.isNotEmpty
            ? _gateway.text
            : current.gatewayUrl,
        appId: _appId.text.isNotEmpty ? _appId.text : current.appId,
        backend: _backend,
        vapidPublicKey: _vapid.text.isNotEmpty
            ? _vapid.text
            : current.vapidPublicKey,
      );
      await manager.changeFcmConfiguration(() async {
        await fcmPushRuntime.retireToken();
        await FirebaseClientConfigStore().save(config);
        fcmPushRuntime.configurationChanged = true;
      });
      if (mounted) {
        ref.invalidate(firebaseClientConfigProvider);
        ref.invalidate(pushSettingsProvider(widget.userId));
        setState(() => _enabled = false);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        ref.invalidate(pushSettingsProvider(widget.userId));
        final settings = await PushSettingsStore().load(widget.userId);
        if (mounted) {
          setState(() {
            _enabled = settings.enabled;
            _busy = false;
          });
        }
      }
    }
  }

  Future<void> _save(bool enabled) async {
    if (enabled) {
      final error =
          validatePushGateway(_gateway.text) ??
          validatePushAppId(_appId.text) ??
          (_backend == PushBackend.web
              ? validateVapidPublicKey(_vapid.text)
              : null);
      if (error != null) {
        _form.currentState!.validate();
        setState(() => _error = error);
        return;
      }
    }
    final manager = ref.read(pushRegistrationManagerProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (enabled) await requestPushPermission(_backend);
      await manager.configure(
        widget.userId,
        enabled: enabled,
        gatewayUrl: _gateway.text,
        appId: _appId.text,
        backend: _backend,
        vapidPublicKey: _vapid.text,
      );
      if (mounted) {
        ref
            .read(pushRegistrationErrorProvider.notifier)
            .setError(widget.userId, null);
        neuToast(context, enabled ? '推送已注册' : '推送已关闭');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        ref.invalidate(pushSettingsProvider(widget.userId));
        final settings = await PushSettingsStore().load(widget.userId);
        if (mounted) {
          setState(() {
            _enabled = settings.enabled;
            _busy = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
    final firebaseConfig = fcmPushSupported
        ? ref.watch(firebaseClientConfigProvider)
        : null;
    final configured =
        _backend == PushBackend.web ||
        (firebaseConfig?.asData?.value != null &&
            !fcmPushRuntime.configurationChanged);
    final settings = ref.watch(pushSettingsProvider(widget.userId));
    final registrationError = ref.watch(
      pushRegistrationErrorProvider,
    )[widget.userId];

    return Scaffold(
      backgroundColor: colors.base,
      body: Stack(
        children: [
          Positioned.fill(
            child: settings.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(NeuSpacing.lg),
                  child: Text('读取推送设置失败：$error'),
                ),
              ),
              data: (value) {
                if (!_loaded) {
                  _loaded = true;
                  _enabled = value.enabled;
                  _backend = value.backend;
                  _gateway.text = value.gatewayUrl;
                  _appId.text = value.appId;
                  _vapid.text = value.vapidPublicKey;
                }
                return MaxContentWidth(
                  child: Form(
                    key: _form,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        NeuSpacing.lg,
                        viewPaddingTop + kToolbarHeight + NeuSpacing.sm,
                        NeuSpacing.lg,
                        NeuSpacing.xl * 2,
                      ),
                      children: [
                        _buildOverview(
                          context: context,
                          settings: value,
                          registrationError: registrationError,
                        ),
                        const SizedBox(height: NeuSpacing.xl),
                        if (pushSupported) ...[
                          if (fcmPushSupported) ...[
                            const SizedBox(height: NeuSpacing.xl),
                            const _SectionTitle(
                              'Firebase 凭据',
                              subtitle: '用于 Android 客户端连接 Google FCM 推送服务',
                            ),
                            _buildFirebaseCard(
                              context: context,
                              firebaseConfig: firebaseConfig,
                            ),
                          ],
                          const SizedBox(height: NeuSpacing.xl),
                          const _SectionTitle(
                            '推送配置',
                            subtitle: '选择推送通道，填写网关地址与应用标识',
                          ),
                          _buildConfigCard(context: context),
                          const SizedBox(height: NeuSpacing.xl),
                          _buildActions(
                            context: context,
                            configured: configured,
                            settings: value,
                          ),
                        ] else ...[
                          const SizedBox(height: NeuSpacing.xl),
                          const _SectionTitle(
                            '接入方式',
                            subtitle: '选择当前设备使用的消息推送通道',
                          ),
                          NeuSurface(
                            color: colors.card,
                            radius: NeuRadius.surface,
                            padding: const EdgeInsets.all(NeuSpacing.lg),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildBackendDropdown(context),
                                const SizedBox(height: NeuSpacing.md),
                                _NoticeBar(
                                  tone: _NoticeTone.info,
                                  title: '此平台暂不支持消息推送',
                                  body:
                                      'Android 使用 FCM，浏览器使用 Web Push；当前平台两者均不可用。',
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: NeuSpacing.xl),
                        const _SectionTitle('使用说明'),
                        _buildHelpCard(context: context),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: viewPaddingTop + kToolbarHeight,
            child: const TopFadeBlur(useShader: true),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: kToolbarHeight,
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: NeuSpacing.sm,
                    right: NeuSpacing.md,
                  ),
                  child: Row(
                    children: [
                      NeuIconButton(
                        icon: Icons.arrow_back_ios_new_rounded,
                        size: 40,
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: NeuSpacing.sm),
                      Expanded(
                        child: Text(
                          '通知',
                          style: textTheme.titleLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverview({
    required BuildContext context,
    required PushSettings settings,
    required String? registrationError,
  }) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final activeError = _error ?? registrationError;
    final currentUser = ref.watch(currentUserProvider);

    return NeuSurface(
      color: colors.card,
      radius: NeuRadius.surface,
      padding: const EdgeInsets.all(NeuSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (currentUser != null && currentUser.id == widget.userId)
                AppAvatar(
                  fallback: currentUser.displayName,
                  url: currentUser.avatarUrl,
                  size: 48,
                )
              else
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _enabled
                        ? colors.accent.withValues(alpha: 0.15)
                        : colors.surface,
                  ),
                  child: Icon(
                    _enabled
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_off_rounded,
                    color: _enabled ? colors.accent : colors.textSecondary,
                    size: 24,
                  ),
                ),
              const SizedBox(width: NeuSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _enabled ? '推送已启用' : '推送未启用',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: NeuSpacing.sm),
                        NeuSurface(
                          depth: NeuDepth.flat,
                          color: _enabled ? colors.accentSoft : colors.surface,
                          radius: NeuRadius.tag,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          child: Text(
                            _enabled ? '已注册' : '待配置',
                            style: textTheme.labelSmall?.copyWith(
                              color: _enabled
                                  ? colors.accent
                                  : colors.textTertiary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.userId,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: NeuSpacing.md),
          Text(
            _enabled
                ? '收到新消息时将在应用后台或关闭后通过系统通知提醒；通知不显示消息正文。'
                : '网关设置仅对当前账号生效；开启后可在应用后台或关闭时接收消息推送。',
            style: textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          if (activeError != null) ...[
            const SizedBox(height: NeuSpacing.md),
            _NoticeBar(tone: _NoticeTone.error, body: activeError),
          ],
        ],
      ),
    );
  }

  Widget _buildBackendDropdown(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return NeuSurface(
      depth: NeuDepth.pressed,
      color: colors.card,
      radius: NeuRadius.content,
      intensity: .85,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: DropdownButtonFormField<PushBackend>(
        initialValue: _backend,
        dropdownColor: colors.card,
        borderRadius: BorderRadius.circular(NeuRadius.button),
        icon: Icon(
          Icons.unfold_more_rounded,
          color: colors.textSecondary,
          size: 20,
        ),
        isExpanded: true,
        style: textTheme.bodyMedium?.copyWith(
          color: colors.text,
          fontWeight: FontWeight.w500,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 10),
        ),
        items: [
          DropdownMenuItem(
            value: PushBackend.web,
            enabled: supportsPushBackend(PushBackend.web),
            child: Row(
              children: [
                Icon(
                  Icons.language_rounded,
                  size: 18,
                  color: supportsPushBackend(PushBackend.web)
                      ? colors.accent
                      : colors.textTertiary,
                ),
                const SizedBox(width: 10),
                const Text('Web Push（浏览器）'),
              ],
            ),
          ),
          DropdownMenuItem(
            value: PushBackend.android,
            enabled: supportsPushBackend(PushBackend.android),
            child: Row(
              children: [
                Icon(
                  Icons.phone_android_rounded,
                  size: 18,
                  color: supportsPushBackend(PushBackend.android)
                      ? colors.accent
                      : colors.textTertiary,
                ),
                const SizedBox(width: 10),
                const Text('Flutter / Android（FCM）'),
              ],
            ),
          ),
        ],
        onChanged: _busy || !pushSupported
            ? null
            : (backend) {
                if (backend != null) {
                  setState(() => _backend = backend);
                }
              },
      ),
    );
  }

  Widget _buildFirebaseCard({
    required BuildContext context,
    required AsyncValue<FirebaseClientConfig?>? firebaseConfig,
  }) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final isConfigured = firebaseConfig?.asData?.value != null;
    final project = firebaseConfig?.asData?.value;

    return NeuSurface(
      color: colors.card,
      radius: NeuRadius.surface,
      padding: const EdgeInsets.all(NeuSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(NeuSpacing.md),
            decoration: BoxDecoration(
              color: isConfigured
                  ? colors.success.withValues(alpha: 0.08)
                  : colors.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(NeuRadius.content),
              border: Border.all(
                color: isConfigured
                    ? colors.success.withValues(alpha: 0.25)
                    : colors.warning.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isConfigured
                        ? colors.success.withValues(alpha: 0.15)
                        : colors.warning.withValues(alpha: 0.15),
                  ),
                  child: Icon(
                    isConfigured
                        ? Icons.cloud_done_rounded
                        : Icons.warning_amber_rounded,
                    size: 20,
                    color: isConfigured ? colors.success : colors.warning,
                  ),
                ),
                const SizedBox(width: NeuSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isConfigured
                            ? 'Firebase 项目：${project!.projectId}'
                            : '请导入你自己的 Android google-services.json',
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        isConfigured
                            ? '已成功载入客户端配置，可连接 Google FCM 接收通知'
                            : '尚未配置 Firebase 项目，暂不可启用 Android 推送',
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: NeuSpacing.md),
          SizedBox(
            width: double.infinity,
            child: NeuButton(
              onPressed: _busy ? null : _importFirebase,
              icon: const Icon(Icons.file_upload_outlined, size: 18),
              child: const Center(child: Text('导入 google-services.json')),
            ),
          ),
          const SizedBox(height: NeuSpacing.sm),
          Text(
            'Firebase 项目由此安装的所有账号共享。更换项目会关闭并注销所有 Android 推送。',
            style: textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          if (fcmPushRuntime.configurationChanged) ...[
            const SizedBox(height: NeuSpacing.md),
            const _NoticeBar(
              tone: _NoticeTone.warning,
              title: '需要重启应用',
              body: '新配置已保存，请在系统设置中强行停止 Matter 后重新打开，再启用推送。',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildConfigCard({required BuildContext context}) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return NeuSurface(
      color: colors.card,
      radius: NeuRadius.surface,
      padding: const EdgeInsets.all(NeuSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _backend == PushBackend.web
                    ? Icons.language_rounded
                    : Icons.phone_android_rounded,
                size: 16,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                '接入方式',
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: NeuSpacing.sm),
          _buildBackendDropdown(context),
          const SizedBox(height: NeuSpacing.lg),
          Divider(height: 1, color: colors.hairline),
          const SizedBox(height: NeuSpacing.lg),
          _buildFormField(
            context: context,
            label: '推送网关 URL',
            controller: _gateway,
            hintText: 'https://你的网关/_matrix/push/v1/notify',
            icon: Icons.link_rounded,
            keyboardType: TextInputType.url,
            helperText: '须为 HTTPS 地址',
            validator: (value) => validatePushGateway(value ?? ''),
          ),
          const SizedBox(height: NeuSpacing.lg),
          _buildFormField(
            context: context,
            label: '应用 ID',
            controller: _appId,
            hintText: '例如 matter.android',
            icon: Icons.badge_outlined,
            helperText: '须与网关配置中的应用 ID 一致',
            validator: (value) => validatePushAppId(value ?? ''),
          ),
          if (_backend == PushBackend.web) ...[
            const SizedBox(height: NeuSpacing.lg),
            _buildFormField(
              context: context,
              label: 'VAPID 公钥',
              controller: _vapid,
              hintText: 'Base64URL 格式 P-256 公钥',
              icon: Icons.key_rounded,
              helperText: 'Web Push 客户端公钥',
              validator: (value) => validateVapidPublicKey(value ?? ''),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFormField({
    required BuildContext context,
    required String label,
    required TextEditingController controller,
    required String hintText,
    required String? Function(String?) validator,
    required IconData icon,
    String? helperText,
    TextInputType keyboardType = TextInputType.text,
  }) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;

    return Focus(
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: focused ? colors.accent : colors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: focused ? colors.accent : colors.text,
                    ),
                  ),
                  if (helperText != null) ...[
                    const Spacer(),
                    Text(
                      helperText,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: NeuSpacing.sm),
              AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                decoration: NeuDecoration(
                  colors: colors,
                  superellipseEnabled: ChatVisualSettingsScope.of(
                    context,
                  ).superellipseBorderEnabled,
                  depth: NeuDepth.pressed,
                  radius: NeuRadius.content,
                  intensity: .85,
                  borderColor: focused ? colors.accent : null,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                child: TextFormField(
                  controller: controller,
                  enabled: !_busy,
                  autocorrect: false,
                  keyboardType: keyboardType,
                  style: textTheme.bodyMedium?.copyWith(color: colors.text),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: hintText,
                    hintStyle: textTheme.bodyMedium?.copyWith(
                      color: colors.textTertiary,
                    ),
                    errorStyle: TextStyle(color: colors.error, fontSize: 12),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  validator: validator,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildActions({
    required BuildContext context,
    required bool configured,
    required PushSettings settings,
  }) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: double.infinity,
          child: NeuButton(
            accent: true,
            padding: const EdgeInsets.symmetric(vertical: 14),
            onPressed: _busy || !configured || !supportsPushBackend(_backend)
                ? null
                : () => _save(true),
            child: Center(
              child: Text(
                _enabled ? '保存并重新注册' : '启用推送',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        if (!configured && fcmPushRuntime.configurationChanged) ...[
          const SizedBox(height: NeuSpacing.xs),
          Center(
            child: Text(
              '待系统设置中强行停止应用并重新启动后可启用',
              style: textTheme.bodySmall?.copyWith(
                color: colors.textTertiary,
                fontSize: 12,
              ),
            ),
          ),
        ],
        if (_enabled || settings.registrations.isNotEmpty) ...[
          const SizedBox(height: NeuSpacing.md),
          SizedBox(
            width: double.infinity,
            child: NeuButton(
              padding: const EdgeInsets.symmetric(vertical: 14),
              onPressed: _busy ? null : () => _save(false),
              child: Center(
                child: Text(
                  _enabled ? '关闭推送' : '重试注销推送',
                  style: TextStyle(
                    color: _enabled ? colors.error : colors.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ],
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: NeuSpacing.md),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  Widget _buildHelpCard({required BuildContext context}) {
    final colors = context.neu;
    return NeuSurface(
      color: colors.card,
      radius: NeuRadius.surface,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          _buildInfoTile(
            context,
            icon: Icons.hub_outlined,
            title: '关于网关',
            content: 'Matter 不提供默认网关。构建中已配置网关时，可以直接启用；需要时展开“网关配置”修改。',
          ),
          const _Hairline(),
          _buildInfoTile(
            context,
            icon: Icons.notifications_none_rounded,
            title: '通知行为',
            content: '通知显示“你有一条新消息”，点击后进入对应账号的聊天。房间免打扰仍由房间管理中的设置控制。',
          ),
          const _Hairline(),
          _buildInfoTile(
            context,
            icon: _backend == PushBackend.web
                ? Icons.language_rounded
                : Icons.phone_android_rounded,
            title: _backend == PushBackend.web ? 'Web 端环境' : 'Android 端环境',
            content: _backend == PushBackend.web
                ? '浏览器须支持 Web Push，站点须使用 HTTPS；网关须支持 Web Push/VAPID，并保留账号路由数据。'
                : 'Android 设备需要 Google Play 服务。网关的 FCM 项目必须与当前 Firebase 配置一致。',
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String content,
  }) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  content,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.subtitle});

  final String text;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, NeuSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _NoticeTone { info, warning, error }

/// Single notice style for inline status, warnings and errors, so the page
/// does not grow a different container per message.
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.tone, required this.body, this.title});

  final _NoticeTone tone;
  final String body;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final (color, icon) = switch (tone) {
      _NoticeTone.info => (colors.textSecondary, Icons.info_outline_rounded),
      _NoticeTone.warning => (colors.warning, Icons.restart_alt_rounded),
      _NoticeTone.error => (colors.error, Icons.error_outline_rounded),
    };
    return Container(
      padding: const EdgeInsets.all(NeuSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(NeuRadius.button),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: NeuSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  body,
                  style: textTheme.bodySmall?.copyWith(
                    color: color,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
