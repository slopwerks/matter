import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/settings/blur_settings_page.dart';
import 'package:matter/providers/chat_visual_settings_provider.dart';
import 'package:matter/widgets/glass.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  testWidgets(
    'pushed routes and sheets follow restored and live visual settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'chat_visual_chat_blur': false,
        'chat_visual_superellipse_border': false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            builder: (context, child) => ChatVisualSettingsRoot(child: child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const BlurSettingsPage(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byType(GlassPanel), 300);
      await tester.pumpAndSettle();

      void expectPanelSettings(bool enabled) {
        final panel = find.byType(GlassPanel).last;
        final settings = ChatVisualSettingsScope.of(tester.element(panel));
        expect(settings.chatBlurEnabled, enabled);
        expect(settings.superellipseBorderEnabled, enabled);
        expect(
          find.descendant(of: panel, matching: find.byType(BackdropFilter)),
          enabled ? findsOneWidget : findsNothing,
        );
        final content = tester.widget<Container>(
          find.descendant(of: panel, matching: find.byType(Container)).first,
        );
        expect(
          (content.decoration! as ShapeDecoration).shape,
          enabled
              ? isA<RoundedSuperellipseBorder>()
              : isA<RoundedRectangleBorder>(),
        );
      }

      expectPanelSettings(false);
      final routeContext = tester.element(find.byType(BlurSettingsPage));
      showModalBottomSheet<void>(
        context: routeContext,
        builder: (_) => const GlassPanel(child: Text('sheet')),
      );
      await tester.pumpAndSettle();
      expectPanelSettings(false);

      final notifier = container.read(chatVisualSettingsProvider.notifier);
      await notifier.setChatBlurEnabled(true);
      await notifier.setSuperellipseBorderEnabled(true);
      await tester.pumpAndSettle();
      expectPanelSettings(true);

      Navigator.of(tester.element(find.text('sheet'))).pop();
      await tester.pumpAndSettle();
      expectPanelSettings(true);
      expect(tester.takeException(), isNull);
    },
  );
}
