import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// GTK's resolved desktop family, not Flutter's built-in Linux default.
class LinuxSystemFont extends Notifier<String?> {
  static const _channel = MethodChannel('moe.aks.matter/system_font');

  @override
  String? build() {
    var disposed = false;
    var changed = false;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed' && !disposed) {
        changed = true;
        state = call.arguments as String?;
      }
    });
    ref.onDispose(() {
      disposed = true;
      _channel.setMethodCallHandler(null);
    });
    _channel
        .invokeMethod<String>('getFamily')
        .then(
          (family) {
            if (!disposed && !changed) state = family;
          },
          onError: (Object error, StackTrace stack) {
            // A missing native bridge is visible in logs; retain the platform fallback.
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stack,
                library: 'Linux system font',
              ),
            );
          },
        );
    return null;
  }
}

final linuxSystemFontProvider = NotifierProvider<LinuxSystemFont, String?>(
  LinuxSystemFont.new,
);
