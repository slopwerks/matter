import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matter/providers/disabled_sticker_packs_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _account = '@busyo:example.org';
const _scope = (account: _account);

void main() {
  test('switching a pack off is remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(
      disabledStickerPacksProvider(_scope).notifier,
    );

    await notifier.setEnabled('room:!a:example.org:cats', false);
    expect(container.read(disabledStickerPacksProvider(_scope)), {
      'room:!a:example.org:cats',
    });

    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('chat_disabled_sticker_packs:$_account'), [
      'room:!a:example.org:cats',
    ]);
  });

  test('a stored choice is restored and can be switched back on', () async {
    SharedPreferences.setMockInitialValues({
      'chat_disabled_sticker_packs:$_account': <String>[
        'room:!a:example.org:cats',
      ],
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(
      disabledStickerPacksProvider(_scope).notifier,
    );

    await Future<void>.delayed(Duration.zero);
    expect(container.read(disabledStickerPacksProvider(_scope)), {
      'room:!a:example.org:cats',
    });

    await notifier.setEnabled('room:!a:example.org:cats', true);
    expect(container.read(disabledStickerPacksProvider(_scope)), isEmpty);
  });
}
