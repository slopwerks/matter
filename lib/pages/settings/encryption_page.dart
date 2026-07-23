import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/max_content_width.dart';

class EncryptionPage extends StatefulWidget {
  const EncryptionPage({super.key});

  @override
  State<EncryptionPage> createState() => _EncryptionPageState();
}

class _EncryptionPageState extends State<EncryptionPage> {
  final _recoveryController = TextEditingController();
  List<rust.VerificationDevice> _devices = [];
  rust.EncryptionRecoveryInfo? _recoveryInfo;
  bool _loading = true;
  bool _busy = false;
  bool _verificationDialogOpen = false;
  bool _hideRecoveryValue = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
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
    return Scaffold(
      appBar: AppBar(title: const Text('加密与验证')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadAll,
              child: MaxContentWidth(
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    _buildOverview(),
                    const SizedBox(height: 16),
                    _buildDevices(),
                    const SizedBox(height: 16),
                    _buildRecovery(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildOverview() {
    final verified = _recoveryInfo?.deviceVerified ?? false;
    return AppCard(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: (verified ? AppColors.success : AppColors.warning)
                  .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadii.button),
            ),
            child: Icon(
              verified ? Icons.verified_user_rounded : Icons.shield_outlined,
              color: verified ? AppColors.success : AppColors.warning,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  verified ? '当前设备已验证' : '当前设备尚未验证',
                  style: const TextStyle(
                    color: AppColors.onBackground,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _recoveryLabel(_recoveryInfo?.state),
                  style: const TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDevices() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('我的设备'),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var index = 0; index < _devices.length; index++) ...[
                _buildDevice(_devices[index]),
                if (index != _devices.length - 1)
                  const Divider(height: 1, indent: 64),
              ],
              if (_devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    '暂时没有读取到设备，请先完成一次同步',
                    style: TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDevice(rust.VerificationDevice device) {
    return ListTile(
      leading: Icon(
        device.isCurrent ? Icons.phone_android_rounded : Icons.devices_rounded,
        color: device.isVerified ? AppColors.success : AppColors.primary,
      ),
      title: Text(
        device.displayName,
        style: const TextStyle(color: AppColors.onBackground),
      ),
      subtitle: Text(
        '${device.deviceId}${device.isCurrent ? ' · 当前设备' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.onSurfaceVariant),
      ),
      trailing: device.isCurrent || device.isVerified
          ? Icon(
              device.isVerified
                  ? Icons.verified_rounded
                  : Icons.circle_outlined,
              color: device.isVerified ? AppColors.success : AppColors.muted,
            )
          : TextButton(
              onPressed: _busy
                  ? null
                  : () => _startVerification(device.deviceId),
              child: const Text('验证'),
            ),
    );
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
    final enabled = _recoveryInfo?.state == 'enabled';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('加密恢复'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '恢复历史加密消息',
                style: TextStyle(
                  color: AppColors.onBackground,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '输入 Matrix 恢复密钥或设置恢复时使用的口令。内容只会交给本机加密存储处理。',
                style: TextStyle(
                  color: AppColors.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _recoveryController,
                obscureText: _hideRecoveryValue,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: '恢复密钥或恢复口令',
                  suffixIcon: IconButton(
                    onPressed: () => setState(
                      () => _hideRecoveryValue = !_hideRecoveryValue,
                    ),
                    icon: Icon(
                      _hideRecoveryValue
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await rust.recoverEncryption(
                          recoveryKeyOrPassphrase: _recoveryController.text,
                        );
                        _recoveryController.clear();
                        await _refreshDevicesAndRecovery();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('加密数据恢复完成')),
                          );
                        }
                      }),
                child: const Text('恢复加密数据'),
              ),
              if (!enabled) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _enableRecovery,
                  child: const Text('新建恢复密钥'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _enableRecovery() async {
    final controller = TextEditingController();
    final passphrase = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建恢复密钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('可选填一个恢复口令。无论是否填写，都必须妥善保存稍后生成的恢复密钥。'),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(hintText: '恢复口令（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
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
        builder: (context) => AlertDialog(
          title: const Text('保存恢复密钥'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('这是恢复历史加密消息的最后保障。请保存到安全的位置，关闭后不会再次显示。'),
              const SizedBox(height: 14),
              SelectableText(
                key,
                style: const TextStyle(
                  color: AppColors.onBackground,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: key));
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('恢复密钥已复制')));
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('复制'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('我已保存'),
            ),
          ],
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
    final comparing = _status.phase == 'comparing';
    final color = switch (_status.phase) {
      'done' => AppColors.success,
      'cancelled' => AppColors.error,
      _ => AppColors.primary,
    };
    final icon = switch (_status.phase) {
      'done' => Icons.verified_rounded,
      'cancelled' => Icons.cancel_rounded,
      _ => Icons.phonelink_lock_rounded,
    };

    return AlertDialog(
      icon: Icon(icon, color: color, size: 40),
      title: Text(_title, textAlign: TextAlign.center),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _description,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.onSurfaceVariant),
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
                  itemBuilder: (context, index) => Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(AppRadii.button),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _status.emojis[index].symbol,
                      style: const TextStyle(fontSize: 30),
                    ),
                  ),
                ),
              ] else if (!_finished && _status.phase != 'requested') ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: _buildActions(comparing),
    );
  }

  List<Widget> _buildActions(bool comparing) {
    if (_finished) {
      return [
        FilledButton(onPressed: _busy ? null : _close, child: const Text('关闭')),
      ];
    }
    if (_status.phase == 'requested') {
      return [
        TextButton(
          onPressed: _busy ? null : () => _cancel(mismatch: false),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _run(rust.acceptDeviceVerification),
          child: const Text('接受'),
        ),
      ];
    }
    if (comparing) {
      return [
        TextButton(
          onPressed: _busy ? null : () => _cancel(mismatch: true),
          child: const Text('不相同'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : () => _run(rust.confirmDeviceVerification),
          icon: const Icon(Icons.check_rounded),
          label: const Text('完全相同'),
        ),
      ];
    }
    return [
      TextButton(
        onPressed: _busy ? null : () => _cancel(mismatch: false),
        child: const Text('取消验证'),
      ),
    ];
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
        style: const TextStyle(
          color: AppColors.onSurfaceVariant,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
