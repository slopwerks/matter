import '../../../src/rust/api/matrix.dart';
import '../chat_timestamp.dart';
import '../image_message_runs.dart';

/// A render block inside a sender/day cluster. Long clusters may occupy
/// several blocks; their joining flags keep bubble corners and spacing intact.
class MessageGroup {
  final String senderId;
  final String senderName;
  final bool isMe;
  final List<ChatMessage> messages;
  final bool startsCluster;
  bool endsCluster;
  final List<ChatImageRun>? imageRuns;

  MessageGroup({
    required this.senderId,
    required this.senderName,
    required this.isMe,
    required this.messages,
    this.startsCluster = true,
    this.endsCluster = true,
    this.imageRuns,
  });
}

/// Preserve the image run at the reading origin when newly loaded images
/// would otherwise join it. Explicit albums can span interleaved messages:
/// freeze their actual members, not every message in a timestamp interval.
List<ChatImageRun> _timelineImageRuns(
  List<ChatMessage> messages, {
  required String Function(ChatMessage) layoutId,
  Set<String> pivotRunIds = const {},
  bool pivotAlbum = false,
}) {
  final runs = chatImageRuns(messages);
  if (pivotRunIds.isEmpty) return runs;
  bool anchored(ChatMessage message) => pivotRunIds.contains(layoutId(message));
  final frozen = messages.where(anchored).toList();
  final result = <ChatImageRun>[];
  var emitted = false;
  for (final run in runs) {
    final first = run.messages.indexWhere(anchored);
    if (first < 0) {
      result.add(run);
      continue;
    }
    final before = run.messages.take(first).toList();
    final after = run.messages
        .skip(first)
        .where((message) => !anchored(message))
        .toList();
    if (before.isNotEmpty) result.add(ChatImageRun(before, album: run.album));
    if (!emitted) {
      result.add(ChatImageRun(frozen, album: pivotAlbum));
      emitted = true;
    }
    if (after.isNotEmpty) result.add(ChatImageRun(after, album: run.album));
  }
  return result;
}

/// Group the already ordered, filtered timeline. This function neither sorts
/// nor reconciles messages: those operations remain with the caller.
/// Image runs are indivisible, so a render block may exceed the 12-message
/// soft limit if the run that is appended is a collection.
List<MessageGroup> clusterTimelineMessages(
  List<ChatMessage> messages, {
  required String Function(ChatMessage) layoutId,
  Set<String> pivotRunIds = const {},
  bool pivotAlbum = false,
  String? pivotEndId,
  bool pivotEndsCluster = true,
}) {
  const maxMessagesPerRenderGroup = 12;
  final groups = <MessageGroup>[];
  for (final run in _timelineImageRuns(
    messages,
    layoutId: layoutId,
    pivotRunIds: pivotRunIds,
    pivotAlbum: pivotAlbum,
  )) {
    final message = run.messages.first;
    final startsNewCluster =
        groups.isEmpty ||
        groups.last.senderId != message.senderId ||
        chatDateKey(groups.last.messages.last.timestamp) !=
            chatDateKey(message.timestamp);
    final startsNewRenderGroup =
        startsNewCluster ||
        layoutId(groups.last.messages.last) == pivotEndId ||
        groups.last.messages.length >= maxMessagesPerRenderGroup;
    if (startsNewRenderGroup) {
      if (!startsNewCluster && groups.isNotEmpty) {
        groups.last.endsCluster = false;
      }
      groups.add(
        MessageGroup(
          senderId: message.senderId,
          senderName: message.senderName,
          isMe: message.isMe,
          messages: List.of(run.messages),
          imageRuns: [run],
          startsCluster: startsNewCluster,
        ),
      );
    } else {
      groups.last.messages.addAll(run.messages);
      groups.last.imageRuns!.add(run);
    }
  }
  for (final group in groups) {
    if (layoutId(group.messages.last) == pivotEndId) {
      // Keep the trailing gap/radius fixed when pagination extends a cluster.
      group.endsCluster = pivotEndsCluster;
    }
  }
  return groups;
}
