import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';

class EncryptionPage extends StatefulWidget {
  const EncryptionPage({super.key});

  @override
  State<EncryptionPage> createState() => _EncryptionPageState();
}

class _EncryptionPageState extends State<EncryptionPage> {
  final _recoveryController = TextEditingController();
  Timer? _pollTimer;
  List<rust.VerificationDevice> _devices = [];
  rust.DeviceVerificationStatus? _verification;
  rust.EncryptionRecoveryInfo? _recoveryInfo;
  bool _loading = true;
  bool _busy = false;
  bool _polling = false;
  bool _hideRecoveryValue = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
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
        _verification = results[2] as rust.DeviceVerificationStatus?;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showError(error);
    }
  }

  Future<void> _poll() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final status = await rust.getDeviceVerificationStatus();
      if (!mounted) return;
      final wasDone = _verification?.phase == 'done';
      setState(() => _verification = status);
      if (!wasDone && status?.phase == 'done') {
        await _refreshDevicesAndRecovery();
      }
    } catch (_) {
      // Sync may briefly be unavailable while switching accounts.
    } finally {
      _polling = false;
    }
  }

  Future<void> _refreshDevicesAndRecovery() async {
    final devices = await rust.listOwnDevices();
    final recovery = await rust.getEncryptionRecoveryInfo();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _recoveryInfo = recovery;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _poll();
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

  String _verificationLabel(String phase) {
    return switch (phase) {
      'requested' => '另一台设备请求验证',
      'waiting' => '等待另一台设备接受',
      'starting' => '正在建立 Emoji 验证',
      'comparing' => '请比较两台设备上的 Emoji',
      'done' => '设备验证完成',
      'cancelled' => '验证已取消',
      _ => '正在处理验证',
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
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _buildOverview(),
                  const SizedBox(height: 16),
                  if (_verification != null) ...[
                    _buildVerificationCard(_verification!),
                    const SizedBox(height: 16),
                  ],
                  _buildDevices(),
                  const SizedBox(height: 16),
                  _buildRecovery(),
                ],
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
                  : () => _run(
                      () => rust.startDeviceVerification(
                        deviceId: device.deviceId,
                      ),
                    ),
              child: const Text('验证'),
            ),
    );
  }

  Widget _buildVerificationCard(rust.DeviceVerificationStatus status) {
    final comparing = status.phase == 'comparing';
    final finished = status.phase == 'done' || status.phase == 'cancelled';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('设备验证'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _verificationLabel(status.phase),
                style: const TextStyle(
                  color: AppColors.onBackground,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '设备 ${status.deviceId}',
                style: const TextStyle(color: AppColors.onSurfaceVariant),
              ),
              if (comparing) ...[
                const SizedBox(height: 18),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: status.emojis.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.9,
                  ),
                  itemBuilder: (context, index) {
                    final emoji = status.emojis[index];
                    return Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(AppRadii.button),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            emoji.symbol,
                            style: const TextStyle(fontSize: 32),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '第 ${index + 1} 个',
                            style: const TextStyle(
                              color: AppColors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(rust.confirmDeviceVerification),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('相同，完成验证'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => rust.cancelDeviceVerification(mismatch: true),
                        ),
                  child: const Text(
                    '不相同，立即取消',
                    style: TextStyle(color: AppColors.error),
                  ),
                ),
              ] else if (status.phase == 'requested') ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(rust.acceptDeviceVerification),
                  child: const Text('接受并开始 Emoji 验证'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => rust.cancelDeviceVerification(mismatch: false),
                        ),
                  child: const Text('拒绝'),
                ),
              ] else if (!finished) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => rust.cancelDeviceVerification(mismatch: false),
                        ),
                  child: const Text('取消验证'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
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
