import 'dart:async';

import '../../pages/chat/media_preparation.dart';
import '../../pages/chat/prepared_media_source.dart';

/// Browser Blob behaviour stays bounded by the existing media loader. Native
/// platforms use the file/loopback cache; a web Rust player is not shipped yet.
class AudioSourceCache {
  int _epoch = 0;
  bool _closed = false;
  String? _account;
  AudioSourceCache({int maxBytes = 256 * 1024 * 1024});

  void selectAccount(String? userId, String? homeserver) {
    final next = userId == null ? null : '$userId@$homeserver';
    if (next != _account) {
      _account = next;
      _epoch++;
    }
  }

  Future<void> get released async {}

  Future<PreparedMediaSource> prepare({
    required String key,
    required String filename,
    required MediaPreparation preparation,
    Uri? url,
    Map<String, String> headers = const {},
    Future<PreparedMediaSource> Function(MediaPreparation)? verifiedLoader,
  }) async {
    final epoch = _epoch;
    preparation.throwIfCancelled();
    if (_closed || _account == null) {
      throw StateError('No active audio account');
    }
    final source = verifiedLoader != null
        ? await verifiedLoader(preparation)
        : await prepareRemoteMediaSource(
            url!,
            filename,
            httpHeaders: headers,
            preparation: preparation,
          );
    if (_closed || epoch != _epoch || preparation.isCancelled) {
      await source.cleanup();
      throw StateError('Audio owner changed');
    }
    return source;
  }

  Future<void> close() async {
    _closed = true;
  }
}
