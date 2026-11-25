import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/disabled_sticker_packs_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' show StickerPackKey;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('hidden packs retain source and raw key across restart, scoped to account and room', () async {
    SharedPreferences.setMockInitialValues({});
    const scope = (account: '@alice:e', roomId: '!here:e');
    final provider = disabledStickerPacksProvider(scope);
    const keys = [
      StickerPackKey(roomId: '!source:e', stateKey: ''),
      StickerPackKey(roomId: '!source:e', stateKey: ' : '),
      StickerPackKey(roomId: '!other:e', stateKey: ''),
    ];
    final first = ProviderContainer();
    await first.read(provider.future);
    for (final key in keys) {
      await first.read(provider.notifier).setEnabled(key, false);
    }
    first.dispose();
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    expect(await restored.read(provider.future), keys.toSet());
    for (final other in [
      (account: '@bob:e', roomId: scope.roomId),
      (account: scope.account, roomId: '!else:e'),
    ]) {
      expect(
        await restored.read(disabledStickerPacksProvider(other).future),
        isEmpty,
      );
    }
    await restored.read(provider.notifier).setEnabled(keys.first, true);
    expect(restored.read(provider).requireValue, keys.skip(1).toSet());
  });
}
