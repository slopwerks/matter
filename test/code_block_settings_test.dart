import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/settings/code_block_settings_page.dart';
import 'package:matter/providers/code_block_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CodeBlockSettings Model', () {
    test('has expected defaults', () {
      const settings = CodeBlockSettings();
      expect(settings.darkTheme, 'atom-one-dark');
      expect(settings.lightTheme, 'atom-one-light');
      expect(settings.opacity, 1.0);
      expect(settings.showLineNumbers, false);
    });

    test('copyWith clamps opacity to [0.1, 1.0]', () {
      const settings = CodeBlockSettings();
      final low = settings.copyWith(opacity: 0.0);
      expect(low.opacity, 0.1);

      final high = settings.copyWith(opacity: 1.5);
      expect(high.opacity, 1.0);

      final normal = settings.copyWith(opacity: 0.6);
      expect(normal.opacity, 0.6);
    });

    test('equality and hashCode work as expected', () {
      const s1 = CodeBlockSettings(darkTheme: 'monokai', opacity: 0.8);
      const s2 = CodeBlockSettings(darkTheme: 'monokai', opacity: 0.8);
      const s3 = CodeBlockSettings(darkTheme: 'vs2015', opacity: 0.8);

      expect(s1, equals(s2));
      expect(s1.hashCode, equals(s2.hashCode));
      expect(s1, isNot(equals(s3)));
    });
  });

  group('CodeBlockSettingsNotifier Persistence', () {
    test('updates state and persists to SharedPreferences', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(codeBlockSettingsProvider.notifier);

      await notifier.setDarkTheme('monokai');
      expect(container.read(codeBlockSettingsProvider).darkTheme, 'monokai');

      await notifier.setLightTheme('github');
      expect(container.read(codeBlockSettingsProvider).lightTheme, 'github');

      await notifier.setOpacity(0.75);
      expect(container.read(codeBlockSettingsProvider).opacity, 0.75);

      await notifier.setShowLineNumbers(true);
      expect(container.read(codeBlockSettingsProvider).showLineNumbers, true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('code_block_dark_theme'), 'monokai');
      expect(prefs.getString('code_block_light_theme'), 'github');
      expect(prefs.getDouble('code_block_opacity'), 0.75);
      expect(prefs.getBool('code_block_line_numbers'), true);
    });

    test('restores saved settings from SharedPreferences on init', () async {
      SharedPreferences.setMockInitialValues({
        'code_block_dark_theme': 'tokyo-night-dark',
        'code_block_light_theme': 'vs',
        'code_block_opacity': 0.85,
        'code_block_line_numbers': true,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(codeBlockSettingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container.read(codeBlockSettingsProvider);
      expect(state.darkTheme, 'tokyo-night-dark');
      expect(state.lightTheme, 'vs');
      expect(state.opacity, 0.85);
      expect(state.showLineNumbers, true);
    });
  });

  group('CodeBlockSettingsPage Widget', () {
    testWidgets('renders preview, slider, and theme choices', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const CodeBlockSettingsPage(),
          ),
        ),
      );

      expect(find.text('代码块设置'), findsOneWidget);
      expect(find.text('效果实时预览'), findsOneWidget);
      expect(find.textContaining('MatterClient'), findsWidgets);
      expect(find.text('背景透明度'), findsOneWidget);
      expect(find.text('暗色模式高亮主题'), findsOneWidget);
      expect(find.text('浅色模式高亮主题'), findsOneWidget);

      // Verify theme options exist
      expect(find.text('Atom One Dark'), findsOneWidget);
      expect(find.text('GitHub Dark'), findsOneWidget);
      expect(find.text('VS Code'), findsOneWidget);
      expect(find.text('Monokai'), findsOneWidget);
      expect(find.text('Tokyo Night'), findsOneWidget);

      // Switch preview segment
      await tester.tap(find.text('浅色'));
      await tester.pumpAndSettle();
      expect(find.text('模拟浅色消息气泡'), findsOneWidget);

      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(find.text('模拟深色消息气泡'), findsOneWidget);
    });
  });
}
