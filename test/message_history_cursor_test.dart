import 'package:flutter_test/flutter_test.dart';
import 'package:matter/providers/message_history_cursor.dart';

void main() {
  test('starts at the live window, not the oldest display cache', () {
    final cursor = const MessageHistoryCursor().refreshed(['301', '302']);
    expect(cursor.anchorId, '301');
    expect(cursor.reachedStart, isFalse);
  });

  test('known pages advance the cursor even without new display messages', () {
    final cursor = const MessageHistoryCursor()
        .refreshed(['301', '302'])
        .advanced(['201', '202']);
    expect(cursor.anchorId, '201');
    expect(cursor.reachedStart, isFalse);
  });

  test('overlapping live refresh preserves historical progress', () {
    final cursor = const MessageHistoryCursor()
        .refreshed(['301', '302'])
        .advanced(['201', '202'])
        .refreshed(['302', '303']);
    expect(cursor.anchorId, '201');
    expect(cursor.generation, 1);
  });

  test('a disconnected live refresh reopens pagination at the new gap', () {
    final cursor = const MessageHistoryCursor()
        .refreshed(['301', '302'])
        .advanced([])
        .refreshed(['501', '502']);
    expect(cursor.anchorId, '501');
    expect(cursor.connectedEventIds, {'501', '502'});
    expect(cursor.reachedStart, isFalse);
    expect(cursor.generation, 2);
  });

  test('unchanged live ids do not reopen exhausted focused pagination', () {
    final cursor = const MessageHistoryCursor().refreshed(['301', '302']);
    expect(identical(cursor.refreshed(['301', '302']), cursor), isTrue);
  });

  test(
    'joining older context preserves all connected events and its anchor',
    () {
      final cursor = const MessageHistoryCursor().refreshed(['301', '302']);
      final joined = cursor.joined(
        ['201', '202', '301'],
        oldestEventId: '201',
        hitStart: false,
      );
      expect(joined.anchorId, '201');
      expect(joined.connectedEventIds, {'201', '202', '301', '302'});
      expect(joined.generation, cursor.generation);
      expect(joined.reachedStart, isFalse);
    },
  );

  test(
    'joining an interior context retains the deeper live history anchor',
    () {
      final cursor = const MessageHistoryCursor().refreshed([
        '201',
        '202',
        '301',
      ]);
      final joined = cursor.joined(
        ['202', '301'],
        oldestEventId: '202',
        hitStart: false,
      );
      expect(joined.anchorId, '201');
    },
  );

  test('empty refresh preserves progress and empty page ends history', () {
    final cursor = const MessageHistoryCursor()
        .refreshed(['301', '302'])
        .refreshed([])
        .advanced([]);
    expect(cursor.anchorId, '301');
    expect(cursor.reachedStart, isTrue);
  });
}
