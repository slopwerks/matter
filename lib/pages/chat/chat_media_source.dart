import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../providers/auth_provider.dart';
import '../../providers/authenticated_media_cache.dart';
import '../../providers/chat_provider.dart';
import 'media_preparation.dart';
import 'prepared_media_source.dart';

/// Resolve Matrix media with account-scoped authentication. Native Matrix
/// downloads play from disk because the endpoint need not support byte ranges.
Future<PreparedMediaSource> prepareChatMediaSource({
  required WidgetRef ref,
  required String? url,
  required String? mediaSourceJson,
  required String filename,
  required MediaPreparation preparation,
}) async {
  preparation.throwIfCancelled();
  final account = ref.read(currentUserProvider);
  final source = mediaSourceJson == null ? null : jsonDecode(mediaSourceJson);
  final sourceUrl = source is String
      ? source
      : source is Map && source['url'] is String
      ? source['url'] as String
      : url;
  if (mediaSourceJson != null && source is Map && source.containsKey('file')) {
    if (account == null) throw StateError('No active media account');
    final prepared = await prepareEncryptedMediaSource(
      mediaSourceJson,
      filename,
      expectedUserId: account.id,
      preparation: preparation,
    );
    if (!ref.context.mounted || preparation.isCancelled) {
      await prepared.cleanup();
      throw StateError('Media owner was disposed');
    }
    final current = ref.read(currentUserProvider);
    if (current?.id != account.id ||
        current?.homeserver != account.homeserver) {
      await prepared.cleanup();
      throw StateError('Media account changed');
    }
    return prepared;
  }
  final resolvedUrl = sourceUrl?.startsWith('mxc://') == true
      ? await resolveMxcUrlFull(ref, sourceUrl)
      : sourceUrl;
  if (!ref.context.mounted) throw StateError('Media owner was disposed');
  preparation.throwIfCancelled();
  final current = ref.read(currentUserProvider);
  if (current?.id != account?.id ||
      current?.homeserver != account?.homeserver) {
    throw StateError('Media account changed');
  }
  if (resolvedUrl == null || resolvedUrl.isEmpty) {
    throw StateError('Missing media source');
  }
  final isMatrixMedia = isCurrentHomeserverMatrixMediaUrl(
    resolvedUrl,
    ref.read(currentUserProvider)?.homeserver,
  );
  final token = ref.read(currentAccessTokenProvider);
  final headers = token == null || !isMatrixMedia
      ? const <String, String>{}
      : {'Authorization': 'Bearer $token'};
  if (sourceUrl!.startsWith('mxc://') || isMatrixMedia) {
    return prepareRemoteMediaSource(
      Uri.parse(resolvedUrl),
      filename,
      httpHeaders: headers,
      preparation: preparation,
    );
  }
  return PreparedMediaSource(
    media: Media(resolvedUrl, httpHeaders: headers),
    cleanup: () async {},
  );
}
