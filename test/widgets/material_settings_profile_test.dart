import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matter/pages/settings/settings_choice_chips.dart';
import 'package:matter/pages/settings/settings_profile_card.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/theme_provider.dart';
import 'package:matter/theme/material_theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final loggedIn in [false, true]) {
      testWidgets('$brightness profile card supports large text and editing', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var edits = 0;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: buildMaterialTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SettingsProfileCard(
                    user: loggedIn
                        ? const CurrentUser(
                            id: '@a-long-account-name:example.org',
                            displayName: '很长的显示名称 Shiro',
                            homeserver: 'https://example.org',
                          )
                        : null,
                    onTap: () => edits++,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(SettingsProfileCard));
        await tester.pumpAndSettle();
        expect(edits, 1);
        expect(find.text(loggedIn ? '很长的显示名称 Shiro' : '未登录'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'theme options stay reachable with enlarged text on a narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      ThemeFamily? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SettingsChoiceChips(
              options: ThemeFamily.values,
              selected: ThemeFamily.material,
              label: (family) => family.label,
              onChanged: (family) => selected = family,
            ),
          ),
        ),
      );
      await tester.tap(find.text('新拟物'));
      await tester.pumpAndSettle();
      expect(selected, ThemeFamily.neu);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
