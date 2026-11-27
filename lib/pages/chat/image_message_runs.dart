import '../../src/rust/api/matrix.dart' as rust;
import 'chat_timestamp.dart';

class ChatImageRun {
  final List<rust.ChatMessage> messages;
  final bool album;

  ChatImageRun(this.messages, {this.album = false});
  bool get collection => album || messages.length > 1;
}

bool isChatImage(rust.ChatMessage message) =>
    message.msgType == rust.MessageType.image &&
    (message.imageUrl != null || message.mediaSourceJson != null) &&
    !message.id.startsWith('local_outgoing_');

(String, String) _imageDescription(rust.ChatMessage message) {
  final text = (message.caption ?? message.sharedCaption ?? '').trim();
  return (
    text,
    text.isEmpty ? '' : (message.captionFormattedBody ?? '').trim(),
  );
}

bool _adjacentImages(rust.ChatMessage previous, rust.ChatMessage message) {
  final timestamp = int.tryParse(message.timestamp);
  final previousTimestamp = int.tryParse(previous.timestamp);
  return isChatImage(previous) &&
      isChatImage(message) &&
      message.senderId == previous.senderId &&
      message.isMe == previous.isMe &&
      message.inReplyTo == previous.inReplyTo &&
      _imageDescription(message) == _imageDescription(previous) &&
      chatDateKey(message.timestamp) == chatDateKey(previous.timestamp) &&
      timestamp != null &&
      previousTimestamp != null &&
      timestamp >= previousTimestamp &&
      timestamp - previousTimestamp <= 300000;
}

/// Album membership is explicit. Independent images only fold across adjacent
/// messages with matching descriptions, from the same sender, on the same day,
/// at most five minutes apart.
List<ChatImageRun> chatImageRuns(List<rust.ChatMessage> messages) {
  final roots = {
    for (final message in messages)
      if (isChatImage(message) && message.imageMetadata?.albumRoot != null)
        (message.senderId, message.imageMetadata!.albumRoot!),
  };
  String? rootOf(rust.ChatMessage message) => !isChatImage(message)
      ? null
      : message.imageMetadata?.albumRoot ??
            (roots.contains((message.senderId, message.id))
                ? message.id
                : null);
  final albums = <(String, String), List<rust.ChatMessage>>{};
  for (final message in messages) {
    final root = rootOf(message);
    if (root != null) {
      albums.putIfAbsent((message.senderId, root), () => []).add(message);
    }
  }
  // Older Matter batches carry a shared caption on each image, with a
  // standard caption on the final image. That final caption ends the batch,
  // even when the next album has the same description.
  final legacyAlbums = <String, List<rust.ChatMessage>>{};
  var pending = <rust.ChatMessage>[];
  void finishLegacyAlbum() {
    if (pending.length > 1) {
      for (final message in pending) {
        legacyAlbums[message.id] = pending;
      }
    }
    pending = [];
  }

  for (final message in messages) {
    final caption = message.sharedCaption?.trim();
    if (!isChatImage(message) ||
        rootOf(message) != null ||
        caption == null ||
        caption.isEmpty) {
      finishLegacyAlbum();
      continue;
    }
    if (pending.isNotEmpty &&
        (!_adjacentImages(pending.last, message) ||
            pending.last.sharedCaption?.trim() != caption)) {
      finishLegacyAlbum();
    }
    pending.add(message);
    if (message.caption?.trim().isNotEmpty == true) finishLegacyAlbum();
  }
  finishLegacyAlbum();

  final emitted = <(String, String)>{};
  final runs = <ChatImageRun>[];
  var adjacent = false;
  for (final message in messages) {
    final root = rootOf(message);
    if (root != null) {
      final key = (message.senderId, root);
      if (emitted.add(key)) runs.add(ChatImageRun(albums[key]!, album: true));
      adjacent = false;
      continue;
    }
    final legacyAlbum = legacyAlbums[message.id];
    if (legacyAlbum != null) {
      if (legacyAlbum.first.id == message.id) {
        runs.add(ChatImageRun(legacyAlbum, album: true));
      }
      adjacent = false;
      continue;
    }
    final previous = runs.isEmpty ? null : runs.last;
    final last = previous?.messages.last;
    if (adjacent &&
        previous != null &&
        !previous.album &&
        last != null &&
        _adjacentImages(last, message)) {
      previous.messages.add(message);
    } else {
      runs.add(ChatImageRun([message]));
    }
    adjacent = isChatImage(message);
  }
  return runs;
}
