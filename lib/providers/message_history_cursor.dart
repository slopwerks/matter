import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mutable_state.dart';

/// Only events fetched through a continuous live/history window are visible.
/// A persisted display cache is not a pagination cursor: it can predate a gap.
class MessageHistoryCursor {
  const MessageHistoryCursor({
    this.anchorId,
    this.connectedEventIds = const {},
    this.generation = 0,
    this.reachedStart = false,
  });

  final String? anchorId;
  final Set<String> connectedEventIds;
  final int generation;
  final bool reachedStart;

  MessageHistoryCursor refreshed(Iterable<String> eventIds) {
    final ids = eventIds.toList();
    if (ids.isEmpty || ids.every(connectedEventIds.contains)) return this;
    final connected = ids.any(connectedEventIds.contains);
    return MessageHistoryCursor(
      anchorId: connected ? anchorId : ids.first,
      connectedEventIds: {
        ...(connected ? connectedEventIds : <String>{}),
        ...ids,
      },
      generation: connected ? generation : generation + 1,
      reachedStart: connected && reachedStart,
    );
  }

  /// Join a verified, overlapping historical window without losing its older
  /// edge or exposing unrelated persisted cache entries.
  MessageHistoryCursor joined(
    Iterable<String> eventIds, {
    required String oldestEventId,
    required bool hitStart,
  }) {
    final extendsOlder = !connectedEventIds.contains(oldestEventId);
    return MessageHistoryCursor(
      anchorId: extendsOlder ? oldestEventId : anchorId,
      connectedEventIds: {...connectedEventIds, ...eventIds},
      generation: generation,
      reachedStart: extendsOlder ? hitStart : reachedStart || hitStart,
    );
  }

  MessageHistoryCursor advanced(Iterable<String> eventIds) {
    final ids = eventIds.toList();
    return MessageHistoryCursor(
      anchorId: ids.isEmpty ? anchorId : ids.first,
      connectedEventIds: {...connectedEventIds, ...ids},
      generation: generation,
      reachedStart: ids.isEmpty,
    );
  }
}

final messageHistoryCursorProvider =
    NotifierProvider.family<
      MutableState<MessageHistoryCursor>,
      MessageHistoryCursor,
      ({String roomId, String userId})
    >((_) => MutableState(const MessageHistoryCursor()));
