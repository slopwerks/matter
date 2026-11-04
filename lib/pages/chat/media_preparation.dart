/// Cancellation belongs to one preparation, including waits before native I/O
/// starts. Removing a listener never cancels an already prepared playing file.
class MediaPreparation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void throwIfCancelled() {
    if (_cancelled) throw StateError('Media preparation cancelled');
  }

  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}
