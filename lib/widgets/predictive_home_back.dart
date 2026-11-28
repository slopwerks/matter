import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Only eligibility crosses the bridge. Android animates its cached View,
/// without sending gesture progress through Dart or repainting the Flutter tree.
class PredictiveHomeBack extends StatefulWidget {
  const PredictiveHomeBack({
    super.key,
    required this.enabled,
    required this.child,
  });
  final bool enabled;
  final Widget child;
  @override
  State<PredictiveHomeBack> createState() => _PredictiveHomeBackState();
}

class _PredictiveHomeBackState extends State<PredictiveHomeBack>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('moe.aks.matter/home_back');
  bool _canHandlePop = false;
  bool? _lastEligible;
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _publish();
  }

  @override
  void didUpdateWidget(PredictiveHomeBack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publish();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _publish();
  }

  void _publish() {
    if (!_android) return;
    final eligible =
        widget.enabled &&
        !_canHandlePop &&
        MediaQuery.viewInsetsOf(context).bottom == 0;
    if (eligible == _lastEligible) return;
    _lastEligible = eligible;
    unawaited(_channel.invokeMethod<void>('setEligible', eligible));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_android) unawaited(_channel.invokeMethod<void>('setEligible', false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<NavigationNotification>(
        onNotification: (notification) {
          _canHandlePop = notification.canHandlePop;
          _publish();
          // The normal WidgetsApp listener still controls Flutter's child-route
          // callback. Native home handling is active only when it is released.
          return false;
        },
        child: widget.child,
      );
}
