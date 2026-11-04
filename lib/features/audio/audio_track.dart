import 'dart:convert';

import 'package:media_kit/media_kit.dart';

import '../../pages/chat/media_preparation.dart';
import '../../pages/chat/prepared_media_source.dart';
import '../../providers/authenticated_media_cache.dart';
import '../../src/rust/api/matrix.dart' as rust;
import 'audio_source_cache.dart';

/// Queue identity never contains serialized media keys or access tokens.
class AudioTrack {
  final String id;
  final String filename;
  final String? url;
  final String? mediaSourceJson;
  final String? roomId;
  final String? messageId;
  final int? durationMs;

  const AudioTrack({
    required this.id,
    required this.filename,
    required this.url,
    required this.mediaSourceJson,
    this.roomId,
    this.messageId,
    this.durationMs,
  });
}

class AudioAccount {
  final String userId;
  final String homeserver;
  final String? accessToken;

  const AudioAccount(this.userId, this.homeserver, this.accessToken);

  bool sameSession(AudioAccount? other) =>
      other?.userId == userId && other?.homeserver == homeserver;
}

/// Unlike a bubble's WidgetRef, these immutable inputs remain valid when the
/// user navigates away. The owning session cancels the preparation on logout.
Future<PreparedMediaSource> prepareAudioTrack(
  AudioTrack track,
  AudioAccount account,
  MediaPreparation preparation, {
  AudioSourceCache? cache,
}) async {
  preparation.throwIfCancelled();
  final source = track.mediaSourceJson == null
      ? null
      : jsonDecode(track.mediaSourceJson!);
  if (source is Map && source.containsKey('file')) {
    Future<PreparedMediaSource> verified(MediaPreparation cancellation) =>
        prepareEncryptedMediaSource(
          track.mediaSourceJson!,
          track.filename,
          expectedUserId: account.userId,
          preparation: cancellation,
        );
    if (cache != null) {
      return cache.prepare(
        key: jsonEncode(['encrypted', source]),
        filename: track.filename,
        preparation: preparation,
        verifiedLoader: verified,
      );
    }
    return verified(preparation);
  }
  final original = source is String
      ? source
      : source is Map && source['url'] is String
      ? source['url'] as String
      : track.url;
  if (original == null || original.isEmpty) {
    throw StateError('Missing audio source');
  }
  final resolved = original.startsWith('mxc://')
      ? await rust.mxcToHttpFull(mxcUrl: original)
      : original;
  preparation.throwIfCancelled();
  if (resolved == null) throw StateError('Audio source unavailable');
  final matrix = isCurrentHomeserverMatrixMediaUrl(
    resolved,
    account.homeserver,
  );
  final headers = matrix && account.accessToken != null
      ? {'Authorization': 'Bearer ${account.accessToken}'}
      : const <String, String>{};
  final scheme = Uri.tryParse(resolved)?.scheme;
  if (matrix ||
      original.startsWith('mxc://') ||
      scheme == 'http' ||
      scheme == 'https') {
    if (cache != null) {
      return cache.prepare(
        key: jsonEncode(['plain', original]),
        filename: track.filename,
        preparation: preparation,
        url: Uri.parse(resolved),
        headers: headers,
      );
    }
    return prepareRemoteMediaSource(
      Uri.parse(resolved),
      track.filename,
      httpHeaders: headers,
      preparation: preparation,
    );
  }
  return PreparedMediaSource(
    media: Media(resolved, httpHeaders: headers),
    cleanup: () async {},
  );
}
