import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Reading progress for one frozen entry interval, independent of server
/// auto-read receipts and message timestamps.
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
  final _seen = <String>{};
  final _excluded = <String>{};
  final _exposure = <String, _Exposure>{};

  Iterable<String> get remainingIds =>
      _ids.where((id) => !_seen.contains(id) && !_excluded.contains(id));

  String? get firstRemainingId => remainingIds.firstOrNull;
  String? get firstNavigableId =>
      remainingIds.where((id) => !_unresolved.contains(id)).firstOrNull;
  int? get remainingCount => boundaryResolved && complete && _unresolved.isEmpty
      ? remainingIds.length
      : null;
  bool get hasRemaining => remainingIds.isNotEmpty;
  bool get hasUnresolved => _unresolved.isNotEmpty;

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
      if (_confirmed.contains(id)) continue;
      _ids.add(id);
      _unresolved.add(id);
      // Looking at a decryption placeholder does not read the later body.
      _seen.remove(id);
      _exposure.remove(id);
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
      _exposure.remove(id);
    }
  }

  /// Measure message content, not built/cache rows. For an oversized message,
  /// accumulate exposed vertical intervals until its entire body was visible.
  bool observe(Map<String, Rect> messages, Rect readableViewport) {
    if (readableViewport.isEmpty) return false;
    var changed = false;
    for (final entry in messages.entries) {
      final id = entry.key;
      if ((complete && !_ids.contains(id)) ||
          _seen.contains(id) ||
          _excluded.contains(id) ||
          _unresolved.contains(id)) {
        continue;
      }
      final rect = entry.value;
      if (rect.isEmpty ||
          rect.left < readableViewport.left - 0.5 ||
          rect.right > readableViewport.right + 0.5) {
        continue;
      }
      final top = math.max(rect.top, readableViewport.top);
      final bottom = math.min(rect.bottom, readableViewport.bottom);
      if (bottom <= top) continue;
      // While classification is in flight, remember real decoded content
      // that was already exposed. A late page must not resurrect it.
      _confirmed.add(id);
      var exposure = _exposure[id];
      if (exposure == null || (exposure.height - rect.height).abs() > 0.5) {
        exposure = _Exposure(rect.height);
        _exposure[id] = exposure;
      }
      exposure.add(top - rect.top, bottom - rect.top);
      if (exposure.complete) {
        _seen.add(id);
        _exposure.remove(id);
        changed = true;
      }
    }
    return changed;
  }

  /// The first unexposed vertical coordinate within a long message.
  double firstUnseenOffset(String id) => _exposure[id]?.firstGap ?? 0;
}

class _Exposure {
  _Exposure(this.height);
  final double height;
  final _intervals = <(double, double)>[];

  void add(double start, double end) {
    _intervals.add((start, end));
    _intervals.sort((a, b) => a.$1.compareTo(b.$1));
    var index = 0;
    while (index + 1 < _intervals.length) {
      final current = _intervals[index];
      final next = _intervals[index + 1];
      if (next.$1 <= current.$2 + 0.5) {
        _intervals[index] = (current.$1, math.max(current.$2, next.$2));
        _intervals.removeAt(index + 1);
      } else {
        index++;
      }
    }
  }

  bool get complete =>
      _intervals.length == 1 &&
      _intervals.single.$1 <= 0.5 &&
      _intervals.single.$2 >= height - 0.5;

  double get firstGap => _intervals.isNotEmpty && _intervals.first.$1 <= 0.5
      ? _intervals.first.$2
      : 0;
}
