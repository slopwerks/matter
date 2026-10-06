import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connection_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_surface.dart';

/// Keeps authentication failures visible above every route in the app.
class SessionExpiryListener extends ConsumerStatefulWidget {
  const SessionExpiryListener({
    super.key,
    required this.child,
    required this.onRelogin,
    required this.navigatorKey,
  });

  final Widget child;
  final ValueChanged<bool> onRelogin;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  ConsumerState<SessionExpiryListener> createState() =>
      _SessionExpiryListenerState();
}

class _SessionExpiryListenerState extends ConsumerState<SessionExpiryListener> {
  String? _promptedAccount;
  String? _dialogAccount;
  DialogRoute<bool>? _dialog;
  bool _reloggingIn = false;

  void _closeDialog() {
    final route = _dialog;
    _dialog = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  void _checkSession() {
    if (!mounted) return;
    final account = ref.read(activeUserIdProvider);
    final expired =
        ref.read(connectionProvider) == AppConnectionState.sessionExpired;
    final ready =
        ref.read(sessionReadyProvider) && ref.read(isLoggedInProvider);
    if (_reloggingIn && account == _dialogAccount) return;
    if (!expired || account != _promptedAccount) _promptedAccount = null;
    if (_dialog != null && (!expired || !ready || account != _dialogAccount)) {
      _closeDialog();
    }
    if (!expired ||
        !ready ||
        account == null ||
        _dialog != null ||
        _promptedAccount == account) {
      return;
    }
    _promptedAccount = account;
    _dialogAccount = account;
    unawaited(_showDialog(account));
  }

  Future<void> _showDialog(String account) async {
    var busy = false;
    var canResume = false;
    String? error;
    final navigator = widget.navigatorKey.currentState!;
    late final DialogRoute<bool> route;
    route = DialogRoute<bool>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => PopScope(
          canPop: !busy,
          child: Dialog(
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
                      '登录已失效',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$account\n\n请重新登录以继续收发消息。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(error!, style: TextStyle(color: context.neu.error)),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: NeuButton(
                            onPressed: busy ? null : () => navigator.pop(false),
                            child: const Center(child: Text('稍后')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: NeuButton(
                            onPressed: busy
                                ? null
                                : () async {
                                    setDialogState(() {
                                      busy = true;
                                      error = null;
                                    });
                                    _reloggingIn = true;
                                    try {
                                      canResume = await rust
                                          .prepareSessionRelogin(
                                            accountUserId: account,
                                          );
                                      if (!mounted ||
                                          !dialogContext.mounted ||
                                          ref.read(activeUserIdProvider) !=
                                              account) {
                                        return;
                                      }
                                      if (route.isCurrent) {
                                        navigator.pop(true);
                                      } else {
                                        navigator.removeRoute(route, true);
                                      }
                                    } catch (_) {
                                      if (dialogContext.mounted) {
                                        setDialogState(() {
                                          busy = false;
                                          error = '无法打开登录页，请重试。';
                                        });
                                      }
                                    } finally {
                                      _reloggingIn = false;
                                    }
                                  },
                            child: Center(
                              child: busy
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('重新登录'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _dialog = route;
    final relogin = await navigator.push(route);
    if (_dialog == route) _dialog = null;
    if (!mounted ||
        relogin != true ||
        ref.read(activeUserIdProvider) != account) {
      return;
    }
    widget.onRelogin(canResume);
  }

  @override
  void dispose() {
    final route = _dialog;
    // Navigator may be rebuilding its home route while this widget is removed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route != null && route.isActive) route.navigator?.removeRoute(route);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(connectionProvider);
    ref.watch(activeUserIdProvider);
    ref.watch(sessionReadyProvider);
    ref.watch(isLoggedInProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSession());
    return widget.child;
  }
}
