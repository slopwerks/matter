import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/connection_provider.dart';

void main() {
  group('connection label provider', () {
    test('maps every connection state to a Chinese label', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      for (final state in AppConnectionState.values) {
        container.read(connectionProvider.notifier).value = state;
        final label = container.read(connectionLabelProvider);
        switch (state) {
          case AppConnectionState.connected:
            expect(label, '');
          case AppConnectionState.connecting:
            expect(label, '连接中…');
          case AppConnectionState.updating:
            expect(label, '同步中…');
          case AppConnectionState.disconnected:
            expect(label, '已断开');
          case AppConnectionState.sessionExpired:
            expect(label, '登录已失效，请重新登录');
        }
      }
    });

    test('connection color provider returns null for all states', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      for (final state in AppConnectionState.values) {
        container.read(connectionProvider.notifier).value = state;
        expect(container.read(connectionColorProvider), isNull);
      }
    });
  });
}
