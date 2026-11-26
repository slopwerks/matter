import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/unread_navigation.dart';

void main() {
  test(
    'deduplicates pages in order and counts only a complete known interval',
    () {
      final state = UnreadNavigation(boundaryResolved: true);
      state.addPage([], reachedEnd: false);
      expect(state.candidateCount, isNull);
      state.addPage(['a', 'b'], reachedEnd: false);
      expect(state.candidateCount, isNull);
      state.addPage(['b', 'c'], reachedEnd: true);
      expect(state.candidateCount, 3);
      expect(state.firstNavigableId, 'a');
      state.exclude(['a']);
      expect(state.firstNavigableId, 'b');
      expect(state.candidateCount, 2);
    },
  );

  test('an unknown boundary never gives a false exact count', () {
    final state = UnreadNavigation(
      boundaryResolved: false,
      eventIds: ['a'],
      complete: true,
    );
    expect(state.candidateCount, isNull);
    expect(state.firstNavigableId, 'a');
  });

  test('decryption restores original candidate order without counting placeholders', () {
    final state = UnreadNavigation(
      boundaryResolved: true,
      eventIds: ['encrypted', 'text'],
      unresolvedIds: ['encrypted'],
      complete: true,
    );
    expect(state.firstNavigableId, 'text');
    expect(state.candidateCount, isNull);
    state.resolve('encrypted', candidate: true);
    state.addPage(
      ['encrypted'],
      unresolvedIds: ['encrypted'],
      reachedEnd: true,
    );
    expect(state.firstNavigableId, 'encrypted');
    expect(state.candidateCount, 2);
    expect(state.hasUnresolved, isFalse);
  });

  test('excluded events stay excluded even when late pages list them as unresolved', () {
    final state = UnreadNavigation(
      boundaryResolved: true,
      eventIds: ['own', 'ignored', 'redacted', 'a'],
      unresolvedIds: ['ignored'],
      complete: true,
    );
    state.resolve('own', candidate: false);
    state.exclude(['ignored', 'redacted']);
    state.addPage(['ignored'], unresolvedIds: ['ignored'], reachedEnd: true);
    expect(state.candidateCount, 1);
    expect(state.firstNavigableId, 'a');
    expect(state.hasUnresolved, isFalse);
  });

  test(
    'classification before a page preserves decoded and excluded candidates',
    () {
      final state = UnreadNavigation(boundaryResolved: true);
      state.resolve('decoded', candidate: true);
      state.resolve('own', candidate: false);
      state.addPage(
        ['decoded', 'own'],
        unresolvedIds: ['decoded', 'own'],
        reachedEnd: true,
      );
      expect(state.candidateCount, 1);
      expect(state.firstNavigableId, 'decoded');
      state.resolve('outside', candidate: true);
      expect(state.candidateCount, 1);
    },
  );

  test(
    'tracks excluded targets and reports zero candidates when all are excluded',
    () {
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['a', 'b'],
        complete: true,
      );
      expect(state.isExcluded('a'), isFalse);
      state.resolve('a', candidate: false);
      state.exclude(['b']);
      expect(state.isExcluded('a'), isTrue);
      expect(state.isExcluded('b'), isTrue);
      expect(state.firstNavigableId, isNull);
      expect(state.candidateCount, 0);
      expect(state.hasUnresolved, isFalse);
    },
  );

  test(
    'hasUnresolvedBefore ignores unresolved events newer than the target',
    () {
      final state = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['a', 'utd-after'],
        unresolvedIds: ['utd-after'],
        complete: true,
      );
      expect(state.firstNavigableId, 'a');
      expect(state.hasUnresolved, isTrue);
      expect(state.hasUnresolvedBefore('a'), isFalse);

      final preceded = UnreadNavigation(
        boundaryResolved: true,
        eventIds: ['utd-before', 'b'],
        unresolvedIds: ['utd-before'],
        complete: true,
      );
      expect(preceded.firstNavigableId, 'b');
      expect(preceded.hasUnresolvedBefore('b'), isTrue);
    },
  );
}
