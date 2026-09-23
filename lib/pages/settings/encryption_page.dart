import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

class EncryptionPage extends StatefulWidget {
  const EncryptionPage({super.key});

  @override
  State<EncryptionPage> createState() => _EncryptionPageState();
}

class _EncryptionPageState extends State<EncryptionPage> {
  final _recoveryController = TextEditingController();
  List<rust.VerificationDevice> _devices = [];
  List<rust.AccountDevice>? _accountDevices;
  String? _accountDevicesError;
  rust.EncryptionRecoveryInfo? _recoveryInfo;
  bool _loading = true;
  bool _busy = false;
  bool _verificationDialogOpen = false;
  bool _hideRecoveryValue = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadAccountDevices();
  }

  @override
  void dispose() {
    _recoveryController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    try {
      final results = await Future.wait([
        rust.listOwnDevices(),
        rust.getEncryptionRecoveryInfo(),
        rust.getDeviceVerificationStatus(),
      ]);
      if (!mounted) return;
      setState(() {
        _devices = results[0] as List<rust.VerificationDevice>;
        _recoveryInfo = results[1] as rust.EncryptionRecoveryInfo;
        _loading = false;
      });
      final verification = results[2] as rust.DeviceVerificationStatus?;
      if (verification != null &&
          verification.phase != 'done' &&
          verification.phase != 'cancelled') {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _showVerificationDialog(verification),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(error);
    }
  }

  Future<bool> _loadAccountDevices() async {
    try {
      final devices = await rust.listAccountDevices();
      if (!mounted) return false;
      setState(() {
        _accountDevices = devices;
        _accountDevicesError = null;
      });
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() => _accountDevicesError = error.toString());
      return false;
    }
  }

  Future<void> _refreshDevicesAndRecovery() async {
    // Device trust can be committed just after the verification reaches Done.
    // Retry briefly so the success state is visible without a manual refresh.
    for (var attempt = 0; attempt < 3; attempt++) {
      final devices = await rust.listOwnDevices();
      final recovery = await rust.getEncryptionRecoveryInfo();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _recoveryInfo = recovery;
      });
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
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
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('操作失败：${error.toString()}')));
  }

  String _recoveryLabel(String? state) {
    return switch (state) {
      'enabled' => '已启用，当前设备已持有恢复信息',
      'incomplete' => '需要恢复密钥或恢复口令',
      'disabled' => '尚未启用加密恢复',
      _ => '正在确认恢复状态',
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
    return Scaffold(
      backgroundColor: colors.base,
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
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: viewPaddingTop + kToolbarHeight,
            child: const TopFadeBlur(useShader: true),
          ),
          // 标题栏移到上方浮层,滚动内容从它下方穿过。
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
    final verified = _recoveryInfo?.deviceVerified ?? false;
    return NeuSurface(
      color: colors.card,
      radius: NeuRadius.surface,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(
            verified ? Icons.verified_user_rounded : Icons.shield_outlined,
            size: 22,
            color: verified ? colors.success : colors.warning,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  verified ? '当前设备已验证' : '当前设备尚未验证',
                  style: textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  _recoveryLabel(_recoveryInfo?.state),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('我的设备'),
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
    final isVerified = device?.isVerified ?? false;
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
    final time = DateTime.fromMillisecondsSinceEpoch(
      timestamp.toInt(),
    ).toLocal();
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
          if (device.isCurrent) ...[
            const SizedBox(height: 4),
            NeuSheetItem(
              icon: Icons.edit_rounded,
              label: '重命名',
              onTap: () async {
                Navigator.of(context).pop();
                await _renameDevice(device);
              },
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _renameDevice(rust.AccountDevice device) async {
    if (_busy || !device.isCurrent) return;
    final name = await showNeuPrompt(
      context,
      title: '重命名设备',
      message: '该名称会显示在账号的设备列表中。',
      hint: '设备名称',
      initial: device.displayName ?? '',
      confirmLabel: '保存',
    );
    if (name == null || !mounted) return;
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
    if (_busy) return;
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
    if (_verificationDialogOpen || !mounted) return;
    _verificationDialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VerificationDialog(initialStatus: status),
    );
    _verificationDialogOpen = false;
    if (mounted) await _refreshDevicesAndRecovery();
  }

  Widget _buildRecovery() {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final enabled = _recoveryInfo?.state == 'enabled';
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
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await rust.recoverEncryption(
                          recoveryKeyOrPassphrase: _recoveryController.text,
                        );
                        _recoveryController.clear();
                        await _refreshDevicesAndRecovery();
                        if (mounted) {
                          neuToast(context, '加密数据恢复完成');
                        }
                      }),
                child: const Center(child: Text('恢复加密数据')),
              ),
              if (!enabled) ...[
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

  Future<void> _enableRecovery() async {
    final passphrase = await showNeuPrompt(
      context,
      title: '新建恢复密钥',
      message: '可选填一个恢复口令。无论是否填写，都必须妥善保存稍后生成的恢复密钥。',
      hint: '恢复口令（可选）',
      confirmLabel: '创建',
      obscureText: true,
    );
    if (passphrase == null || !mounted) return;

    await _run(() async {
      final key = await rust.enableEncryptionRecovery(
        passphrase: passphrase.trim().isEmpty ? null : passphrase.trim(),
      );
      await _refreshDevicesAndRecovery();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 32),
          child: GlassPanel(
            radius: NeuRadius.nav,
            padding: const EdgeInsets.all(22),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '保存恢复密钥',
                    style: Theme.of(dialogContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '这是恢复历史加密消息的最后保障。请保存到安全的位置，关闭后不会再次显示。',
                    style: Theme.of(dialogContext).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 14),
                  NeuSurface(
                    depth: NeuDepth.pressed,
                    radius: NeuRadius.button,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      key,
                      style: Theme.of(dialogContext).textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace', height: 1.6),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: NeuButton(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: key));
                            if (dialogContext.mounted) {
                              neuToast(dialogContext, '恢复密钥已复制');
                            }
                          },
                          child: const Center(child: Text('复制')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: NeuButton(
                          accent: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Center(child: Text('我已保存')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _VerificationDialog extends StatefulWidget {
  const _VerificationDialog({required this.initialStatus});

  final rust.DeviceVerificationStatus initialStatus;

  @override
  State<_VerificationDialog> createState() => _VerificationDialogState();
}

class _VerificationDialogState extends State<_VerificationDialog> {
  Timer? _timer;
  late rust.DeviceVerificationStatus _status;
  bool _busy = false;
  bool _polling = false;

  bool get _finished => _status.phase == 'done' || _status.phase == 'cancelled';

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    if (!_finished) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _poll(),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _title => switch (_status.phase) {
    'requested' => '设备验证请求',
    'waiting' => '等待另一台设备',
    'starting' => '正在建立验证',
    'comparing' => '比较 Emoji',
    'done' => '验证完成',
    'cancelled' => '验证已取消',
    _ => '设备验证',
  };

  String get _description => switch (_status.phase) {
    'requested' => '设备 ${_status.deviceId} 请求验证当前设备。',
    'waiting' => '已向设备 ${_status.deviceId} 发送请求，请在另一台设备上接受。',
    'starting' => '正在与设备 ${_status.deviceId} 建立 Emoji 验证。',
    'comparing' => '请确认两台设备上的 Emoji 完全相同。',
    'done' => '设备 ${_status.deviceId} 已成功验证。',
    'cancelled' => '本次设备验证已取消，不会更改任何信任状态。',
    _ => _status.message,
  };

  Future<void> _poll() async {
    if (_polling || _finished || !mounted) return;
    _polling = true;
    try {
      final status = await rust.getDeviceVerificationStatus();
      if (!mounted || status == null) return;
      setState(() => _status = status);
      if (_finished) _timer?.cancel();
    } catch (_) {
      // Sync can briefly be unavailable while verification events are applied.
    } finally {
      _polling = false;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _poll();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('验证操作失败：$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel({required bool mismatch}) async {
    await _run(() async {
      await rust.cancelDeviceVerification(mismatch: mismatch);
      if (!mounted) return;
      _timer?.cancel();
      setState(() {
        _status = rust.DeviceVerificationStatus(
          phase: 'cancelled',
          deviceId: _status.deviceId,
          flowId: _status.flowId,
          incoming: _status.incoming,
          emojis: const [],
          message: 'Verification cancelled',
        );
      });
    });
  }

  Future<void> _close() async {
    if (_status.phase == 'done') {
      try {
        await rust.cancelDeviceVerification(mismatch: false);
      } catch (_) {
        // The SDK may already have discarded the completed flow.
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final comparing = _status.phase == 'comparing';
    final color = switch (_status.phase) {
      'done' => colors.success,
      'cancelled' => colors.error,
      _ => colors.accent,
    };
    final icon = switch (_status.phase) {
      'done' => Icons.verified_rounded,
      'cancelled' => Icons.cancel_rounded,
      _ => Icons.phonelink_lock_rounded,
    };

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: GlassPanel(
        radius: NeuRadius.nav,
        padding: const EdgeInsets.all(22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 40),
              const SizedBox(height: 12),
              Text(
                _title,
                textAlign: TextAlign.center,
                style: textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _description,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium,
              ),
              if (comparing) ...[
                const SizedBox(height: 20),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _status.emojis.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.9,
                  ),
                  itemBuilder: (context, index) => NeuSurface(
                    depth: NeuDepth.pressed,
                    color: colors.card,
                    radius: NeuRadius.button,
                    child: Center(
                      child: Text(
                        _status.emojis[index].symbol,
                        style: const TextStyle(fontSize: 30),
                      ),
                    ),
                  ),
                ),
              ] else if (!_finished && _status.phase != 'requested') ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: 20),
              _buildActions(comparing),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActions(bool comparing) {
    final buttons = <Widget>[];
    void add(Widget button) {
      if (buttons.isNotEmpty) buttons.add(const SizedBox(width: 12));
      buttons.add(Expanded(child: button));
    }

    if (_finished) {
      add(
        NeuButton(
          accent: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed: _busy ? null : _close,
          child: const Center(child: Text('关闭')),
        ),
      );
    } else if (_status.phase == 'requested') {
      add(
        NeuButton(
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed: _busy ? null : () => _cancel(mismatch: false),
          child: const Center(child: Text('拒绝')),
        ),
      );
      add(
        NeuButton(
          accent: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed: _busy ? null : () => _run(rust.acceptDeviceVerification),
          child: const Center(child: Text('接受')),
        ),
      );
    } else if (comparing) {
      add(
        NeuButton(
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed: _busy ? null : () => _cancel(mismatch: true),
          child: const Center(child: Text('不相同')),
        ),
      );
      add(
        NeuButton(
          accent: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          icon: const Icon(Icons.check_rounded),
          onPressed: _busy ? null : () => _run(rust.confirmDeviceVerification),
          child: const Center(child: Text('完全相同')),
        ),
      );
    } else {
      add(
        NeuButton(
          padding: const EdgeInsets.symmetric(vertical: 12),
          onPressed: _busy ? null : () => _cancel(mismatch: false),
          child: const Center(child: Text('取消验证')),
        ),
      );
    }
    return Row(children: buttons);
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
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
