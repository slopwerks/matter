import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/managed_media.dart';
import '../../features/storage/storage_models.dart';
import '../../providers/auth_provider.dart';
import 'prepared_media_source.dart';

Future<PreparedMediaSource?> cachedChatMediaSource({
  required WidgetRef ref,
  required String? url,
  required String? mediaSourceJson,
  required String filename,
  String? roomId,
  StorageKind kind = StorageKind.video,
}) async {
  final user = ref.read(currentUserProvider);
  if (user == null) return null;
  final account = storageAccountKey(user.id, user.homeserver);
  final source = await cachedManagedMedia(
    account: account,
    key: mediaSourceJson ?? url ?? '',
    filename: filename,
    kind: kind,
    owner: roomId == null ? null : StorageOwner(account, roomId),
  );
  final current = ref.context.mounted ? ref.read(currentUserProvider) : null;
  if (current?.id != user.id || current?.homeserver != user.homeserver) {
    await source?.cleanup();
    throw StateError('Media account changed');
  }
  return source;
}
