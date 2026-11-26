/// Ordered navigation candidates for one entry interval, independent of
/// viewport exposure and server auto-read receipts.
class UnreadNavigation {
  UnreadNavigation({
    required this.boundaryResolved,
    Iterable<String> eventIds = const [],
    Iterable<String> unresolvedIds = const [],
    this.complete = false,
  }) {
    addPage(eventIds, unresolvedIds: unresolvedIds, reachedEnd: complete);
  }

  final bool boundaryResolved;
  bool complete;
  final _ids = <String>{};
  final _unresolved = <String>{};
  final _confirmed = <String>{};
  final _excluded = <String>{};

  Iterable<String> get _candidateIds =>
      _ids.where((id) => !_excluded.contains(id));

  String? get firstNavigableId =>
      _candidateIds.where((id) => !_unresolved.contains(id)).firstOrNull;
  int? get candidateCount => boundaryResolved && complete && _unresolved.isEmpty
      ? _candidateIds.length
      : null;
  bool get hasUnresolved => _unresolved.isNotEmpty;
  bool isExcluded(String id) => _excluded.contains(id);

  void addPage(
    Iterable<String> ids, {
    Iterable<String> unresolvedIds = const [],
    required bool reachedEnd,
  }) {
    final pending = unresolvedIds.toSet();
    for (final id in ids) {
      _ids.add(id);
      if (!pending.contains(id)) {
        _confirmed.add(id);
        _unresolved.remove(id);
      }
    }
    for (final id in pending) {
      if (_confirmed.contains(id) || _excluded.contains(id)) continue;
      _ids.add(id);
      _unresolved.add(id);
    }
    complete = reachedEnd;
  }

  void resolve(String id, {required bool candidate}) {
    if (complete && !_ids.contains(id)) return;
    _unresolved.remove(id);
    _confirmed.add(id);
    if (!candidate) _excluded.add(id);
  }

  void exclude(Iterable<String> ids) {
    for (final id in ids) {
      _excluded.add(id);
      _unresolved.remove(id);
    }
  }
}
