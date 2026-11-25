import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/startup_page_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alice = '@alice:test';
const _bob = '@bob:test';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'remember is default and missing history opens all conversations',
    () async {
      expect(
        (await loadStartupLocation(_alice)).page,
        NavigationDestinationPage.allChats,
      );
    },
  );
  test('navigation history is isolated by account', () async {
    await rememberNavigationPage(
      _alice,
      const StartupLocation(
        NavigationDestinationPage.space,
        spaceId: '!space:test',
      ),
    );
    expect((await loadStartupLocation(_alice)).spaceId, '!space:test');
    expect(
      (await loadStartupLocation(_bob)).page,
      NavigationDestinationPage.allChats,
    );
  });
  test('explicit startup choice overrides remembered history and restores across containers', () async {
    await rememberNavigationPage(
      _alice,
      const StartupLocation(NavigationDestinationPage.directMessages),
    );
    for (final page in StartupPage.values.where(
      (page) => page != StartupPage.remember,
    )) {
      final container = ProviderContainer();
      await container.read(startupPageProvider.notifier).setPage(page);
      container.dispose();
      expect((await loadStartupLocation(_alice)).page.name, page.name);
      final restored = ProviderContainer();
      restored.read(startupPageProvider);
      await Future<void>.delayed(Duration.zero);
      expect(restored.read(startupPageProvider), page);
      restored.dispose();
    }
  });
  test('invalid remembered values fall back to all conversations', () async {
    final key = 'last_page_${base64Url.encode(utf8.encode(_alice))}';
    for (final value in [
      'bad-json',
      '[]',
      '{}',
      '{"page":"space"}',
      '{"page":"unknown"}',
    ]) {
      SharedPreferences.setMockInitialValues({key: value});
      expect(
        (await loadStartupLocation(_alice)).page,
        NavigationDestinationPage.allChats,
      );
    }
  });
  test('restore cannot overwrite an early startup setting edit', () async {
    SharedPreferences.setMockInitialValues({'startup_page': 'settings'});
    final container = ProviderContainer();
    await container
        .read(startupPageProvider.notifier)
        .setPage(StartupPage.allChats);
    expect(container.read(startupPageProvider), StartupPage.allChats);
    container.dispose();
  });
}
