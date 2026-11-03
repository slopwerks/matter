import 'dart:async';

/// One result refresh in flight, with bounded coalescing of history updates.
/// History downloads never await this queue; a final request flushes it.
class SearchResultsRefresh {
  SearchResultsRefresh({required this.refresh, required this.onError});

  final Future<void> Function() refresh;
  final void Function(Object) onError;
  static const _interval = Duration(milliseconds: 120);
  Timer? _timer;
  bool _running = false;
  bool _dirty = false;
  bool _immediate = false;
  bool _started = false;
  bool _disposed = false;

  bool get hasPending => _running || _dirty || _timer != null;

  void request({bool immediate = false}) {
    if (_disposed) return;
    _dirty = true;
    _immediate |= immediate;
    if (_running) return;
    if (!_started || _immediate) {
      _timer?.cancel();
      _timer = null;
      unawaited(_run());
    } else {
      _timer ??= Timer(_interval, () {
        _timer = null;
        unawaited(_run());
      });
    }
  }

  Future<void> _run() async {
    if (_disposed || _running || !_dirty) return;
    _started = true;
    _dirty = false;
    _immediate = false;
    _running = true;
    try {
      await refresh();
    } catch (error) {
      _dirty = false;
      _immediate = false;
      if (!_disposed) onError(error);
    } finally {
      _running = false;
      if (!_disposed && _dirty) request(immediate: _immediate);
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _dirty = false;
  }
}
