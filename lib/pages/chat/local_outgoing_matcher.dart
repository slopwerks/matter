import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import 'send_flight.dart';

/// Result of matching local outgoing messages with their remote counterparts.
class LocalOutgoingMatchResult {
  /// Ids of local messages that should be removed because their remote
  /// counterpart has arrived.
  final Set<String> localIds;

  /// Maps a remote event id to the stable flight id of the local message it
  /// replaced. This lets the [SendFlightTarget] state survive the local-to-
  /// remote id transition so the animation can follow the message to its final
  /// position.
  final Map<String, String> remoteToLocalFlightId;

  /// Maps a remote event id to the local optimistic timestamp it replaced.
  /// While a send is being reconciled, this keeps the visible message order
  /// aligned with the user's send order instead of briefly switching to server
  /// timestamp / event-id ordering.
  final Map<String, int> remoteToLocalSortTimestamp;

  LocalOutgoingMatchResult(
    this.localIds,
    this.remoteToLocalFlightId,
    this.remoteToLocalSortTimestamp,
  );
}

/// Whether an optimistic media bubble is the same upload as a server event.
///
/// Stickers and re-sent media carry an `mxc://` source before they are sent,
/// so the source URI identifies them exactly. An image picked for upload does
/// not: it has no `mxc://` until the homeserver finishes the upload, and the
/// echo therefore only matches on the metadata the uploader already knew
/// (filename, declared MIME type, and dimensions).
bool _sameMediaPayload(ChatMessage remote, LocalOutgoingMessage local) {
  final localUrl = local.sourceImageUrl;
  if (localUrl != null) return remote.imageUrl == localUrl;
  return remote.filename == local.message.filename &&
      remote.mimeType == local.message.mimeType &&
      remote.imageWidth == local.message.imageWidth &&
      remote.imageHeight == local.message.imageHeight;
}

/// Matches local outgoing messages with their corresponding remote events.
///
/// [consumedRemoteIds] tracks remote events that have already been matched in
/// previous calls, preventing duplicate sends of the same payload from being
/// collapsed onto the same remote event.
///
/// Locals are processed in chronological order and each is matched to the
/// earliest unconsumed remote with the same payload and a plausible timestamp.
/// This preserves send ordering for alternating or rapid consecutive sends.
LocalOutgoingMatchResult matchLocalOutgoingMessages(
  List<ChatMessage> latestMessages,
  List<LocalOutgoingMessage> localMessages,
  Set<String> consumedRemoteIds,
) {
  final ids = <String>{};
  final remoteToLocalFlightId = <String, String>{};
  final remoteToLocalSortTimestamp = <String, int>{};

  // Sort remotes by timestamp so we consider the earliest remote first.
  final remotes =
      latestMessages
          .where(
            (remote) => remote.isMe && !consumedRemoteIds.contains(remote.id),
          )
          .toList()
        ..sort((a, b) {
          final aTime = int.tryParse(a.timestamp) ?? 0;
          final bTime = int.tryParse(b.timestamp) ?? 0;
          return aTime.compareTo(bTime);
        });

  for (final local in localMessages) {
    // A failed message never produced a remote event, so it can never have
    // a remote counterpart. Matching one anyway would consume the echo of a
    // LATER successful send of the same content: the failed bubble would
    // vanish and the successful send's bubble would stay unreconciled
    // forever (a ghost with no delete entry).
    if (local.message.id.startsWith(localOutgoingFailedPrefix)) continue;
    final localTime = int.tryParse(local.message.timestamp) ?? 0;
    ChatMessage? matched;
    for (final remote in remotes) {
      if (consumedRemoteIds.contains(remote.id)) continue;
      final remoteTime = int.tryParse(remote.timestamp) ?? 0;
      final isLocalMedia =
          local.message.msgType == MessageType.image ||
          local.message.msgType == MessageType.sticker;
      final samePayload = isLocalMedia
          ? remote.msgType == local.message.msgType &&
                _sameMediaPayload(remote, local)
          : remote.msgType == MessageType.text &&
                remote.content == local.message.content &&
                remote.inReplyTo == local.message.inReplyTo;
      if (samePayload &&
          remoteTime >= localTime - 60000 &&
          remoteTime <= localTime + 300000) {
        matched = remote;
        break;
      }
    }
    if (matched != null) {
      final localId = local.message.id;
      ids.add(localId);
      consumedRemoteIds.add(matched.id);
      remoteToLocalFlightId[matched.id] = sendFlightId(localId);
      remoteToLocalSortTimestamp[matched.id] = localTime;
    }
  }

  return LocalOutgoingMatchResult(
    ids,
    remoteToLocalFlightId,
    remoteToLocalSortTimestamp,
  );
}
