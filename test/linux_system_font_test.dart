import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/fonts/linux_system_font.dart';
import 'package:matter/providers/app_font_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.aks.matter/system_font');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> changed(String family) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('changed', family)),
      (_) {},
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getFamily');
      return 'GTK Font';
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'Linux default and following chat update with GTK, without changing sizes',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appFontFamilyProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(appFontFamilyProvider), 'GTK Font');
      expect(container.read(chatFontFamilyProvider), 'GTK Font');
      final scales = container.read(fontScaleSettingsProvider);
      final mono = container.read(monospaceFontFamilyProvider);
      await changed('New GTK Font');
      expect(container.read(appFontFamilyProvider), 'New GTK Font');
      expect(container.read(chatFontFamilyProvider), 'New GTK Font');
      expect(container.read(monospaceFontFamilyProvider), mono);
      expect(container.read(fontScaleSettingsProvider), scales);
    },
  );

  test(
    'explicit UI, chat, mono and fallback choices retain priority',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_font_kind': 'system',
        'app_font_family': 'UI Choice',
        'chat_font_kind': 'system',
        'chat_font_family': 'Chat Choice',
        'mono_font_kind': 'system',
        'mono_font_family': 'Mono Choice',
        'app_font_fallback_family': 'Fallback Choice',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appFontFamilyProvider);
      container.read(chatFontFamilyProvider);
      container.read(monospaceFontFamilyProvider);
      container.read(appFontFallbackProvider);
      await Future<void>.delayed(Duration.zero);
      await changed('New GTK Font');
      expect(container.read(appFontFamilyProvider), 'UI Choice');
      expect(container.read(chatFontFamilyProvider), 'Chat Choice');
      expect(container.read(monospaceFontFamilyProvider), 'Mono Choice');
      expect(container.read(appFontFallbackProvider), ['Fallback Choice']);
    },
  );

  test('a change wins over a late initial response and disposal ignores late results', () async {
    final initial = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (_) => initial.future);
    final container = ProviderContainer();
    container.read(linuxSystemFontProvider);
    await changed('Latest GTK Font');
    initial.complete('Stale GTK Font');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(linuxSystemFontProvider), 'Latest GTK Font');
    container.dispose();
    await changed('After disposal');

    final pending = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    final disposed = ProviderContainer();
    disposed.read(linuxSystemFontProvider);
    disposed.dispose();
    pending.complete('Late Font');
    await Future<void>.delayed(Duration.zero);
  });
}
