import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ordinary playback speed and held speed are independent user preferences.
class VideoPreferences extends ChangeNotifier {
  static const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
  static const heldSpeeds = [1.5, 2.0, 2.5, 3.0];
  static const _speedKey = 'video_playback_speed';
  static const _heldKey = 'video_hold_speed';

  double speed = 1;
  double heldSpeed = 2;
  bool _speedEdited = false;
  bool _heldEdited = false;
  bool _disposed = false;
  Future<void> _writes = Future.value();

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    if (_disposed) return;
    final savedSpeed = preferences.getDouble(_speedKey);
    final savedHeld = preferences.getDouble(_heldKey);
    if (!_speedEdited && speeds.contains(savedSpeed)) speed = savedSpeed!;
    if (!_heldEdited && heldSpeeds.contains(savedHeld)) heldSpeed = savedHeld!;
    notifyListeners();
  }

  Future<void> setSpeed(double value) {
    if (!speeds.contains(value)) throw ArgumentError.value(value, 'speed');
    speed = value;
    _speedEdited = true;
    notifyListeners();
    return _save(_speedKey, value);
  }

  Future<void> setHeldSpeed(double value) {
    if (!heldSpeeds.contains(value)) {
      throw ArgumentError.value(value, 'heldSpeed');
    }
    heldSpeed = value;
    _heldEdited = true;
    notifyListeners();
    return _save(_heldKey, value);
  }

  Future<void> _save(String key, double value) => _writes = _writes
      .then((_) async {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setDouble(key, value);
      })
      .catchError((Object _) {
        // A preference write failure must not interrupt playback controls.
      });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
