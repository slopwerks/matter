import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../providers/auth_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/glass.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'encryption_dialog_surface.dart';
import 'encryption_verification_dialog.dart';
import 'material_encryption_sections.dart';

class EncryptionPage extends ConsumerStatefulWidget {
  const EncryptionPage({super.key});

  @override
  ConsumerState<EncryptionPage> createState() => _EncryptionPageState();
}

class _EncryptionPageState extends ConsumerState<EncryptionPage> {
  late final String? _accountUserId;
  bool get _isCurrentAccount =>
      mounted && ref.read(activeUserIdProvider) == _accountUserId;
  final _recoveryController = TextEditingController();
  List<rust.VerificationDevice> _devices = [];
  List<rust.AccountDevice>? _accountDevices;
  String? _accountDevicesError;
  rust.EncryptionRecoveryInfo? _recoveryInfo;
  String? _devicesError;
  String? _recoveryError;
  Timer? _recoveryTimer;
  bool _loadingAll = false;
  bool _refreshingRecovery = false;
  int _recoveryRequestId = 0;
  bool _loading = true;
  bool _busy = false;
  bool _verificationDialogOpen = false;
  bool _hideRecoveryValue = true;

  @override
  void initState() {
    super.initState();
    _accountUserId = ref.read(activeUserIdProvider);
    _loadAll();
    _loadAccountDevices();
    _recoveryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_isCurrentAccount && !_loadingAll && !_busy && !_refreshingRecovery) {
        unawaited(_refreshRecoveryInfo());
      }
    });
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    _recoveryController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    if (_loadingAll || !_isCurrentAccount) return;
    _loadingAll = true;
    // A pending state read must not overwrite the identity refresh below.
    _recoveryRequestId++;
    try {
      await _loadDevices();
      if (!_isCurrentAccount) return;
      await _refreshRecoveryInfo();
      if (!_isCurrentAccount) return;
      setState(() => _loading = false);
      try {
        final verification = await rust.getDeviceVerificationStatus();
        if (!_isCurrentAccount) return;
        if (verification != null &&
            verification.phase != 'done' &&
            verification.phase != 'cancelled') {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _showVerificationDialog(verification),
          );
        }
      } catch (error) {
        _showError(error);
      }
    } finally {
      _loadingAll = false;
    }
  }

  Future<void> _loadDevices() async {
    if (!_isCurrentAccount) return;
    try {
      final devices = await rust.listOwnDevices();
      if (!_isCurrentAccount) return;
      setState(() {
        _devices = devices;
        _devicesError = null;
      });
    } catch (error) {
      if (!_isCurrentAccount) return;
      setState(() => _devicesError = error.toString());
    }
  }

  Future<void> _refreshRecoveryInfo() async {
    if (!_isCurrentAccount) return;
    final requestId = ++_recoveryRequestId;
    _refreshingRecovery = true;
    try {
      final recovery = await rust.getEncryptionRecoveryInfo(
        accountUserId: _accountUserId,
      );
      if (!_isCurrentAccount || requestId != _recoveryRequestId) return;
      if (_recoveryInfo == recovery && _recoveryError == null) return;
      setState(() {
        _recoveryInfo = recovery;
        _recoveryError = null;
      });
    } catch (error) {
      if (!_isCurrentAccount || requestId != _recoveryRequestId) return;
      setState(() {
        _recoveryInfo = null;
        _recoveryError = error.toString();
      });
    } finally {
      if (requestId == _recoveryRequestId) _refreshingRecovery = false;
    }
  }

  Future<bool> _loadAccountDevices() async {
    if (!_isCurrentAccount) return false;
    try {
      final devices = await rust.listAccountDevices();
      if (!_isCurrentAccount) return false;
      setState(() {
        _accountDevices = devices;
        _accountDevicesError = null;
      });
      return true;
    } catch (error) {
      if (!_isCurrentAccount) return false;
      setState(() => _accountDevicesError = error.toString());
      return false;
    }
  }

  Future<void> _refreshDevicesAndRecovery() async {
    // Device trust can be committed just after the verification reaches Done.
    // Retry briefly so the success state is visible without a manual refresh.
    for (var attempt = 0; attempt < 3; attempt++) {
      await _loadDevices();
      if (!_isCurrentAccount) return;
      await _refreshRecoveryInfo();
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_isCurrentAccount) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object error) {
    if (!_isCurrentAccount) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('操作失败：${error.toString()}')));
  }

  String _recoveryLabel(String? state) {
    return switch (state) {
      'enabled' => '已启用，当前设备已持有恢复信息',
      'incomplete' => '账号已配置恢复，当前设备需要恢复密钥或恢复口令',
      'disabled' => '账号尚未配置密钥恢复',
      _ => '正在确认恢复状态',
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    if (ref.watch(activeUserIdProvider) != _accountUserId) {
      return Scaffold(
        backgroundColor: colors.base,
        extendBodyBehindAppBar: true,
        appBar: buildFloatingAppBar(title: const Text('设备与加密')),
        body: const Center(child: Text('当前账号已切换，请返回设置重新打开')),
      );
    }
    final viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
    return Scaffold(
      backgroundColor: colors.base,
      extendBodyBehindAppBar: context.isMaterial,
      appBar: context.isMaterial
          ? buildFloatingAppBar(title: const Text('设备与加密'))
          : null,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () async {
                      await _loadAll();
                      await _loadAccountDevices();
                    },
                    // 悬浮标题栏让滚动视图从屏幕顶部开始,下拉指示器按标题栏
                    // 高度下移,否则会被标题栏挡住。
                    edgeOffset: viewPaddingTop + kToolbarHeight,
                    child: MaxContentWidth(
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          NeuSpacing.lg,
                          viewPaddingTop + kToolbarHeight + NeuSpacing.sm,
                          NeuSpacing.lg,
                          32,
                        ),
                        children: [
                          _buildOverview(),
                          const SizedBox(height: NeuSpacing.lg),
                          _buildDevices(),
                          const SizedBox(height: NeuSpacing.lg),
                          _buildRecovery(),
                        ],
                      ),
                    ),
                  ),
          ),
          // 渐变模糊层:柔和过渡从标题栏下方滚过的内容。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: viewPaddingTop + kToolbarHeight,
              child: const TopFadeBlur(useShader: true),
            ),
          // 标题栏移到上方浮层,滚动内容从它下方穿过。
          if (!context.isMaterial)
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
                            '设备与加密',
                            style: Theme.of(context).textTheme.titleLarge,
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

  Widget _buildOverview() {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final verified = _recoveryInfo?.deviceVerified;
    if (context.isMaterial) {
      return MaterialEncryptionOverview(
        verified: verified,
        description: _recoveryError == null
            ? _recoveryLabel(_recoveryInfo?.state)
            : '加密状态读取失败，请下拉重试',
      );
    }
    return NeuSurface(
      color: colors.card,
      radius: NeuRadius.surface,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(
            verified == true
                ? Icons.verified_user_rounded
                : Icons.shield_outlined,
            size: 22,
            color: verified == true ? colors.success : colors.warning,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(switch (verified) {
                  true => '当前设备已验证',
                  false => '当前设备尚未验证',
                  null => '正在确认设备验证状态',
                }, style: textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  _recoveryError == null
                      ? _recoveryLabel(_recoveryInfo?.state)
                      : '加密状态读取失败，请下拉重试',
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDevices() {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final accountDevices = _accountDevices;
    final verificationById = {
      for (final device in _devices) device.deviceId: device,
    };
    if (context.isMaterial) {
      final entries = accountDevices != null
          ? [
              for (final account in accountDevices)
                (
                  account: account,
                  verification: verificationById[account.deviceId],
                ),
            ]
          : [
              for (final device in _devices)
                (account: null, verification: device),
            ];
      bool isCurrent(
        ({rust.AccountDevice? account, rust.VerificationDevice? verification})
        entry,
      ) => entry.account?.isCurrent ?? entry.verification?.isCurrent ?? false;
      return MaterialEncryptionDevices(
        current: [
          for (final entry in entries.where(isCurrent))
            _buildDevice(entry.account, entry.verification),
        ],
        others: [
          for (final entry in entries.where((entry) => !isCurrent(entry)))
            _buildDevice(entry.account, entry.verification),
        ],
        notices: [
          if (_devicesError != null) '设备验证状态刷新失败，请下拉重试',
          if (_accountDevicesError != null)
            accountDevices == null
                ? '登录设备信息暂不可用，显示已同步的验证设备'
                : '登录设备信息刷新失败，显示上次结果',
        ],
        emptyText: accountDevices == null ? '暂时没有读取到设备，请先完成一次同步' : '暂无登录设备',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('我的设备'),
        if (_devicesError != null) ...[
          NeuSurface(
            color: colors.card,
            radius: NeuRadius.surface,
            padding: const EdgeInsets.all(16),
            child: Text('设备验证状态刷新失败，请下拉重试', style: textTheme.bodySmall),
          ),
          const SizedBox(height: NeuSpacing.md),
        ],
        if (_accountDevicesError != null) ...[
          NeuSurface(
            color: colors.card,
            radius: NeuRadius.surface,
            padding: const EdgeInsets.all(16),
            child: Text(
              accountDevices == null
                  ? '登录设备信息暂不可用，显示已同步的验证设备'
                  : '登录设备信息刷新失败，显示上次结果',
              style: textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: NeuSpacing.md),
        ],
        if ((accountDevices?.isEmpty ?? _devices.isEmpty))
          NeuSurface(
            color: colors.card,
            radius: NeuRadius.surface,
            padding: const EdgeInsets.all(20),
            child: Text(
              accountDevices == null ? '暂时没有读取到设备，请先完成一次同步' : '暂无登录设备',
              style: textTheme.bodyMedium,
            ),
          )
        else
          Column(
            children: [
              if (accountDevices != null)
                for (var index = 0; index < accountDevices.length; index++) ...[
                  if (index > 0) const SizedBox(height: NeuSpacing.md),
                  _buildDevice(
                    accountDevices[index],
                    verificationById[accountDevices[index].deviceId],
                  ),
                ]
              else
                for (var index = 0; index < _devices.length; index++) ...[
                  if (index > 0) const SizedBox(height: NeuSpacing.md),
                  _buildDevice(null, _devices[index]),
                ],
            ],
          ),
      ],
    );
  }

  Widget _buildDevice(
    rust.AccountDevice? account,
    rust.VerificationDevice? device,
  ) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final deviceId = account?.deviceId ?? device!.deviceId;
    final accountName = account?.displayName?.trim();
    final name = accountName != null && accountName.isNotEmpty
        ? accountName
        : device?.displayName.trim().isNotEmpty == true
        ? device!.displayName
        : '未命名设备';
    final isCurrent = account?.isCurrent ?? device?.isCurrent ?? false;
    // Local trust of our own keys is not account cross-signing verification.
    final isVerified = isCurrent
        ? _recoveryInfo?.deviceVerified == true
        : _devicesError == null && (device?.isVerified ?? false);
    if (context.isMaterial) {
      return MaterialEncryptionDevice(
        name: name,
        deviceId: deviceId,
        current: isCurrent,
        verified: isCurrent
            ? _recoveryInfo?.deviceVerified
            : _devicesError == null
            ? device?.isVerified
            : null,
        hasVerification: device != null,
        onDetails: account == null ? null : () => _openDeviceDetails(account),
        onVerify: _busy ? null : () => _startVerification(deviceId),
      );
    }
    return GestureDetector(
      onTap: account == null ? null : () => _openDeviceDetails(account),
      child: NeuSurface(
        color: colors.card,
        radius: NeuRadius.content,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              isCurrent ? Icons.phone_android_rounded : Icons.devices_rounded,
              size: 22,
              color: isVerified ? colors.success : colors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall,
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 8),
                        NeuSurface(
                          depth: NeuDepth.flat,
                          color: colors.accentSoft,
                          radius: NeuRadius.tag,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            '本机',
                            style: textTheme.labelSmall?.copyWith(
                              color: colors.accent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    deviceId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (device != null)
              if (isCurrent || isVerified)
                Icon(
                  isVerified ? Icons.verified_rounded : Icons.circle_outlined,
                  size: 20,
                  color: isVerified ? colors.success : colors.textTertiary,
                )
              else
                NeuButton(
                  accent: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  intensity: .7,
                  onPressed: _busy ? null : () => _startVerification(deviceId),
                  child: const Text('验证'),
                ),
            if (account != null) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colors.textTertiary,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatLastSeen(rust.AccountDevice device) {
    final timestamp = device.lastSeenTs;
    if (timestamp == null) return '无活动记录';
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp.toInt())
        .toLocal();
    return DateFormat('yyyy-MM-dd HH:mm').format(time);
  }

  Future<void> _openDeviceDetails(rust.AccountDevice device) async {
    await showNeuSheet<void>(
      context: context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text(
              device.displayName?.trim().isNotEmpty == true
                  ? device.displayName!
                  : '未命名设备',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          _DeviceDetailRow(label: 'Device ID', value: device.deviceId),
          _DeviceDetailRow(label: 'IP 地址', value: device.lastSeenIp ?? '未知'),
          _DeviceDetailRow(label: '上次活动', value: _formatLastSeen(device)),
          if (device.isCurrent)
            const _DeviceDetailRow(label: '状态', value: '当前设备'),
          ...[
            const SizedBox(height: 4),
            NeuSheetItem(
              icon: Icons.edit_rounded,
              label: '重命名',
              onTap: () async {
                Navigator.of(context).pop();
                await _renameDevice(device);
              },
            ),
            if (!device.isCurrent)
              NeuSheetItem(
                icon: Icons.shield_outlined,
                label: '验证',
                onTap: _busy
                    ? () => {}
                    : () async {
                        Navigator.of(context).pop();
                        await _startVerification(device.deviceId);
                      },
              ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _renameDevice(rust.AccountDevice device) async {
    if (_busy || !_isCurrentAccount) return;
    final name = await showNeuPrompt(
      context,
      title: '重命名设备',
      message: '该名称会显示在账号的设备列表中。',
      hint: '设备名称',
      initial: device.displayName ?? '',
      confirmLabel: '保存',
    );
    if (name == null || !_isCurrentAccount) return;
    setState(() => _busy = true);
    try {
      await rust.renameAccountDevice(
        deviceId: device.deviceId,
        displayName: name,
      );
      final refreshed = await _loadAccountDevices();
      if (mounted) {
        neuToast(context, refreshed ? '设备名称已更新' : '设备名称已更新，但列表刷新失败');
      }
    } catch (error) {
      if (mounted) neuToast(context, '重命名失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startVerification(String deviceId) async {
    if (_busy || !_isCurrentAccount) return;
    setState(() => _busy = true);
    try {
      await rust.startDeviceVerification(deviceId: deviceId);
      final status = await rust.getDeviceVerificationStatus();
      if (status != null && mounted) {
        await _showVerificationDialog(status);
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showVerificationDialog(
    rust.DeviceVerificationStatus status,
  ) async {
    if (_verificationDialogOpen || !_isCurrentAccount) return;
    _verificationDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EncryptionVerificationDialog(initialStatus: status),
    );
    _verificationDialogOpen = false;
    if (mounted) await _refreshDevicesAndRecovery();
  }

  Widget _buildRecovery() {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final canCreate = _recoveryInfo?.state == 'disabled';
    if (context.isMaterial) {
      return MaterialEncryptionRecovery(
        controller: _recoveryController,
        hidden: _hideRecoveryValue,
        canCreate: canCreate,
        onVisibilityChanged: () =>
            setState(() => _hideRecoveryValue = !_hideRecoveryValue),
        onRecover: _busy ? null : _recoverEncryption,
        onCreate: _busy ? null : _enableRecovery,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('加密恢复'),
        NeuSurface(
          color: colors.card,
          radius: NeuRadius.surface,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('恢复历史加密消息', style: textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                '输入 Matrix 恢复密钥或设置恢复时使用的口令。内容只会交给本机加密存储处理。',
                style: textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              NeuTextField(
                controller: _recoveryController,
                obscureText: _hideRecoveryValue,
                hint: '恢复密钥或恢复口令',
                trailing: NeuIconButton(
                  icon: _hideRecoveryValue
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  size: 36,
                  tooltip: _hideRecoveryValue ? '显示' : '隐藏',
                  onPressed: () =>
                      setState(() => _hideRecoveryValue = !_hideRecoveryValue),
                ),
              ),
              const SizedBox(height: 12),
              NeuButton(
                accent: true,
                padding: const EdgeInsets.symmetric(vertical: 12),
                onPressed: _busy ? null : _recoverEncryption,
                child: const Center(child: Text('恢复加密数据')),
              ),
              if (canCreate) ...[
                const SizedBox(height: 8),
                NeuButton(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  onPressed: _busy ? null : _enableRecovery,
                  child: const Center(child: Text('新建恢复密钥')),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _recoverEncryption() => _run(() async {
    await rust.recoverEncryption(
      accountUserId: _accountUserId,
      recoveryKeyOrPassphrase: _recoveryController.text,
    );
    if (!_isCurrentAccount) return;
    _recoveryController.clear();
    await _refreshDevicesAndRecovery();
    if (mounted && _isCurrentAccount) {
      neuToast(context, '恢复信息已导入，历史消息将按需解密');
    }
  });

  Future<void> _enableRecovery() async {
    final passphrase = await showNeuPrompt(
      context,
      title: '新建恢复密钥',
      message: '可选填一个恢复口令。无论是否填写，都必须妥善保存稍后生成的恢复密钥。',
      hint: '恢复口令（可选）',
      confirmLabel: '创建',
      obscureText: true,
    );
    if (passphrase == null || !_isCurrentAccount) return;

    await _run(() async {
      final key = await rust.enableEncryptionRecovery(
        accountUserId: _accountUserId,
        passphrase: passphrase.trim().isEmpty ? null : passphrase.trim(),
      );
      await _refreshDevicesAndRecovery();
      if (!mounted || !_isCurrentAccount) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => EncryptionRecoveryKeyDialog(recoveryKey: key),
      );
    });
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 1.2),
      ),
    );
  }
}

class _DeviceDetailRow extends StatelessWidget {
  const _DeviceDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(child: Text(value, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
