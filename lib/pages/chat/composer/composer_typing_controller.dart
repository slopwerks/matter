import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/auth_provider.dart';
import '../../../src/rust/api/matrix.dart' as rust;

/// Inline typing lifecycle: idle timeout, periodic keep-alive and correction
/// when an older start arrives after a newer stop. Bound to its opening account.
class ComposerTypingController {
  ComposerTypingController({required this.userId, required this.roomId});

  final String userId;
  final String roomId;
  Timer? _idleTimer;
  Timer? _keepAliveTimer;
  bool _typing = false;
  int _sequence = 0;
  bool _inFlight = false;

  void activity() {
    if (!_typing) {
      _typing = true;
      _send(true, force: true);
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_typing) _send(true);
      });
    }
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 3), stop);
  }

  void stop() {
    if (_typing) {
      _typing = false;
      _send(false);
    }
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  void _send(bool typing, {bool force = false}) {
    // Starts and stops always go out. Coalesce only periodic keep-alives;
    // a stale completion must not release a newer request's in-flight guard.
    if (!force && _inFlight && typing) return;
    _inFlight = true;
    final sequence = ++_sequence;
    rust
        .sendTypingNotice(accountUserId: userId, roomId: roomId, typing: typing)
        .whenComplete(() {
          if (sequence == _sequence) {
            _inFlight = false;
          } else if (typing && !_typing) {
            _send(false);
          }
        })
        .catchError((error) => debugPrint('sendTypingNotice failed: $error'));
  }

  void dispose() {
    _idleTimer?.cancel();
    _keepAliveTimer?.cancel();
    stop();
  }
}

/// A full-screen editor owns its own idle timer and may outlive the inline
/// input. Unlike the inline sender, detached notices check the active account.
class DetachedComposerTyping {
  DetachedComposerTyping({
    required this.container,
    required this.roomId,
    required this.userId,
  });

  final ProviderContainer container;
  final String roomId;
  final String userId;
  Timer? _keepAliveTimer;
  bool _typing = false;
  bool _noticeInFlight = false;
  int _noticeSequence = 0;

  void setTyping(bool typing) {
    if (typing) {
      if (_typing || container.read(activeUserIdProvider) != userId) return;
      _typing = true;
      _send(true, force: true);
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_typing) _send(true);
      });
      return;
    }
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (!_typing) return;
    _typing = false;
    _send(false);
  }

  void _send(bool typing, {bool force = false}) {
    if (container.read(activeUserIdProvider) != userId) return;
    if (!force && typing && _noticeInFlight) return;
    _noticeInFlight = true;
    final sequence = ++_noticeSequence;
    rust
        .sendTypingNotice(accountUserId: userId, roomId: roomId, typing: typing)
        .whenComplete(() {
          if (sequence == _noticeSequence) {
            _noticeInFlight = false;
          } else if (typing && !_typing) {
            _send(false);
          }
        })
        .catchError((error) => debugPrint('sendTypingNotice failed: $error'));
  }
}
