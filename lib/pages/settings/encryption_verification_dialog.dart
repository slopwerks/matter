import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/neu_surface.dart';
import 'encryption_dialog_surface.dart';

class EncryptionVerificationDialog extends StatefulWidget {
  const EncryptionVerificationDialog({super.key, required this.initialStatus});

  final rust.DeviceVerificationStatus initialStatus;

  @override
  State<EncryptionVerificationDialog> createState() =>
      _EncryptionVerificationDialogState();
}

class _EncryptionVerificationDialogState
    extends State<EncryptionVerificationDialog> {
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('验证操作失败：$error')));
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

    return EncryptionDialogSurface(
      wideOnLandscape: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 40),
          const SizedBox(height: 12),
          Text(
            _title,
            textAlign: TextAlign.center,
            style: context.isMaterial
                ? textTheme.headlineSmall
                : textTheme.titleMedium,
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
              itemBuilder: (context, index) => EncryptionDialogValueSurface(
                neuColor: colors.card,
                child: Center(
                  child: Text(
                    _status.emojis[index].symbol,
                    style: context.isMaterial
                        ? textTheme.headlineMedium
                        : const TextStyle(fontSize: 30),
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
