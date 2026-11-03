import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/unread_navigation.dart';

void main() {
  const viewport = Rect.fromLTRB(0, 100, 400, 600);

  test(
    'counts actual IDs after complete enumeration, never a notification count',
    () {
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['a'],
        complete: false,
      );
      expect(state.remainingCount, isNull);
      state.addPage(['a', 'b'], reachedEnd: true);
      expect(state.remainingCount, 2);
      state.observe({'a': const Rect.fromLTRB(20, 200, 200, 250)}, viewport);
      expect(state.remainingCount, 1);
      expect(state.firstRemainingId, 'b');
      state.observe({'a': const Rect.fromLTRB(20, 200, 200, 250)}, viewport);
      expect(state.remainingCount, 1);
    },
  );

  test('one and several fully visible unread messages all disappear without thresholds', () {
    for (final count in [1, 3, 7]) {
      final ids = List.generate(count, (i) => '$i');
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ids,
        complete: true,
      );
      state.observe({
        for (var i = 0; i < count; i++)
          '$i': Rect.fromLTWH(20, 110 + i * 60, 200, 40),
      }, viewport);
      expect(state.remainingCount, 0);
      expect(state.hasRemaining, isFalse);
    }
  });

  test('header, composer and off-screen built rows do not count as seen', () {
    final state = UnreadNavigation(
      boundaryResolved: true,
      eventIds: ['header', 'input', 'cache', 'visible'],
      complete: true,
    );
    state.observe({
      'header': const Rect.fromLTRB(20, 70, 200, 120),
      'input': const Rect.fromLTRB(20, 580, 200, 630),
      'cache': const Rect.fromLTRB(20, -200, 200, -150),
      'visible': const Rect.fromLTRB(20, 200, 200, 250),
    }, viewport);
    expect(state.remainingCount, 3);
    state.observe({'header': const Rect.fromLTRB(20, 110, 200, 160)}, viewport);
    expect(state.remainingCount, 2);
  });

  test('a single long message stays unread until every vertical interval was exposed', () {
    final state = UnreadNavigation(
      boundaryResolved: true,
      eventIds: ['long'],
      complete: true,
    );
    state.observe({'long': const Rect.fromLTWH(20, -400, 200, 1000)}, viewport);
    expect(state.remainingCount, 1);
    expect(state.firstUnseenOffset('long'), 0);
    state.observe({'long': const Rect.fromLTWH(20, 100, 200, 1000)}, viewport);
    expect(state.remainingCount, 0);
    state.addPage(['long'], reachedEnd: true);
    expect(state.remainingCount, 0);
  });

  test(
    'gaps between exposed parts of a long message are not treated as read',
    () {
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['long'],
        complete: true,
      );
      state.observe({
        'long': const Rect.fromLTWH(20, 100, 200, 1500),
      }, viewport);
      state.observe({
        'long': const Rect.fromLTWH(20, -900, 200, 1500),
      }, viewport);
      expect(state.remainingCount, 1);
      expect(state.firstUnseenOffset('long'), 500);
      state.observe({
        'long': const Rect.fromLTWH(20, -400, 200, 1500),
      }, viewport);
      expect(state.remainingCount, 0);
    },
  );

  test(
    'a fractional gap must actually be exposed, not rounded into read content',
    () {
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['long'],
        complete: true,
      );
      state.observe({
        'long': const Rect.fromLTWH(20, 100, 200, 1000),
      }, viewport);
      state.observe({
        'long': const Rect.fromLTWH(20, -400.9, 200, 1000),
      }, viewport);
      expect(state.remainingCount, 1);
      expect(state.firstUnseenOffset('long'), 500);
      state.observe({
        'long': const Rect.fromLTWH(20, -150, 200, 1000),
      }, viewport);
      expect(state.remainingCount, 0);
    },
  );

  test('layout height changes reset partial exposure rather than filling unseen content', () {
    final state = UnreadNavigation(
      boundaryResolved: true,
      eventIds: ['image'],
      complete: true,
    );
    state.observe({
      'image': const Rect.fromLTWH(20, -400, 200, 1000),
    }, viewport);
    state.observe({'image': const Rect.fromLTWH(20, 100, 200, 1500)}, viewport);
    expect(state.remainingCount, 1);
  });

  test(
    'an unresolved boundary or decryption never gives a false exact count',
    () {
      final unknownBoundary = UnreadNavigation(
        boundaryResolved: false,
        eventIds: ['a'],
        complete: true,
      );
      expect(unknownBoundary.remainingCount, isNull);
      final encrypted = UnreadNavigation(
        boundaryResolved: true,
        unresolvedIds: ['utd'],
        complete: true,
      );
      encrypted.observe({
        'utd': const Rect.fromLTRB(20, 200, 200, 250),
      }, viewport);
      expect(encrypted.hasRemaining, isTrue);
      expect(encrypted.remainingCount, isNull);
      encrypted.resolve('utd', candidate: true);
      expect(encrypted.remainingCount, 1);
      encrypted.observe({
        'utd': const Rect.fromLTRB(20, 200, 200, 250),
      }, viewport);
      expect(encrypted.remainingCount, 0);
    },
  );

  test(
    'ignored, redacted and own events do not become unread navigation targets',
    () {
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['own', 'ignored', 'redacted', 'a'],
        complete: true,
      );
      state.exclude(['own', 'ignored']);
      state.resolve('redacted', candidate: false);
      expect(state.remainingCount, 1);
      expect(state.firstRemainingId, 'a');
    },
  );

  test(
    'unknown candidates retain raw order and cannot be read as placeholders',
    () {
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['encrypted', 'text'],
        unresolvedIds: ['encrypted'],
        complete: true,
      );
      expect(state.firstRemainingId, 'encrypted');
      expect(state.firstNavigableId, 'text');
      state.observe({
        'encrypted': const Rect.fromLTRB(20, 200, 200, 250),
      }, viewport);
      expect(state.remainingCount, isNull);
      expect(state.firstRemainingId, 'encrypted');
      state.resolve('encrypted', candidate: true);
      expect(state.firstNavigableId, 'encrypted');
      expect(state.remainingCount, 2);
    },
  );

  test(
    'a stale undecryptable duplicate cannot downgrade an already read body',
    () {
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['a'],
        complete: true,
      );
      state.observe({'a': const Rect.fromLTRB(20, 200, 200, 250)}, viewport);
      state.addPage(['a'], unresolvedIds: ['a'], reachedEnd: true);
      expect(state.remainingCount, 0);
      expect(state.hasRemaining, isFalse);
    },
  );

  test('excluding an ignored unknown candidate does not block the exact remaining count', () {
    final state = UnreadNavigation(
      boundaryResolved: true,
      eventIds: ['ignored', 'a'],
      unresolvedIds: ['ignored'],
      complete: true,
    );
    state.exclude(['ignored']);
    expect(state.remainingCount, 1);
  });

  test('unread end to end remembers visible content before async unread classification', () {
    final state = UnreadNavigation(boundaryResolved: true);
    state.observe({
      'seen-before-page': const Rect.fromLTRB(20, 200, 200, 250),
    }, viewport);
    state.addPage(['seen-before-page', 'still-offscreen'], reachedEnd: true);
    expect(state.remainingCount, 1);
    expect(state.firstRemainingId, 'still-offscreen');
  });

  test('unread end to end late unresolved duplicate cannot resurrect a decoded seen body', () {
    final state = UnreadNavigation(boundaryResolved: true);
    state.observe({
      'decoded': const Rect.fromLTRB(20, 200, 200, 250),
    }, viewport);
    state.addPage(['decoded'], unresolvedIds: ['decoded'], reachedEnd: true);
    expect(state.remainingCount, 0);
    expect(state.hasRemaining, isFalse);
  });

  test('an empty incomplete page does not declare the interval complete', () {
    final state = UnreadNavigation(boundaryResolved: true);
    state.addPage([], reachedEnd: false);
    expect(state.remainingCount, isNull);
    state.addPage(['later'], reachedEnd: true);
    expect(state.remainingCount, 1);
  });
}
