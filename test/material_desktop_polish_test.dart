import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/settings/interaction_mode_settings_page.dart';
import 'package:matter/pages/settings/startup_page_settings_page.dart';
import 'package:matter/providers/interaction_mode_provider.dart';
import 'package:matter/providers/startup_page_provider.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('Material composer uses capsules without enlarging mouse targets', () {
    final material = neuTestTheme(material: true);
    final neu = neuTestTheme(material: false);
    expect(composerButtonShape(material), isA<StadiumBorder>());
    expect(composerButtonShape(neu), composerControlShape);
    for (final compact in [false, true]) {
      final size = compact ? 32.0 : 48.0;
      expect(
        composerIconButtonStyle(
          material,
          compact: compact,
        ).minimumSize!.resolve({}),
        Size.square(size),
      );
      expect(
        composerSendButtonStyle(
          material,
          compact: compact,
        ).minimumSize!.resolve({})!.height,
        size,
      );
      expect(
        composerSendButtonStyle(material, compact: compact).shape!.resolve({}),
        isA<StadiumBorder>(),
      );
    }
  });
  for (final dark in [false, true]) {
    testWidgets(
      'Material choices have radio semantics and selected container ($dark)',
      (tester) async {
        final container = ProviderContainer();
        final theme = neuTestTheme(material: true, dark: dark);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: theme,
              home: const InteractionModeSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(RadioListTile<InteractionMode>), findsNWidgets(3));
        final chosen = tester.widget<RadioListTile<InteractionMode>>(
          find.byKey(const ValueKey('interaction-mode-auto')),
        );
        expect(chosen.selected, isTrue);
        expect(chosen.selectedTileColor, theme.colorScheme.secondaryContainer);
        await tester.tap(find.byKey(const ValueKey('interaction-mode-touch')));
        await tester.pumpAndSettle();
        expect(container.read(interactionModeProvider), InteractionMode.touch);
        expect(
          tester
              .widget<RadioListTile<InteractionMode>>(
                find.byKey(const ValueKey('interaction-mode-touch')),
              )
              .selected,
          isTrue,
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: theme,
              home: const StartupPageSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(RadioListTile<StartupPage>),
          findsNWidgets(StartupPage.values.length),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      },
    );
  }
  testWidgets('Neu choice rows keep their original selection treatment', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(material: false),
          home: const InteractionModeSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<InteractionMode>), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });
  testWidgets(
    'Material attachment panel uses tonal surfaces and navigation indicators',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(material: true),
            home: Scaffold(
              body: SizedBox(
                height: 500,
                child: AttachmentPicker(
                  initialTab: AttachmentTab.poll,
                  roomId: '!test',
                  accountUserId: '@test',
                  height: 500,
                  maxHeight: 500,
                  totalMembers: 2,
                  onRefresh: (_) async {},
                  resolveSendPresentation: () => MessageSendPresentation.quiet,
                  onMessageQueued: (_, _) {},
                  onMessageSent: (_, _) {},
                  onHeightChanged: (_) {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      expect(navigation.selectedIndex, AttachmentTab.poll.index);
      expect(navigation.destinations, hasLength(4));
      expect(
        find.byKey(const ValueKey('attachment-send-button')),
        findsOneWidget,
      );
      expect(
        tester.widget(find.byKey(const ValueKey('attachment-send-button'))),
        isA<FilledButton>(),
      );
      final theme = Theme.of(tester.element(find.byType(AttachmentPicker)));
      final surfaces = tester.widgetList<Material>(find.byType(Material));
      expect(
        surfaces.any(
          (surface) => surface.color == theme.colorScheme.surfaceContainerLow,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
