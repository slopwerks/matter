import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../theme/neu_colors.dart';
import 'neu_decoration.dart';

/// Space kept free under a toast so it never covers the composer.
const double neuToastBottomGap = 88;

/// Longest a toast may get before it wraps.
const double neuToastMaxWidth = 300;

OverlayEntry? _visibleToast;
Timer? _dismissTimer;
int _toastToken = 0;
int _toastTimerToken = 0;

/// Shows [message] in a short lived pill above the bottom of the screen.
///
/// The pill is sized to its text, centred, and ignores pointers, so it can
/// never swallow a tap on the composer or the buttons underneath it.
void showNeuToast(BuildContext context, String message) {
  // Callers often hand over the root overlay's own context (message actions
  // capture it once). That context has no Overlay above it, so fall back to the
  // navigator the overlay belongs to.
  final overlay =
      Overlay.maybeOf(context, rootOverlay: true) ??
      Navigator.maybeOf(context, rootNavigator: true)?.overlay;
  if (overlay == null) return;
  final colors = context.neu;
  final material = context.isMaterial;
  final theme = Theme.of(context);
  final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

  _hideToast();

  final token = ++_toastToken;
  final entry = OverlayEntry(
    builder: (context) => _ToastLifetime(
      token: token,
      child: Positioned(
        left: 16,
        right: 16,
        bottom: bottomInset + neuToastBottomGap,
        child: IgnorePointer(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: neuToastMaxWidth),
              child: DecoratedBox(
                decoration: material
                    ? BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      )
                    : NeuDecoration(
                        colors: colors,
                        depth: NeuDepth.flat,
                        radius: NeuRadius.tag,
                      ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: material
                          ? theme.colorScheme.onSurface
                          : colors.text,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  _visibleToast = entry;
  overlay.insert(entry);
  _toastTimerToken = token;
  _dismissTimer = Timer(const Duration(milliseconds: 1600), _hideToast);
}

/// Drops the dismiss timer together with the pill.
///
/// A caller that never pumps the timeout (a widget test tearing the tree down)
/// would otherwise leave the timer pending and fail the test.
class _ToastLifetime extends StatefulWidget {
  const _ToastLifetime({required this.token, required this.child});

  final int token;
  final Widget child;

  @override
  State<_ToastLifetime> createState() => _ToastLifetimeState();
}

class _ToastLifetimeState extends State<_ToastLifetime> {
  @override
  void dispose() {
    // Only the toast that still owns the timer may drop it: a replaced pill is
    // unmounted after the newer one has already scheduled its own dismiss.
    if (_toastTimerToken == widget.token) {
      _dismissTimer?.cancel();
      _dismissTimer = null;
      _visibleToast = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void _hideToast() {
  _dismissTimer?.cancel();
  _dismissTimer = null;
  _toastTimerToken = 0;
  final entry = _visibleToast;
  _visibleToast = null;
  if (entry != null && entry.mounted) entry.remove();
}
