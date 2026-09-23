import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../features/markdown/markdown_source_store.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'auth_provider.dart';
import 'connection_provider.dart';
import 'hidden_rooms_provider.dart';
import 'ignored_users_persistence.dart';
import 'message_cache_persistence.dart';
import 'message_ordering.dart';
import 'mutable_state.dart';

final allChatRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final filter = await _previewIgnoreFilter(ref);
  final rooms = await rust.getChatRooms(
    ignoredUserIds: filter.ids?.toList(),
    authoritative: filter.authoritative,
  );
  return rooms;
});

final chatRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  final rooms = await ref.watch(allChatRoomsProvider.future);
  ref.watch(hiddenRoomsProvider);
  final hidden = ref.read(hiddenRoomsProvider.notifier);
  return rooms.where((room) => !hidden.isHidden(room)).toList();
});

final spacesProvider = FutureProvider<List<rust.Space>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  return rust.getSpaces();
});

final spaceDetailsProvider = FutureProvider.family<rust.SpaceDetails, String>((
  ref,
  spaceId,
) async {
  if (!ref.watch(sessionReadyProvider)) {
    throw StateError('Session not ready');
  }
  return rust.getSpaceDetails(spaceId: spaceId);
});

final inboxRoomsProvider = Provider<AsyncValue<List<rust.ChatRoom>>>((ref) {
  return ref
      .watch(chatRoomsProvider)
      .whenData(
        (rooms) => rooms.where((room) => room.roomType != 'space').toList(),
      );
});

final allUngroupedRoomsProvider =
    FutureProvider<List<rust.ChatRoom>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final filter = await _previewIgnoreFilter(ref);
  return rust.getUngroupedRooms(
    ignoredUserIds: filter.ids?.toList(),
    authoritative: filter.authoritative,
  );
});

final ungroupedRoomsProvider = FutureProvider<List<rust.ChatRoom>>((ref) async {
  final rooms = await ref.watch(allUngroupedRoomsProvider.future);
  ref.watch(hiddenRoomsProvider);
  final hidden = ref.read(hiddenRoomsProvider.notifier);
  return rooms.where((room) => !hidden.isHidden(room)).toList();
});

final allSpaceChildrenProvider =
    FutureProvider.family<List<rust.ChatRoom>, String>((ref, spaceId) async {
      if (!ref.watch(sessionReadyProvider)) return [];
      final filter = await _previewIgnoreFilter(ref);
      return rust.getSpaceChildren(
        spaceId: spaceId,
        ignoredUserIds: filter.ids?.toList(),
        authoritative: filter.authoritative,
      );
    });

final spaceChildrenProvider =
    FutureProvider.family<List<rust.ChatRoom>, String>((ref, spaceId) async {
      final rooms = await ref.watch(allSpaceChildrenProvider(spaceId).future);
      ref.watch(hiddenRoomsProvider);
      final hidden = ref.read(hiddenRoomsProvider.notifier);
      return rooms.where((room) => !hidden.isHidden(room)).toList();
    });

final contactsProvider = FutureProvider<List<rust.Contact>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  // Degrade like _previewIgnoreFilter: an unknown ignore list (no snapshot
  // and the fetch failed) must not take the whole contact list down with it,
  // so serve the unfiltered contacts instead of erroring.
  Set<String>? ignoredUserIds;
  try {
    ignoredUserIds = await ref.watch(ignoredUserIdsProvider.future);
  } catch (_) {
    // Ignore state unknown; contacts are independent of it.
  }
  final contacts = await rust.getContacts();
  final filter = ignoredUserIds;
  if (filter == null) return contacts;
  return contacts.where((contact) => !filter.contains(contact.id)).toList();
});

/// Server-backed ignore list. Chat timelines filter these senders immediately,
/// while the Matrix SDK applies the same policy to future sync events.
///
/// The last successfully fetched list is persisted per account so that a
/// loading or failed refresh never degrades into "nobody is ignored" and
/// re-exposes cached messages from ignored senders. When no snapshot exists
/// yet, the state is *unknown* — wait for the fetch (which itself falls back
/// to the SDK's local account-data store when offline, flagged `fromServer:
/// false` so it is served but never persisted or marked confirmed) instead
/// of rendering unfiltered.
/// Per-namespace count of live in-flight [ignoredUserIdsProvider] builds, and
/// namespaces whose revalidation was requested mid-build. Invalidating the
/// provider while a build is in flight permanently strands futures held on
/// that build, so write-through events arriving mid-build are deferred until
/// the build has fully completed.
final _ignoredListBuildsInFlight = <String, int>{};
final _ignoredListRevalidationPending = <String>{};

/// Records a revalidation request when a live build of
/// [ignoredUserIdsProvider] is in flight and returns true in that case.
/// Every revalidation source (sync events, confirmed write-throughs, refresh
/// completion, session changes) must defer this way instead of invalidating
/// directly:
/// invalidating mid-build permanently strands futures held on that build.
/// Deferred requests are drained by the provider's build-end hook.
bool _deferIgnoredListRevalidation(String namespace) {
  if ((_ignoredListBuildsInFlight[namespace] ?? 0) > 0) {
    _ignoredListRevalidationPending.add(namespace);
    return true;
  }
  return false;
}

/// Revalidate [ignoredUserIdsProvider] for [namespace], deferring while a
/// build is in flight (see [_deferIgnoredListRevalidation]). [invalidate]
/// does the actual invalidation when no build is in flight — callers pass
/// `ref.invalidateSelf` from the provider's own ref or
/// `() => ref.invalidate(ignoredUserIdsProvider)` from an external ref,
/// since a provider's own ref cannot invalidate itself by reference.
void _revalidateIgnoredUserIds(String namespace, void Function() invalidate) {
  if (!_deferIgnoredListRevalidation(namespace)) invalidate();
}

/// Retry a failed [ignoredUserIdsProvider] fetch once sync has completed.
///
/// A failed first fetch (no persisted snapshot yet) leaves the provider in an
/// error state that nothing else recovers: `IgnoredUsersChanged` only fires
/// when the account-data event actually arrives, and an empty ignore list
/// never does — timelines and the pinned page would stay blocked until the
/// user manually retries. This is called on every `SyncCompleted` but only
/// acts while the provider is in its error state, so healthy sessions add no
/// traffic. A persistently failing endpoint is throttled: every retry also
/// cascades into a full room-list refresh (the room collections watch the
/// ignore list), so it must not re-fire on every sync cycle.
final _lastIgnoredListRecoveryAttempt = <String, DateTime>{};
const _ignoredListRecoveryThrottle = Duration(seconds: 30);

void _recoverIgnoredListError(Ref ref) {
  final namespace = ref.read(activeUserIdProvider) ?? '';
  if (namespace.isEmpty) return;
  // Do not instantiate the provider just to check it: a session that never
  // surfaced the ignore list (and thus has nothing stuck) should not start a
  // fetch on its behalf.
  if (!ref.exists(ignoredUserIdsProvider)) return;
  if (!ref.read(ignoredUserIdsProvider).hasError) return;
  final lastAttempt = _lastIgnoredListRecoveryAttempt[namespace];
  final now = clock.now();
  if (lastAttempt != null &&
      now.difference(lastAttempt) < _ignoredListRecoveryThrottle) {
    return;
  }
  _lastIgnoredListRecoveryAttempt[namespace] = now;
  _revalidateIgnoredUserIds(
    namespace,
    () => ref.invalidate(ignoredUserIdsProvider),
  );
  // Riverpod rebuilds invalidated providers lazily: with no active watcher
  // (e.g. no chat open) the rebuild would wait for the next read and the
  // retry might not run until long after connectivity returned. Reading the
  // future here guarantees the retry actually executes; a further failure
  // simply re-enters the error state for the next throttled attempt.
  ref.read(ignoredUserIdsProvider.future).ignore();
}

final ignoredUserIdsProvider = FutureProvider<Set<String>>((ref) async {
  if (!ref.watch(sessionReadyProvider)) return const <String>{};
  final namespace = ref.watch(activeUserIdProvider) ?? '';
  // Revalidate on confirmed write-throughs for this account. The publication
  // lives here — not in whichever widget triggered the write — so a
  // management page popped while its server request is still in flight
  // cannot leave the cached provider (and every open timeline) stale.
  var disposed = false;
  var buildReleased = false;
  void releaseBuild({required bool drainPending}) {
    if (buildReleased) return;
    buildReleased = true;
    final remaining = (_ignoredListBuildsInFlight[namespace] ?? 1) - 1;
    if (remaining == 0) {
      _ignoredListBuildsInFlight.remove(namespace);
    } else {
      _ignoredListBuildsInFlight[namespace] = remaining;
    }
    if (drainPending &&
        !disposed &&
        _ignoredListRevalidationPending.remove(namespace)) {
      ref.invalidateSelf();
    }
  }

  _ignoredListBuildsInFlight[namespace] =
      (_ignoredListBuildsInFlight[namespace] ?? 0) + 1;
  ref.onDispose(() {
    disposed = true;
    // A cancelled first load may never reach its finally block. Release its
    // namespace slot now, but leave pending work for a live build to drain.
    // The pending-revalidation set is per-build bookkeeping too: drop the
    // entry, or a stale one would trigger a spurious revalidation for the
    // next session's build.
    releaseBuild(drainPending: false);
    _ignoredListRevalidationPending.remove(namespace);
  });
  final writeThroughs = _ignoredListWriteThroughs.stream.listen((changed) {
    if (changed != namespace || disposed) return;
    // Mid-build, the in-flight build already reconciles via its version
    // checks and post-change snapshot reads; revalidate once it finishes.
    _revalidateIgnoredUserIds(namespace, ref.invalidateSelf);
  });
  ref.onDispose(writeThroughs.cancel);
  try {
    return await _loadIgnoredUserIds(ref, namespace);
  } finally {
    // Revalidate only after this live build's future has completed:
    // invalidateSelf during a build strands held futures.
    scheduleMicrotask(() {
      releaseBuild(drainPending: true);
    });
  }
});

Future<Set<String>> _loadIgnoredUserIds(Ref ref, String namespace) async {
  // The in-memory confirmed list (set only from server-authoritative
  // sources: a completed write-through or a server fetch) outranks the
  // persisted snapshot, which stays best-effort — a SharedPreferences write
  // can fail after a confirmed write-through, leaving the snapshot stale.
  final initialVersion = _ignoredListVersion(namespace);
  final persisted =
      _confirmedIgnoredLists[namespace] ??
      await _loadPersistedIgnoredUserIds(namespace);
  if (!_ignoredListSessionIsCurrent(ref, namespace)) {
    throw StateError('Ignored-user load superseded by an account change');
  }
  if (persisted != null) {
    unawaited(_refreshIgnoredUserIds(ref, namespace, persisted));
    return persisted;
  }
  final version = initialVersion;
  if (_ignoredListVersion(namespace) != version) {
    throw StateError('Ignored-user load superseded by a newer session');
  }
  final result = await rust.getIgnoredUsers();
  if (!_ignoredListSessionIsCurrent(ref, namespace)) {
    throw StateError('Ignored-user load superseded by an account change');
  }
  final fresh = result.userIds.toSet();
  final syncedStoreIsAuthoritative =
      _authoritativeIgnoredStoreVersions[namespace] == version;
  if (!result.fromServer && !syncedStoreIsAuthoritative) {
    // Offline store fallback: serve it (better than unknown on a first
    // run), but never persist or confirm it — the store can lag the latest
    // confirmed state in either direction and must not overwrite a
    // write-through snapshot later.
    return fresh;
  }
  if (_ignoredListVersion(namespace) == version) {
    await _enqueueIgnoredListWrite(namespace, version, () async {
      await _persistIgnoredUserIds(namespace, fresh);
    });
    // Re-check after the persist: a confirmed change may have landed while
    // the write was queued or on disk; this response is stale then.
    if (_ignoredListSessionIsCurrent(ref, namespace) &&
        _ignoredListVersion(namespace) == version) {
      if (_authoritativeIgnoredStoreVersions[namespace] == version) {
        _authoritativeIgnoredStoreVersions.remove(namespace);
      }
      _confirmedIgnoredLists[namespace] = fresh;
      return fresh;
    }
  }
  // A confirmed change landed while this fetch (or its persist) was in
  // flight: the response is stale and must not become the provider state.
  // Serve the newer write-through snapshot instead; the read is queued
  // behind the change's own write so it observes the post-change snapshot.
  Set<String>? latest = _confirmedIgnoredLists[namespace];
  if (latest == null) {
    await _enqueueIgnoredListWrite(namespace, null, () async {
      latest = await _loadPersistedIgnoredUserIds(namespace);
    });
  }
  return latest ?? fresh;
}

/// The ignore list used to filter room-list previews, with its freshness.
/// Room collections watch it, so a write-through change re-filters previews
/// immediately (and an offline restart still filters via the persisted
/// snapshot). `ids` is null when the ignore state is unknown (no snapshot
/// and the fetch failed): Rust then falls back to its store-side filter
/// instead of treating the account as "nobody is ignored".
/// `authoritative` is true only when the served list matches the last
/// server-confirmed state (a successful write-through or completed fetch,
/// not superseded by a later `IgnoredUsersChanged`): Rust may then let the
/// list override its store, whose sync echo can lag in either direction. A
/// merely persisted cache is merged with the store instead.
Future<({Set<String>? ids, bool authoritative})> _previewIgnoreFilter(
  Ref ref,
) async {
  final namespace = ref.watch(activeUserIdProvider) ?? '';
  try {
    final ids = await ref.watch(ignoredUserIdsProvider.future);
    final confirmed = _confirmedIgnoredLists[namespace];
    return (
      ids: ids,
      authoritative: confirmed != null && setEquals(ids, confirmed),
    );
  } catch (_) {
    return (ids: null, authoritative: false);
  }
}

/// Returns the persisted ignore list, or null when no snapshot exists yet
/// (distinct from a persisted *empty* list).
Future<Set<String>?> _loadPersistedIgnoredUserIds(String namespace) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(ignoredUsersCacheKey(namespace));
    return stored?.toSet();
  } catch (error) {
    debugPrint('loadPersistedIgnoredUserIds failed: $error');
    return null;
  }
}

Future<void> _persistIgnoredUserIds(String namespace, Set<String> ids) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final written = await prefs.setStringList(
      ignoredUsersCacheKey(namespace),
      ids.toList()..sort(),
    );
    if (!written) {
      // Best-effort persistence: the in-memory confirmed list still
      // protects this session, but warn that a restart would lose it.
      debugPrint(
        'persistIgnoredUserIds: setStringList returned false for '
        '$namespace; the snapshot was not updated.',
      );
    }
  } catch (error) {
    debugPrint('persistIgnoredUserIds failed: $error');
  }
}

/// Write the authoritative ignore list returned by a successful
/// `setUserIgnored` call through to the persisted snapshot for [namespace],
/// so timelines filter the affected sender immediately after the caller
/// revalidates [ignoredUserIdsProvider]. Without this, the provider would
/// keep serving the pre-change snapshot until a background server refresh
/// happens to succeed (and would restore it forever if that refresh keeps
/// failing). Persisting the full post-write list — rather than merging a
/// delta into a possibly unknown local baseline — also keeps other
/// already-ignored users when no snapshot exists yet.
/// Broadcasts the account namespace of every confirmed ignore-list
/// write-through. `ignoredUserIdsProvider` revalidates itself on these, so
/// the revalidation does not depend on the lifecycle of the widget that
/// triggered the write.
final _ignoredListWriteThroughs = StreamController<String>.broadcast();

Future<void> persistIgnoredUserList(String namespace, Set<String> ids) async {
  // Record the confirmed value synchronously: previews may treat the list as
  // authoritative from this point (the server has accepted the change), and
  // a later IgnoredUsersChanged demotes it again until revalidated.
  _confirmedIgnoredLists[namespace] = Set.unmodifiable(ids);
  _pendingIgnoredWriteThroughLists[namespace] = Set.unmodifiable(ids);
  _authoritativeIgnoredStoreVersions.remove(namespace);
  // Bump synchronously so any refresh whose fetch started earlier is
  // recognized as stale when it completes. The queued write itself must
  // always run: queued writes execute in order, so rapid consecutive
  // changes apply in order instead of losing updates.
  _ignoredListWriteVersions[namespace] = _ignoredListVersion(namespace) + 1;
  await _enqueueIgnoredListWrite(namespace, null, () async {
    await _persistIgnoredUserIds(namespace, ids);
  });
  _ignoredListWriteThroughs.add(namespace);
}

Future<void> _refreshIgnoredUserIds(
  Ref ref,
  String namespace,
  Set<String> persisted,
) async {
  // Captured before the fetch: if a confirmed change bumps the version while
  // this refresh is in flight, its (stale) result must not overwrite the
  // write-through, nor revalidate the provider over newer state.
  final version = _ignoredListVersion(namespace);
  try {
    if (!_ignoredListSessionIsCurrent(ref, namespace)) return;
    final result = await rust.getIgnoredUsers();
    if (!_ignoredListSessionIsCurrent(ref, namespace)) return;
    final fresh = result.userIds.toSet();
    final pendingWriteThrough = _pendingIgnoredWriteThroughLists[namespace];
    if (result.fromServer && pendingWriteThrough != null) {
      if (!setEquals(fresh, pendingWriteThrough)) {
        // Some homeservers can briefly serve the pre-PUT account data from
        // a GET after accepting the write. Keep the confirmed write-through
        // until either a GET observes it or the sync echo demotes it.
        return;
      }
      _pendingIgnoredWriteThroughLists.remove(namespace);
    }
    final syncedStoreIsAuthoritative =
        _authoritativeIgnoredStoreVersions[namespace] == version;
    if (!result.fromServer && !syncedStoreIsAuthoritative) {
      // Offline store fallback: it can lag a confirmed write-through in
      // either direction, so it must never REMOVE ids from the snapshot.
      final confirmed = _confirmedIgnoredLists[namespace];
      if (confirmed != null && setEquals(confirmed, persisted)) {
        // This snapshot IS a confirmed local write whose sync echo has not
        // arrived: the store is known to lag it, so the confirmed state
        // wins outright — unioning would resurrect e.g. a just-un-ignored
        // sender. Only an unconfirmed list (or one demoted by a genuine
        // IgnoredUsersChanged) may absorb store additions.
        return;
      }
      // A confirmed list whose persistence lagged the snapshot (a failed
      // persist) is still the server-confirmed intent: persist it as-is
      // rather than unioning the stale store back in — the union could
      // resurrect a just-un-ignored sender whose echo has not landed.
      // Without a confirmed list, the store may hold cross-device additions
      // the snapshot missed — union conservatively so Dart timelines (which
      // filter on this list alone) hide those senders too. Only a
      // server-authoritative result may shrink the list or be confirmed.
      final merged = confirmed != null
          ? {...confirmed}
          : {...persisted, ...result.userIds};
      // Compare by CONTENT, not length: a same-length swap (un-ignore A,
      // ignore B) must still be persisted, or the stale disk snapshot
      // would resurrect A on the next startup.
      if (!setEquals(merged, persisted)) {
        await _enqueueIgnoredListWrite(namespace, version, () async {
          await _persistIgnoredUserIds(namespace, merged);
        });
        if (_ignoredListVersion(namespace) == version) {
          _revalidateIgnoredUserIds(namespace, ref.invalidateSelf);
        }
      }
      return;
    }
    await _enqueueIgnoredListWrite(namespace, version, () async {
      await _persistIgnoredUserIds(namespace, fresh);
    });
    if (_ignoredListSessionIsCurrent(ref, namespace) &&
        _ignoredListVersion(namespace) == version) {
      // The fetch completed against the current version: the persisted
      // snapshot now reflects a server-confirmed state, so previews may
      // treat it as authoritative again.
      final confirmed = _confirmedIgnoredLists[namespace];
      final wasConfirmed = confirmed != null && setEquals(confirmed, fresh);
      if (_authoritativeIgnoredStoreVersions[namespace] == version) {
        _authoritativeIgnoredStoreVersions.remove(namespace);
      }
      _confirmedIgnoredLists[namespace] = fresh;
      // Revalidate dependents when the content changed OR the freshness
      // just upgraded (cached → confirmed): the list value alone does not
      // carry freshness, and a stale store may still hide a sender the
      // confirmed list has un-ignored. When both are unchanged, skip the
      // invalidation — it would re-trigger this refresh in a loop.
      if (!wasConfirmed ||
          fresh.length != persisted.length ||
          !fresh.containsAll(persisted)) {
        _revalidateIgnoredUserIds(namespace, ref.invalidateSelf);
      }
    }
  } catch (error) {
    // Keep the persisted snapshot: an unknown server state must not be
    // treated as an empty ignore list.
    debugPrint('refreshIgnoredUserIds failed: $error');
  }
}

final _ignoredListWriteVersions = <String, int>{};
final _ignoredListWriteQueues = <String, List<Future<void> Function()>>{};

/// The last server-confirmed ignore list per account — set by a successful
/// write-through ([persistIgnoredUserList]) or a completed fetch, removed
/// when an `IgnoredUsersChanged` sync event makes it suspect. A served list
/// equal to this value may override the lagging SDK store in Rust; anything
/// else is only merged with the store.
final _confirmedIgnoredLists = <String, Set<String>>{};

/// Confirmed writes not yet observed by a server GET or sync echo. A direct
/// GET can lag an accepted account-data PUT without crossing a local version
/// boundary, so its stale response must not roll the write-through back.
final _pendingIgnoredWriteThroughLists = <String, Set<String>>{};

/// Store snapshots read after a sync event are complete account-data state,
/// even when the direct server request used by `getIgnoredUsers` failed.
/// Tying this trust to a version prevents an older event refresh from
/// overriding a newer confirmed local write.
final _authoritativeIgnoredStoreVersions = <String, int>{};

bool _ignoredListSessionIsCurrent(Ref ref, String namespace) =>
    ref.mounted && (ref.read(activeUserIdProvider) ?? '') == namespace;

int _ignoredListVersion(String namespace) =>
    _ignoredListWriteVersions[namespace] ?? 0;

/// Serializes persisted ignore-list writes per account. When
/// [expectedVersion] is given, the write runs only if the list's version
/// still equals it — a confirmed change ([persistIgnoredUserList]) bumps
/// the version synchronously, so a refresh whose fetch started before that
/// change is dropped instead of overwriting the newer snapshot. Confirmed
/// changes pass null: their queued writes always run, in order.
///
/// The returned future is created in the caller's zone and the drain starts
/// in the caller's zone, so this stays safe when callers live in different
/// zones (e.g. separate `testWidgets` bodies with their own FakeAsync).
Future<void> _enqueueIgnoredListWrite(
  String namespace,
  int? expectedVersion,
  Future<void> Function() write,
) {
  final completer = Completer<void>();
  final queue = _ignoredListWriteQueues.putIfAbsent(namespace, () => []);
  queue.add(() async {
    try {
      if (expectedVersion == null ||
          _ignoredListVersion(namespace) == expectedVersion) {
        await write();
      }
      completer.complete();
    } catch (error) {
      completer.completeError(error);
    }
  });
  if (queue.length == 1) unawaited(_drainIgnoredListWrites(namespace));
  return completer.future;
}

Future<void> _drainIgnoredListWrites(String namespace) async {
  final queue = _ignoredListWriteQueues[namespace]!;
  while (queue.isNotEmpty) {
    // A throwing write must not stall the drain: its completer already
    // carried the error to the enqueue side, so swallow it here and move
    // on (the queue entry is still consumed below).
    try {
      await queue.first();
    } catch (_) {
      // Error already reported through the completer.
    }
    queue.removeAt(0);
  }
  // Drop the drained queue entry so per-account state does not accumulate
  // across sessions. Writes enqueued while the drain was running were
  // processed by this same drain (same queue object); a write enqueued after
  // the entry is removed creates a fresh queue and its own drain.
  if (identical(_ignoredListWriteQueues[namespace], queue)) {
    _ignoredListWriteQueues.remove(namespace);
  }
}

class RoomUnreadOverride {
  final bool unread;
  final int baselineUnreadCount;
  final bool baselineMarkedUnread;

  /// Latest-event ID of the snapshot the override supersedes. A room can
  /// advance without changing the unread counters (one unread is marked
  /// read, then another message arrives before the refresh: count is 1
  /// again), and millisecond timestamps can collide between events, so only
  /// the event ID reliably recognizes a newer snapshot.
  final String baselineLastEventId;

  const RoomUnreadOverride({
    required this.unread,
    required this.baselineUnreadCount,
    required this.baselineMarkedUnread,
    required this.baselineLastEventId,
  });

  bool appliesTo(rust.ChatRoom room) =>
      room.unreadCount == baselineUnreadCount &&
      room.isMarkedUnread == baselineMarkedUnread &&
      room.lastEventId == baselineLastEventId;
}

/// Optimistic unread state tied to the exact server snapshot it supersedes.
///
/// Any newer snapshot, including one containing a newly arrived message,
/// invalidates the override instead of letting an old "read" action hide it.
final roomUnreadOverrideProvider =
    NotifierProvider.family<
      MutableState<RoomUnreadOverride?>,
      RoomUnreadOverride?,
      String
    >((_) => MutableState(null));

/// Prevents background timeline refreshes from undoing an explicit unread
/// action. Opening the room again clears the suppression.
final roomAutoReadSuppressedProvider =
    NotifierProvider.family<MutableState<bool>, bool, String>(
      (_) => MutableState(false),
    );

final roomAutoReadSuppressionRevisionProvider =
    NotifierProvider.family<MutableState<int>, int, String>(
      (_) => MutableState(0),
    );

class RoomAutoReadSuppressionToken {
  final MutableState<int> _revision;
  final MutableState<bool> _sessionReady;
  final MutableState<String?> _activeUserId;
  final int value;
  final bool sessionReadyValue;
  final String? accountId;

  const RoomAutoReadSuppressionToken(
    this._revision,
    this._sessionReady,
    this._activeUserId,
    this.value,
    this.sessionReadyValue,
    this.accountId,
  );

  bool get isCurrent =>
      _revision.mounted &&
      _sessionReady.mounted &&
      _sessionReady.value == sessionReadyValue &&
      _activeUserId.mounted &&
      _activeUserId.value == accountId &&
      _revision.value == value;
}

RoomAutoReadSuppressionToken setRoomAutoReadSuppressed(
  WidgetRef ref,
  String roomId, {
  required bool suppressed,
}) {
  final revision = ref.read(
    roomAutoReadSuppressionRevisionProvider(roomId).notifier,
  );
  final sessionReady = ref.read(sessionReadyProvider.notifier);
  final activeUserId = ref.read(activeUserIdProvider.notifier);
  revision.value++;
  ref.read(roomAutoReadSuppressedProvider(roomId).notifier).value = suppressed;
  return RoomAutoReadSuppressionToken(
    revision,
    sessionReady,
    activeUserId,
    revision.value,
    sessionReady.value,
    activeUserId.value,
  );
}

/// Rooms whose mark-unread write timed out: the suppression stays armed
/// (the queued tail may still land), but a write that ultimately failed
/// must not leave the auto-read suppressed forever. The sync flow
/// re-checks these against the room list once 250s have passed — past the
/// queue bounds (30s + 120s) plus the operation's HTTP retries, a landed
/// write has been confirmed by its sync echo (`isMarkedUnread == true`
/// keeps the suppression), a failed one has not (and the suppression is
/// lifted). Same discipline as the mute 250s convergence read. Value is
/// `(registeredAt, nextDueAt, suppressionRevision)`: the registration time
/// is kept across the periodic re-checks so the viewing branch can bound
/// the total retention, and the suppression revision guards the expiry
/// branch against lifting a suppression a NEWER write re-armed.
final _timedOutUnreadSuppressions = <String, (DateTime, DateTime, int)>{};

/// Called by the mark-unread paths when their write times out (the
/// suppression is intentionally kept armed there). [revision] is the
/// `roomAutoReadSuppressionRevisionProvider` value at call time: the
/// expiry branch only lifts the suppression this registration armed.
void noteTimedOutUnreadSuppression(String roomId, {required int revision}) {
  final now = clock.now();
  _timedOutUnreadSuppressions[roomId] = (now, now, revision);
}

/// Lifts suppressions whose timed-out mark-unread write has definitively
/// failed. Runs from the debounced room refresh (the sync flow). Uses a
/// FRESH read: the invalidate-triggered seamless refresh would return the
/// pre-echo cache, misjudging a late-landing write as failed. [isAlive]
/// guards the reads after the await: the provider may be torn down (account
/// switch / logout) while the fetch is in flight, and `read` on an unmounted
/// ref throws.
Future<void> _convergeTimedOutUnreadSuppressions(
  dynamic read, {
  required bool Function() isAlive,
}) async {
  if (!isAlive()) return;
  if (_timedOutUnreadSuppressions.isEmpty) return;
  final now = clock.now();
  final due = _timedOutUnreadSuppressions.entries
      .where(
        (entry) =>
            now.difference(entry.value.$2) >= const Duration(seconds: 250),
      )
      .map((entry) => (roomId: entry.key, at: entry.value))
      .toList();
  if (due.isEmpty) return;
  List<rust.ChatRoom> rooms;
  try {
    rooms = await read(chatRoomsProvider.future) as List<rust.ChatRoom>;
  } catch (_) {
    return; // Load failure: re-check on the next refresh.
  }
  if (!isAlive()) return;
  // Re-read the clock after the await: the reset below must not be
  // shortened by the fetch duration (the 250s window starts from the
  // assessment, not from the snapshot).
  final assessedAt = clock.now();
  for (final item in due) {
    final roomId = item.roomId;
    // A concurrent convergence run or a NEW registration may have replaced
    // the entry while the fresh read was in flight: only act on the exact
    // registration that was snapshotted.
    if (_timedOutUnreadSuppressions[roomId] != item.at) continue;
    final room = rooms.where((room) => room.id == roomId).firstOrNull;
    if (room == null) {
      // The room is gone from the list (left / kicked / removed): the
      // suppression protects nothing — lift it and drop the entry.
      _timedOutUnreadSuppressions.remove(roomId);
      read(roomAutoReadSuppressedProvider(roomId).notifier).value = false;
      continue;
    }
    if (room.isMarkedUnread) {
      // The write landed. Keep the suppression as it is (armed paths stay
      // armed until the room is reopened, matching the success path) and
      // drop the entry — but do NOT re-arm a suppression that was cleared:
      // an explicit read action (or a room reopen) is the user's latest
      // intent, and re-arming would block the auto-read for a marker that
      // action is about to remove.
      _timedOutUnreadSuppressions.remove(roomId);
      continue;
    }
    if (read(currentRoomIdProvider) == roomId) {
      // The user is viewing this room and the write has not (yet) landed:
      // keep the suppression armed — a write that lands later must not be
      // revoked by the echo-driven auto-read (the user EXPLICITLY asked
      // for the unread marker, and the success path keeps the suppression
      // until the room is reopened). The retention is BOUNDED though: past
      // the queue bounds (30s + 120s) plus the operation's HTTP retries
      // plus headroom (~750s total), a write that still has not landed is
      // treated as failed — keeping the suppression would freeze a viewed
      // room's receipts indefinitely with no visible recovery (unlike
      // mute, which keeps a retry tile). Reset the entry's clock on each
      // pass so a late landing is still re-checked every 250s.
      if (now.difference(item.at.$1) >= const Duration(seconds: 750)) {
        // Only lift the suppression this registration armed: a NEWER
        // mark-unread write may have re-armed it (it will manage its own
        // registration when it times out) — clearing it here would let
        // the auto-read revoke a marker the newer write is still landing.
        if (read(roomAutoReadSuppressionRevisionProvider(roomId)) ==
            item.at.$3) {
          read(roomAutoReadSuppressedProvider(roomId).notifier).value = false;
        }
        _timedOutUnreadSuppressions.remove(roomId);
        continue;
      }
      _timedOutUnreadSuppressions[roomId] = (
        item.at.$1,
        assessedAt,
        item.at.$3,
      );
      continue;
    }
    // The write failed and the room is not being viewed: lift the
    // suppression and drop the entry.
    _timedOutUnreadSuppressions.remove(roomId);
    read(roomAutoReadSuppressedProvider(roomId).notifier).value = false;
  }
}

RoomUnreadOverride? _roomUnreadOverrideFor(
  rust.ChatRoom room, {
  required bool unread,
}) {
  final syncedUnread = room.unreadCount > 0 || room.isMarkedUnread;
  return syncedUnread == unread
      ? null
      : RoomUnreadOverride(
          unread: unread,
          baselineUnreadCount: room.unreadCount,
          baselineMarkedUnread: room.isMarkedUnread,
          baselineLastEventId: room.lastEventId,
        );
}

void setRoomUnreadOverride(
  WidgetRef ref,
  rust.ChatRoom room, {
  required bool unread,
}) {
  ref.read(roomUnreadOverrideProvider(room.id).notifier).value =
      _roomUnreadOverrideFor(room, unread: unread);
}

void setRoomUnreadOverrideById(
  WidgetRef ref,
  String roomId, {
  required bool unread,
}) {
  final rooms = ref.read(chatRoomsProvider).asData?.value;
  if (rooms == null) return;
  for (final room in rooms) {
    if (room.id == roomId) {
      setRoomUnreadOverride(ref, room, unread: unread);
      return;
    }
  }
}

/// Clear a watched unread override once it no longer applies to its room
/// (the synced snapshot advanced past its baseline). Shared by every room
/// tile that renders override-aware unread state — the main room list and
/// the space child list — so a stale override does not linger in memory
/// when only one of the two ever renders the room. The `identical` re-read
/// guards against clearing an override a newer action just installed.
void clearStaleRoomUnreadOverride(
  WidgetRef ref,
  BuildContext context,
  String roomId,
  RoomUnreadOverride? watchedOverride,
) {
  if (watchedOverride == null) return;
  Future.microtask(() {
    if (!context.mounted) return;
    if (identical(
      ref.read(roomUnreadOverrideProvider(roomId)),
      watchedOverride,
    )) {
      ref.read(roomUnreadOverrideProvider(roomId).notifier).value = null;
    }
  });
}

class _ProviderAccess {
  final T Function<T>(ProviderListenable<T> provider) read;
  final void Function(ProviderOrFamily provider) invalidate;

  _ProviderAccess.fromWidgetRef(WidgetRef ref)
    : read = ref.read,
      invalidate = ref.invalidate;

  _ProviderAccess.fromRef(Ref ref)
    : read = ref.read,
      invalidate = ref.invalidate;
}

void _invalidateSessionCollections(_ProviderAccess ref) {
  ref.invalidate(allChatRoomsProvider);
  ref.invalidate(chatRoomsProvider);
  ref.invalidate(spacesProvider);
  ref.invalidate(allUngroupedRoomsProvider);
  ref.invalidate(ungroupedRoomsProvider);
  ref.invalidate(allSpaceChildrenProvider);
  ref.invalidate(contactsProvider);
  ref.invalidate(hiddenRoomsProvider);
  final ignoredNamespace = ref.read(activeUserIdProvider) ?? '';
  if (!_deferIgnoredListRevalidation(ignoredNamespace)) {
    ref.invalidate(ignoredUserIdsProvider);
  }
  ref.invalidate(roomKnockRequestsProvider);
  ref.invalidate(roomMembersProvider);
  ref.invalidate(spaceDetailsProvider);
  ref.invalidate(roomUnreadOverrideProvider);
  ref.invalidate(roomAutoReadSuppressedProvider);
  ref.invalidate(roomAutoReadSuppressionRevisionProvider);
  // The view-owner bookkeeping belongs to the previous session's rooms;
  // a stale owner would keep suppressing auto-reads under the new session
  // until each room is re-activated.
  ref.invalidate(roomViewOwnerProvider);
  // Timed-out mark-unread suppressions belong to the previous session too:
  // their convergence checks would read the new account's room list.
  _timedOutUnreadSuppressions.clear();
}

void invalidateSessionCollections(WidgetRef ref) {
  _invalidateSessionCollections(_ProviderAccess.fromWidgetRef(ref));
}

/// Drop the per-account ignore-list freshness and invalidate any refresh
/// still in flight for [namespace]. Session teardown and (re-)establishment
/// must reset this: while a session is down the sync subscription is
/// stopped, so the IgnoredUsersChanged that would normally demote a stale
/// confirmed list can be missed, and a previous session's confirmed list
/// must never mark the persisted snapshot authoritative for a new session.
void resetIgnoredListAccountState(String namespace) {
  _confirmedIgnoredLists.remove(namespace);
  _pendingIgnoredWriteThroughLists.remove(namespace);
  _authoritativeIgnoredStoreVersions.remove(namespace);
  _ignoredListWriteVersions[namespace] = _ignoredListVersion(namespace) + 1;
  // A fresh session starts with a clean recovery throttle: the record is a
  // per-account global that would otherwise leak across logins (and tests).
  _lastIgnoredListRecoveryAttempt.remove(namespace);
}

void clearActiveSessionState(WidgetRef ref, {bool markSessionReady = false}) {
  _clearActiveSessionState(
    _ProviderAccess.fromWidgetRef(ref),
    markSessionReady: markSessionReady,
  );
}

void clearActiveSessionStateFromRef(Ref ref, {bool markSessionReady = false}) {
  _clearActiveSessionState(
    _ProviderAccess.fromRef(ref),
    markSessionReady: markSessionReady,
  );
}

/// Drop room-scoped composer state only for the account being removed.
/// Ordinary account switches deliberately do not call this, so drafts remain
/// available when the user switches back.
void clearAccountComposerStateFromRef(Ref ref, String userId) {
  _resetAccountComposerState(_ProviderAccess.fromRef(ref), userId);
}

void _resetAccountComposerState(_ProviderAccess ref, String userId) {
  final revision = ref.read(
    _accountComposerStateRevisionProvider(userId).notifier,
  );
  revision.value++;
}

void _clearActiveSessionState(
  _ProviderAccess ref, {
  bool markSessionReady = false,
}) {
  // Drop the ignore-list freshness of the outgoing account and invalidate
  // any refresh still in flight for it: while the session is down the sync
  // subscription is stopped, so the IgnoredUsersChanged that would normally
  // demote a stale confirmed list can be missed across a re-login.
  final outgoingUserId = ref.read(activeUserIdProvider);
  resetIgnoredListAccountState(outgoingUserId ?? '');
  if (outgoingUserId != null) {
    _resetAccountComposerState(ref, outgoingUserId);
  }
  ref.read(isLoggedInProvider.notifier).value = false;
  ref.read(currentUserProvider.notifier).value = null;
  ref.read(currentAccessTokenProvider.notifier).value = null;
  ref.read(activeUserIdProvider.notifier).value = null;
  ref.read(connectionProvider.notifier).value = AppConnectionState.disconnected;
  if (markSessionReady) {
    ref.read(sessionReadyProvider.notifier).value = true;
  }
}

Future<void> applyActiveSessionState(
  WidgetRef ref, {
  required String userId,
  required String displayName,
  required String homeserver,
  bool persistActiveUser = false,
  bool refreshStoredSessions = false,
  bool markLoggedIn = true,
}) => _applyActiveSessionState(
  _ProviderAccess.fromWidgetRef(ref),
  userId: userId,
  displayName: displayName,
  homeserver: homeserver,
  persistActiveUser: persistActiveUser,
  refreshStoredSessions: refreshStoredSessions,
  markLoggedIn: markLoggedIn,
);

Future<void> applyActiveSessionStateFromRef(
  Ref ref, {
  required String userId,
  required String displayName,
  required String homeserver,
  bool persistActiveUser = false,
  bool refreshStoredSessions = false,
  bool markLoggedIn = true,
}) => _applyActiveSessionState(
  _ProviderAccess.fromRef(ref),
  userId: userId,
  displayName: displayName,
  homeserver: homeserver,
  persistActiveUser: persistActiveUser,
  refreshStoredSessions: refreshStoredSessions,
  markLoggedIn: markLoggedIn,
);

Future<void> _applyActiveSessionState(
  _ProviderAccess ref, {
  required String userId,
  required String displayName,
  required String homeserver,
  required bool persistActiveUser,
  required bool refreshStoredSessions,
  required bool markLoggedIn,
}) async {
  // Every session (re-)establishment — login, account switch and its
  // rollback, startup restore — funnels through here. A confirmed ignore
  // list left over from a previous session of this account must not mark
  // the persisted snapshot authoritative: cross-device changes that landed
  // while the session was down were never demoted (the sync subscription is
  // off then), and a store-fallback refresh would cement the stale state.
  resetIgnoredListAccountState(userId);
  if (persistActiveUser) {
    await saveActiveUserId(userId);
  }
  final accessToken = await rust.getAccessToken();
  await syncStoredSessionTokens(userId);
  final sessions = refreshStoredSessions ? await loadAllSessions() : null;
  ref.read(currentUserProvider.notifier).value = CurrentUser(
    id: userId,
    displayName: displayName,
    homeserver: homeserver,
  );
  ref.read(currentAccessTokenProvider.notifier).value = accessToken;
  ref.read(homeserverProvider.notifier).value = homeserver;
  ref.read(activeUserIdProvider.notifier).value = userId;
  if (refreshStoredSessions) {
    ref.read(sessionsProvider.notifier).value = sessions ?? [];
  }
  if (markLoggedIn) {
    ref.read(isLoggedInProvider.notifier).value = true;
  }
  ref.read(connectionProvider.notifier).value = AppConnectionState.connecting;
  unawaited(_refreshCurrentUserProfile(ref));
}

/// Fetch the server-side profile (display name + avatar) and merge it into
/// [currentUserProvider]. Fire-and-forget: failures keep the cached state.
Future<void> refreshCurrentUserProfile(WidgetRef ref) {
  return _refreshCurrentUserProfile(_ProviderAccess.fromWidgetRef(ref));
}

Future<void> _refreshCurrentUserProfile(_ProviderAccess ref) async {
  try {
    final profile = await rust.getProfile();
    final current = ref.read(currentUserProvider);
    if (current == null || current.id != profile.userId) return;
    // Construct directly instead of copyWith: a null profile.avatarUrl means
    // the avatar was deleted on the server and must clear the cached one.
    ref.read(currentUserProvider.notifier).value = CurrentUser(
      id: current.id,
      displayName: profile.displayName.isEmpty
          ? current.displayName
          : profile.displayName,
      avatarUrl: profile.avatarUrl,
      homeserver: current.homeserver,
    );
  } catch (_) {
    // Offline, session not ready, or caller widget disposed: keep cached state.
  }
}

Future<void> bootstrapActiveSessionSync(
  WidgetRef ref, {
  required String attemptLabel,
  required String startSyncLabel,
}) => bootstrapActiveSessionSyncForTest(
  ref,
  attemptLabel: attemptLabel,
  startSyncLabel: startSyncLabel,
  syncOnce: rust.syncOnce,
  startSync: rust.startSync,
  delay: (duration) => Future<void>.delayed(duration),
);

Future<void> bootstrapActiveSessionSyncFromRef(
  Ref ref, {
  required String attemptLabel,
  required String startSyncLabel,
  bool requireSyncLoop = false,
}) => _bootstrapActiveSessionSync(
  _ProviderAccess.fromRef(ref),
  attemptLabel: attemptLabel,
  startSyncLabel: startSyncLabel,
  syncOnce: rust.syncOnce,
  startSync: rust.startSync,
  delay: (duration) => Future<void>.delayed(duration),
  requireSyncLoop: requireSyncLoop,
);

@visibleForTesting
Future<void> bootstrapActiveSessionSyncForTest(
  WidgetRef ref, {
  required String attemptLabel,
  required String startSyncLabel,
  required Future<void> Function() syncOnce,
  required Future<void> Function() startSync,
  required Future<void> Function(Duration duration) delay,
  bool requireSyncLoop = false,
}) => _bootstrapActiveSessionSync(
  _ProviderAccess.fromWidgetRef(ref),
  attemptLabel: attemptLabel,
  startSyncLabel: startSyncLabel,
  syncOnce: syncOnce,
  startSync: startSync,
  delay: delay,
  requireSyncLoop: requireSyncLoop,
);

Future<void> _bootstrapActiveSessionSync(
  _ProviderAccess ref, {
  required String attemptLabel,
  required String startSyncLabel,
  required Future<void> Function() syncOnce,
  required Future<void> Function() startSync,
  required Future<void> Function(Duration duration) delay,
  required bool requireSyncLoop,
}) async {
  var initialSyncSucceeded = false;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      await syncOnce();
      initialSyncSucceeded = true;
      ref.read(connectionProvider.notifier).value =
          AppConnectionState.connected;
      _invalidateSessionCollections(ref);
      break;
    } catch (e) {
      debugPrint('$attemptLabel ${attempt + 1} failed: $e');
      if (attempt < 2) {
        await delay(Duration(seconds: 2 * (attempt + 1)));
      }
    }
  }

  if (!initialSyncSucceeded) {
    ref.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
  }

  try {
    await startSync();
  } catch (e) {
    debugPrint('$startSyncLabel: $e');
    ref.read(connectionProvider.notifier).value =
        AppConnectionState.disconnected;
    if (requireSyncLoop) rethrow;
  }
  _invalidateSessionCollections(ref);
}

final currentRoomIdProvider = NotifierProvider<MutableState<String?>, String?>(
  () => MutableState(null),
);

/// The account that opened the room view for [roomId], if any. The room id
/// alone is not account-scoped, so background (sync-driven) auto-reads must
/// verify the room is being viewed under the *active* account — otherwise a
/// switch to another account that shares the room would advance its read
/// receipts without the user ever looking at it.
final roomViewOwnerProvider =
    NotifierProvider.family<MutableState<String?>, String?, String>(
      (_) => MutableState(null),
    );

final messagesProvider = FutureProvider.family<List<rust.ChatMessage>, String>((
  ref,
  roomId,
) async {
  if (!ref.watch(sessionReadyProvider)) return const <rust.ChatMessage>[];
  return rust.getMessages(roomId: roomId);
});

Future<bool> _canPersistMessagesForRoom(dynamic read, String roomId) async {
  final knownRooms =
      (read(chatRoomsProvider) as AsyncValue<List<rust.ChatRoom>>)
          .asData
          ?.value;
  if (knownRooms != null) {
    for (final room in knownRooms) {
      if (room.id == roomId) {
        return !room.isEncrypted;
      }
    }
  }
  try {
    return !await rust.isRoomEncrypted(roomId: roomId);
  } catch (_) {
    return false;
  }
}

/// In-memory snapshot of the latest fetched messages per room.
///
/// The UI watches this instead of [messagesProvider] directly so that
/// re-entering a chat or receiving a sync event doesn't blank the list while
/// a fresh fetch is in flight. On first entry the disk cache is loaded into
/// here instantly (see [primeMessageCache]); later fetches update it via
/// [updateMessageCache]. See `message_cache_persistence.dart` for the disk
/// tier.
final messageCacheProvider =
    NotifierProvider.family<
      MutableState<List<rust.ChatMessage>>,
      List<rust.ChatMessage>,
      String
    >((_) => MutableState(const <rust.ChatMessage>[]));

final messageCachePrimedProvider =
    NotifierProvider.family<MutableState<bool>, bool, String>(
      (_) => MutableState(false),
    );

final messageCacheOwnerProvider =
    NotifierProvider.family<MutableState<String?>, String?, String>(
      (_) => MutableState(null),
    );

const unableToDecryptMessageContent = '无法解密此消息（缺少会话密钥）';

bool isUnableToDecryptPlaceholder(rust.ChatMessage message) {
  return message.msgType == rust.MessageType.text &&
      message.content == unableToDecryptMessageContent &&
      message.imageUrl == null &&
      message.mediaSourceJson == null;
}

rust.ChatMessage chooseMessageForSameEvent(
  rust.ChatMessage existing,
  rust.ChatMessage incoming,
) {
  final existingUnableToDecrypt = isUnableToDecryptPlaceholder(existing);
  final incomingUnableToDecrypt = isUnableToDecryptPlaceholder(incoming);
  if (existingUnableToDecrypt && !incomingUnableToDecrypt) return incoming;
  if (!existingUnableToDecrypt && incomingUnableToDecrypt) return existing;
  return incoming;
}

bool _reactionContentEquals(rust.Reaction a, rust.Reaction b) {
  return a.key == b.key &&
      a.myEventId == b.myEventId &&
      listEquals(a.senders, b.senders);
}

bool _reactionsContentEqual(List<rust.Reaction> a, List<rust.Reaction> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_reactionContentEquals(a[i], b[i])) return false;
  }
  return true;
}

bool _pollContentEquals(rust.PollInfo? a, rust.PollInfo? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.question == b.question &&
      a.disclosed == b.disclosed &&
      a.maxSelections == b.maxSelections &&
      a.totalVoters == b.totalVoters &&
      a.ended == b.ended &&
      listEquals(a.answers, b.answers) &&
      listEquals(a.myAnswerIds, b.myAnswerIds) &&
      listEquals(a.results, b.results);
}

bool chatMessageContentEquals(rust.ChatMessage a, rust.ChatMessage b) {
  return identical(a, b) ||
      (a.id == b.id &&
          a.senderId == b.senderId &&
          a.senderName == b.senderName &&
          a.content == b.content &&
          a.formattedBody == b.formattedBody &&
          a.caption == b.caption &&
          a.captionFormattedBody == b.captionFormattedBody &&
          listEquals(a.mentionedUserIds, b.mentionedUserIds) &&
          a.mentionsRoom == b.mentionsRoom &&
          a.timestamp == b.timestamp &&
          a.isMe == b.isMe &&
          a.msgType == b.msgType &&
          a.imageUrl == b.imageUrl &&
          a.mediaSourceJson == b.mediaSourceJson &&
          a.imageWidth == b.imageWidth &&
          a.imageHeight == b.imageHeight &&
          a.filename == b.filename &&
          a.fileSize == b.fileSize &&
          a.geoUri == b.geoUri &&
          _pollContentEquals(a.poll, b.poll) &&
          a.inReplyTo == b.inReplyTo &&
          a.isEdited == b.isEdited &&
          listEquals(a.editHistory, b.editHistory) &&
          _reactionsContentEqual(a.reactions, b.reactions) &&
          listEquals(a.readers, b.readers) &&
          a.totalMembers == b.totalMembers);
}

List<rust.ChatMessage> mergeMessageSnapshotAdditions(
  List<rust.ChatMessage> current,
  List<rust.ChatMessage> incoming,
) {
  if (incoming.isEmpty) return current;
  final byId = <String, rust.ChatMessage>{
    for (final message in current) message.id: message,
  };
  var changed = false;
  for (final message in incoming) {
    final existing = byId[message.id];
    if (existing == null) {
      byId[message.id] = message;
      changed = true;
      continue;
    }
    final selected = chooseMessageForSameEvent(existing, message);
    if (!chatMessageContentEquals(selected, existing)) {
      byId[message.id] = selected;
      changed = true;
    }
  }
  if (!changed) return current;
  return byId.values.toList()..sort(compareChatMessages);
}

List<rust.ChatMessage> updateMessageCache(
  WidgetRef ref,
  String roomId,
  List<rust.ChatMessage> messages,
) {
  final current = ref.read(messageCacheProvider(roomId));
  final reconciled = reconcileMessageSnapshot(current, messages);
  if (current.length == reconciled.length) {
    var same = true;
    for (var i = 0; i < reconciled.length; i++) {
      if (!chatMessageContentEquals(reconciled[i], current[i])) {
        same = false;
        break;
      }
    }
    if (same) return current;
  }
  ref.read(messageCacheProvider(roomId).notifier).value = reconciled;
  return reconciled;
}

/// Replaces the server's current window while retaining older cached history.
/// An empty refresh is treated as transient when a snapshot is already visible.
List<rust.ChatMessage> reconcileMessageSnapshot(
  List<rust.ChatMessage> current,
  List<rust.ChatMessage> latest,
) {
  if (latest.isEmpty) return current;
  if (current.isEmpty) return latest;

  final oldestLatestTimestamp = latest
      .map((message) => int.tryParse(message.timestamp) ?? 0)
      .reduce(math.min);
  final currentById = <String, rust.ChatMessage>{
    for (final message in current) message.id: message,
  };
  final byId = <String, rust.ChatMessage>{};
  for (final message in current) {
    if ((int.tryParse(message.timestamp) ?? 0) < oldestLatestTimestamp) {
      byId[message.id] = message;
    }
  }
  for (final message in latest) {
    final existing = currentById[message.id] ?? byId[message.id];
    byId[message.id] = existing == null
        ? message
        : chooseMessageForSameEvent(existing, message);
  }
  return byId.values.toList()..sort(compareChatMessages);
}

/// Populate the in-memory cache from disk for a room. Called once when a chat
/// is opened so the previous snapshot renders instantly while a network fetch
/// runs in the background. Safe to call repeatedly; no-ops after the first
/// successful priming for a given room.
Future<void> primeMessageCache(WidgetRef ref, String roomId) async {
  final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
  final allowDiskCache = await _canPersistMessagesForRoom(ref.read, roomId);
  // The calling widget may have been unmounted while the disk check was in
  // flight (entering the chat and leaving again): `ref.read` below throws
  // on a disposed widget.
  if (!ref.context.mounted) return;
  final owner = ref.read(messageCacheOwnerProvider(roomId));
  if (owner != namespace) {
    ref.read(messageCacheProvider(roomId).notifier).value = const [];
    ref.read(messageCachePrimedProvider(roomId).notifier).value = false;
    ref.read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
  }
  if (ref.read(messageCachePrimedProvider(roomId))) return;
  if (!allowDiskCache) {
    await clearCachedMessagesForRoom(namespace: namespace, roomId: roomId);
  }
  final cached = await loadCachedMessages(
    namespace: namespace,
    roomId: roomId,
    allowDiskRead: allowDiskCache,
  );
  if (!ref.context.mounted) return;
  final current = ref.read(messageCacheProvider(roomId));
  if (current.isEmpty && cached.isNotEmpty) {
    ref.read(messageCacheProvider(roomId).notifier).value = cached;
  }
  ref.read(messageCachePrimedProvider(roomId).notifier).value = true;
}

/// Background refresh of a room's messages that also reconciles the result into
/// the in-memory cache and the disk snapshot. Used by the UI in place of a
/// bare [messagesProvider] watch so the list never goes blank mid-fetch.
Future<void> refreshMessagesFromNetwork(WidgetRef ref, String roomId) async {
  final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
  ref.invalidate(messagesProvider(roomId));
  try {
    final latest = await ref.read(messagesProvider(roomId).future);
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    final allowDiskCache = await _canPersistMessagesForRoom(ref.read, roomId);
    if ((ref.read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    ref.read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
    final reconciled = updateMessageCache(ref, roomId, latest);
    // Persist off the widget tree so a slow disk write never blocks the UI.
    Future.microtask(
      () => saveCachedMessages(
        namespace: namespace,
        roomId: roomId,
        messages: reconciled,
        persistToDisk: allowDiskCache,
      ),
    );
  } catch (_) {
    // Keep the existing cached snapshot on failure; the caller decides whether
    // to surface an error.
  }
}

const localOutgoingPendingPrefix = 'local_outgoing_pending:';
const localOutgoingSentPrefix = 'local_outgoing_sent:';
const localOutgoingFailedPrefix = 'local_outgoing_failed:';

bool isLocalOutgoingMessage(String id) =>
    id.startsWith(localOutgoingPendingPrefix) ||
    id.startsWith(localOutgoingSentPrefix) ||
    id.startsWith(localOutgoingFailedPrefix);

bool isLocalOutgoingSentMessage(String id) =>
    id.startsWith(localOutgoingSentPrefix);

bool isLocalOutgoingFailedMessage(String id) =>
    id.startsWith(localOutgoingFailedPrefix);

String failedLocalOutgoingId(String pendingId) {
  if (!pendingId.startsWith(localOutgoingPendingPrefix)) return pendingId;
  return '$localOutgoingFailedPrefix${pendingId.substring(localOutgoingPendingPrefix.length)}';
}

String sentLocalOutgoingId(String pendingId) {
  if (!pendingId.startsWith(localOutgoingPendingPrefix)) return pendingId;
  return '$localOutgoingSentPrefix${pendingId.substring(localOutgoingPendingPrefix.length)}';
}

class LocalOutgoingMessage {
  final rust.ChatMessage message;
  final String? sourceImageUrl;
  final String? markdownSource;

  /// Sender of the message this outgoing message replies to. Preserved so a
  /// failed reply can be retried with the correct `reply_to` mention.
  final String? replyToUserId;

  const LocalOutgoingMessage({
    required this.message,
    this.sourceImageUrl,
    this.markdownSource,
    this.replyToUserId,
  });
}

typedef RoomAccountKey = ({String roomId, String userId});

final _accountComposerStateRevisionProvider =
    NotifierProvider.family<MutableState<int>, int, String>(
      (_) => MutableState(0),
    );

/// A room/account state cell that is reset when its account is explicitly
/// removed, without affecting state belonging to other signed-in accounts.
class AccountScopedMutableState<T> extends MutableState<T> {
  AccountScopedMutableState(super.initialValue, this.userId);

  final String userId;

  @override
  T build() {
    ref.watch(_accountComposerStateRevisionProvider(userId));
    return super.build();
  }
}

RoomAccountKey activeRoomAccountKey(WidgetRef ref, String roomId) => (
  roomId: roomId,
  userId:
      ref.read(activeUserIdProvider) ??
      ref.read(currentUserProvider)?.id ??
      'anonymous',
);

/// Per-room composer state must also be account-scoped: Matrix room IDs are
/// shared across every member account.
final replyingToProvider =
    NotifierProvider.family<
      MutableState<rust.ChatMessage?>,
      rust.ChatMessage?,
      RoomAccountKey
    >((key) => AccountScopedMutableState(null, key.userId));

final editingMessageProvider =
    NotifierProvider.family<
      MutableState<rust.ChatMessage?>,
      rust.ChatMessage?,
      RoomAccountKey
    >((key) => AccountScopedMutableState(null, key.userId));

final localOutgoingMessagesProvider =
    NotifierProvider.family<
      MutableState<List<LocalOutgoingMessage>>,
      List<LocalOutgoingMessage>,
      RoomAccountKey
    >(
      (key) =>
          AccountScopedMutableState(const <LocalOutgoingMessage>[], key.userId),
    );

void upsertLocalOutgoingMessage(
  WidgetRef ref,
  RoomAccountKey key,
  LocalOutgoingMessage message,
) {
  final messages = ref.read(localOutgoingMessagesProvider(key));
  final index = messages.indexWhere(
    (existing) => existing.message.id == message.message.id,
  );
  if (index == -1) {
    ref.read(localOutgoingMessagesProvider(key).notifier).value = [
      ...messages,
      message,
    ];
    return;
  }

  final next = [...messages];
  next[index] = message;
  ref.read(localOutgoingMessagesProvider(key).notifier).value = next;
}

void removeLocalOutgoingMessage(
  WidgetRef ref,
  RoomAccountKey key,
  String messageId,
) {
  final messages = ref.read(localOutgoingMessagesProvider(key));
  ref.read(localOutgoingMessagesProvider(key).notifier).value = messages
      .where((message) => message.message.id != messageId)
      .toList();
}

/// Retry a failed local outgoing message: flip it back to pending and
/// re-send it. On success the local message is marked sent and the timeline
/// refreshes to reconcile it against the server event; on failure the
/// message returns to the failed state so the user can retry again later.
Future<void> retryFailedLocalMessage(
  WidgetRef ref,
  RoomAccountKey key,
  String failedId,
) async {
  final messages = ref.read(localOutgoingMessagesProvider(key));
  final index = messages.indexWhere(
    (message) => message.message.id == failedId,
  );
  if (index == -1) return;
  final failed = messages[index];
  final message = failed.message;
  if (message.msgType != rust.MessageType.text) {
    throw StateError('仅支持重试文本消息');
  }
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final pendingId = failedId.startsWith(localOutgoingFailedPrefix)
      ? '$localOutgoingPendingPrefix'
            '${failedId.substring(localOutgoingFailedPrefix.length)}'
      : failedId;
  // Re-stamp the message with the retry time. Keeping the original timestamp
  // would make the local/remote matcher (which pairs events within a window
  // around the local time) never match a retried send, leaving a permanent
  // duplicate bubble after a delayed retry.
  var retryTimestamp = clock.now().millisecondsSinceEpoch;
  final cached = ref.read(messageCacheProvider(key.roomId));
  for (final cachedMessage in cached) {
    final ts = int.tryParse(cachedMessage.timestamp) ?? 0;
    if (ts >= retryTimestamp) retryTimestamp = ts + 1;
  }
  for (final outgoing in messages) {
    final ts = int.tryParse(outgoing.message.timestamp) ?? 0;
    if (ts >= retryTimestamp) retryTimestamp = ts + 1;
  }
  final pending = LocalOutgoingMessage(
    message: rust.ChatMessage(
      id: pendingId,
      senderId: message.senderId,
      senderName: message.senderName,
      content: message.content,
      formattedBody: message.formattedBody,
      caption: message.caption,
      captionFormattedBody: message.captionFormattedBody,
      mentionedUserIds: message.mentionedUserIds,
      mentionsRoom: message.mentionsRoom,
      timestamp: retryTimestamp.toString(),
      isMe: true,
      msgType: message.msgType,
      imageUrl: message.imageUrl,
      mediaSourceJson: message.mediaSourceJson,
      imageWidth: message.imageWidth,
      imageHeight: message.imageHeight,
      inReplyTo: message.inReplyTo,
      isEdited: message.isEdited,
      editHistory: message.editHistory,
      reactions: message.reactions,
      readers: message.readers,
      totalMembers: message.totalMembers,
    ),
    sourceImageUrl: failed.sourceImageUrl,
    markdownSource: failed.markdownSource,
    // Keep the reply target across the retry so the resent reply mentions
    // the original message's author (sendReply takes replyToUserId).
    replyToUserId: failed.replyToUserId,
  );
  // Replace the failed entry in place: keeping both would render the same
  // row twice (failed + pending) with duplicate row keys.
  final next = [...messages];
  next[index] = pending;
  // Capture the notifier for the post-send bookkeeping: the provider
  // outlives the page, so it stays usable even if the page (and its ref)
  // is disposed while the request is in flight.
  final outgoing = ref.read(localOutgoingMessagesProvider(key).notifier);
  outgoing.value = next;
  final input = rust.FormattedMessageInput(
    body: message.content,
    formattedBody: message.formattedBody,
    mentionedUserIds: message.mentionedUserIds,
    mentionsRoom: message.mentionsRoom,
  );
  final replyTo = message.inReplyTo;
  // Only the send itself is retried: once the server accepts the message,
  // a failure in the local bookkeeping below must not restore the failed
  // entry and report the send as failed (that would offer a retry which
  // duplicates the message).
  late final String remoteEventId;
  try {
    if (replyTo != null) {
      remoteEventId = await rust.sendReply(
        accountUserId: key.userId,
        roomId: key.roomId,
        message: input,
        replyToEventId: replyTo,
        replyToUserId: failed.replyToUserId,
      );
    } else {
      remoteEventId = await rust.sendMessage(
        accountUserId: key.userId,
        roomId: key.roomId,
        message: input,
      );
    }
  } catch (_) {
    // Restore the failed entry so the bubble keeps its error state. Go
    // through the captured notifier: the page (and its ref) may be disposed
    // while the request was in flight — reads through a stale ref throw,
    // but the provider itself outlives the page, and the restored entry
    // lets a reopened room still offer the retry.
    final restored = outgoing.value
        .where((entry) => entry.message.id != pendingId)
        .toList();
    final failedIndex = restored.indexWhere(
      (entry) => entry.message.id == failed.message.id,
    );
    if (failedIndex == -1) {
      restored.add(failed);
    } else {
      restored[failedIndex] = failed;
    }
    outgoing.value = restored;
    rethrow;
  }
  final markdownSource = failed.markdownSource;
  if (markdownSource != null) {
    try {
      if (container.read(activeUserIdProvider) == key.userId) {
        final persist = await _canPersistMessagesForRoom(
          container.read,
          key.roomId,
        );
        if (container.read(activeUserIdProvider) == key.userId) {
          await const MarkdownSourceStore().save(
            userId: key.userId,
            roomId: key.roomId,
            eventId: remoteEventId,
            source: markdownSource,
            body: message.content,
            formattedBody: message.formattedBody,
            persist: persist,
          );
        }
      }
    } catch (e) {
      // The server already accepted the retry. Source persistence is best
      // effort and must never turn that accepted send back into a failure.
      debugPrint('Failed to save retried markdown source: $e');
    }
  }
  // The server has already accepted the message. If the page (and its ref)
  // was disposed while the request was in flight there is no bubble left to
  // reconcile — drop the pending entry through the captured notifier
  // instead of leaving it: the provider outlives the page, so a leftover
  // entry would resurface as a stuck "sending" bubble the next time the
  // room is opened. The echo renders as a normal message via sync.
  if (!ref.context.mounted || ref.read(activeUserIdProvider) != key.userId) {
    outgoing.value = outgoing.value
        .where((entry) => entry.message.id != pendingId)
        .toList();
    return;
  }
  final sentId = markLocalOutgoingMessageSent(ref, key, pendingId);
  // Poll the timeline a few times so the sent local bubble is replaced by
  // the server echo even when the echo lands just after a refresh (same
  // behavior as a fresh send; a single refresh can leave the "sent" bubble
  // lingering for several seconds).
  unawaited(reconcileSentLocalMessage(ref, key, sentId));
}

/// Repeatedly refresh the timeline until the local `sent:` message is
/// reconciled away by its server echo, or the retry budget runs out.
Future<void> reconcileSentLocalMessage(
  WidgetRef ref,
  RoomAccountKey key,
  String localId,
) async {
  const retryDelays = [
    Duration.zero,
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];
  for (final delay in retryDelays) {
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    // The page (and its ref) may be disposed while the loop is asleep;
    // reading through a disposed ref throws.
    if (!ref.context.mounted) return;
    final stillLocal = ref
        .read(localOutgoingMessagesProvider(key))
        .any((message) => message.message.id == localId);
    if (!stillLocal) return;
    await refreshMessages(ref, key.roomId);
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
}

String markLocalOutgoingMessageSent(
  WidgetRef ref,
  RoomAccountKey key,
  String pendingId,
) {
  return markLocalOutgoingMessageSentInState(
    ref.read(localOutgoingMessagesProvider(key).notifier),
    pendingId,
  );
}

String markLocalOutgoingMessageSentInState(
  MutableState<List<LocalOutgoingMessage>> outgoing,
  String pendingId,
) {
  final sentId = sentLocalOutgoingId(pendingId);
  final messages = outgoing.value;
  final index = messages.indexWhere(
    (message) => message.message.id == pendingId,
  );
  if (index == -1) return sentId;

  final local = messages[index];
  final message = local.message;
  final next = [...messages];
  next[index] = LocalOutgoingMessage(
    message: rust.ChatMessage(
      id: sentId,
      senderId: message.senderId,
      senderName: message.senderName,
      content: message.content,
      formattedBody: message.formattedBody,
      caption: message.caption,
      captionFormattedBody: message.captionFormattedBody,
      mentionedUserIds: message.mentionedUserIds,
      mentionsRoom: message.mentionsRoom,
      timestamp: message.timestamp,
      isMe: message.isMe,
      msgType: message.msgType,
      imageUrl: message.imageUrl,
      mediaSourceJson: message.mediaSourceJson,
      imageWidth: message.imageWidth,
      imageHeight: message.imageHeight,
      inReplyTo: message.inReplyTo,
      isEdited: message.isEdited,
      editHistory: message.editHistory,
      reactions: message.reactions,
      readers: message.readers,
      totalMembers: message.totalMembers,
    ),
    sourceImageUrl: local.sourceImageUrl,
    markdownSource: local.markdownSource,
    replyToUserId: local.replyToUserId,
  );
  outgoing.value = next;
  return sentId;
}

void markLocalOutgoingMessageFailedInState(
  MutableState<List<LocalOutgoingMessage>> outgoing,
  String pendingId,
  LocalOutgoingMessage failed,
) {
  final messages = outgoing.value;
  final index = messages.indexWhere(
    (message) => message.message.id == pendingId,
  );
  if (index == -1) return;

  final next = [...messages];
  next[index] = failed;
  outgoing.value = next;
}

Future<void> refreshMessagesRef(Ref ref, String roomId) =>
    _refreshMessagesShared(
      roomId,
      read: ref.read,
      invalidate: ref.invalidate,
      isAlive: () => ref.mounted,
    );

/// Same refresh as [refreshMessagesRef] but driven by a [ProviderContainer]:
/// it never unmounts, so callers whose widget ref may die mid-flight (e.g.
/// the full-screen composer falling back after a layout switch) still get
/// the reconciled fetch.
Future<void> refreshMessagesContainer(
  ProviderContainer container,
  String roomId,
) => _refreshMessagesShared(
  roomId,
  read: container.read,
  invalidate: container.invalidate,
  isAlive: () => true,
);

Future<void> _refreshMessagesShared(
  String roomId, {
  required T Function<T>(ProviderListenable<T> provider) read,
  required void Function(ProviderOrFamily provider) invalidate,
  required bool Function() isAlive,
}) async {
  final namespace = read(activeUserIdProvider) ?? 'anonymous';
  invalidate(messagesProvider(roomId));
  // Reconcile the fresh fetch into the in-memory cache + disk snapshot so the
  // UI (which watches messageCacheProvider) never has to flip through a
  // loading state. This is the path used by syncStreamProvider.
  try {
    final latest = await read(messagesProvider(roomId).future);
    if (!isAlive()) return;
    if ((read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    final allowDiskCache = await _canPersistMessagesForRoom(read, roomId);
    if (!isAlive()) return;
    if ((read(activeUserIdProvider) ?? 'anonymous') != namespace) return;
    read(messageCacheOwnerProvider(roomId).notifier).value = namespace;
    final current = read(messageCacheProvider(roomId));
    final reconciled = reconcileMessageSnapshot(current, latest);
    // Content-equality check (same discipline as updateMessageCache): the
    // snapshot is rebuilt on every refresh, so `identical` would be false
    // even for unchanged content, forcing a full watcher rebuild each sync.
    var equal = current.length == reconciled.length;
    if (equal) {
      for (var i = 0; i < reconciled.length; i++) {
        if (!chatMessageContentEquals(reconciled[i], current[i])) {
          equal = false;
          break;
        }
      }
    }
    if (!equal) {
      read(messageCacheProvider(roomId).notifier).value = reconciled;
    }
    unawaited(
      saveCachedMessages(
        namespace: namespace,
        roomId: roomId,
        messages: equal ? current : reconciled,
        persistToDisk: allowDiskCache,
      ),
    );
  } catch (_) {
    // Keep the existing snapshot on failure.
  }
}

Future<void> refreshMessages(WidgetRef ref, String roomId) {
  // Route through the cache-aware refresh so every caller (send, reaction,
  // etc.) keeps both the in-memory snapshot and the disk cache in sync.
  return refreshMessagesFromNetwork(ref, roomId);
}

final stickerPacksProvider =
    FutureProvider.family<List<rust.StickerPack>, String>((ref, roomId) async {
      if (!ref.watch(sessionReadyProvider)) return [];
      return rust.getStickerPacks(roomId: roomId);
    });

/// Convert mxc:// URI to HTTP URL for display.
/// Returns null if conversion fails or URL is not mxc://.
final mxcUrlCacheProvider =
    NotifierProvider<MutableState<Map<String, String>>, Map<String, String>>(
      () => MutableState({}),
    );

const _kMxcCachePrefix = 'mxc_http_cache_v1';
const _kMaxPersistedMxcEntriesPerUser = 500;
final _loadedMxcCacheUsers = <String>{};

String _mxcStorageNamespace(WidgetRef ref) =>
    ref.read(activeUserIdProvider) ?? 'anonymous';

String _mxcStorageKey(String namespace) => '${_kMxcCachePrefix}_$namespace';

String _scopedMxcCacheKey(String namespace, String cacheKey) =>
    '$namespace::$cacheKey';

Future<void> _ensureMxcCacheLoaded(WidgetRef ref) async {
  final namespace = _mxcStorageNamespace(ref);
  if (_loadedMxcCacheUsers.contains(namespace)) return;

  final prefs = await SharedPreferences.getInstance();
  // The calling widget may have been unmounted while the disk read was in
  // flight: `ref.read` below throws on a disposed widget.
  if (!ref.context.mounted) return;
  if (_loadedMxcCacheUsers.contains(namespace)) return;
  _loadedMxcCacheUsers.add(namespace);
  final raw = prefs.getString(_mxcStorageKey(namespace));
  if (raw != null && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final trimmed = _trimPersistedMxcEntries(
        decoded.map((key, value) => MapEntry(key, '$value')),
      );
      final loadedEntries = decoded.map(
        (key, value) => MapEntry(
          _scopedMxcCacheKey(namespace, key),
          trimmed[key] ?? '$value',
        ),
      );
      final cache = ref.read(mxcUrlCacheProvider);
      ref.read(mxcUrlCacheProvider.notifier).value = {
        ...cache,
        ...loadedEntries,
      };
      if (trimmed.length != decoded.length) {
        await prefs.setString(_mxcStorageKey(namespace), jsonEncode(trimmed));
      }
    } catch (error) {
      debugPrint('Failed to load persisted MXC cache for $namespace: $error');
    }
  }
}

Future<void> _persistMxcCacheEntry(
  WidgetRef ref,
  String namespace,
  String unscopedCacheKey,
  String httpUrl,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final storageKey = _mxcStorageKey(namespace);
    final raw = prefs.getString(storageKey);
    final persisted = raw == null || raw.isEmpty
        ? <String, String>{}
        : (jsonDecode(raw) as Map<String, dynamic>).map(
            (key, value) => MapEntry(key, '$value'),
          );
    persisted.remove(unscopedCacheKey);
    persisted[unscopedCacheKey] = httpUrl;
    final trimmed = _trimPersistedMxcEntries(persisted);
    await prefs.setString(storageKey, jsonEncode(trimmed));
  } catch (error) {
    debugPrint('Failed to persist MXC cache entry: $error');
  }
}

Map<String, String> _trimPersistedMxcEntries(Map<String, String> entries) {
  if (entries.length <= _kMaxPersistedMxcEntriesPerUser) return entries;
  final trimmed = Map<String, String>.from(entries);
  while (trimmed.length > _kMaxPersistedMxcEntriesPerUser) {
    trimmed.remove(trimmed.keys.first);
  }
  return trimmed;
}

String _mxcCacheKey(String mxcUrl, {int? width, int? height}) {
  if (width == null && height == null) return mxcUrl;
  return '$mxcUrl|${width ?? 0}x${height ?? 0}';
}

String? cachedResolvedMxcUrl(
  WidgetRef ref,
  String? mxcUrl, {
  int? width,
  int? height,
}) {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);
  return ref.read(mxcUrlCacheProvider)[cacheKey];
}

void rememberResolvedMxcUrl(
  WidgetRef ref,
  String? mxcUrl,
  String? httpUrl, {
  int? width,
  int? height,
}) {
  if (mxcUrl == null ||
      httpUrl == null ||
      !mxcUrl.startsWith('mxc://') ||
      httpUrl.isEmpty) {
    return;
  }
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);
  final cache = ref.read(mxcUrlCacheProvider);
  if (cache[cacheKey] == httpUrl) return;
  ref.read(mxcUrlCacheProvider.notifier).value = {...cache, cacheKey: httpUrl};
  unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
}

Future<String?> resolveMxcUrlAvatar(WidgetRef ref, String? mxcUrl) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  await _ensureMxcCacheLoaded(ref);
  // The calling widget may have been unmounted while the cache load was in
  // flight: `ref.read` below throws on a disposed widget.
  if (!ref.context.mounted) return null;
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: 96, height: 96);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);

  final cache = ref.read(mxcUrlCacheProvider);
  if (cache.containsKey(cacheKey)) return cache[cacheKey];

  try {
    final httpUrl = await rust.mxcToHttpAvatar(mxcUrl: mxcUrl);
    if (httpUrl == null || httpUrl.isEmpty) return null;
    if (!ref.context.mounted) return null;
    ref.read(mxcUrlCacheProvider.notifier).value = {
      ...cache,
      cacheKey: httpUrl,
    };
    unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
    return httpUrl;
  } catch (_) {
    return null;
  }
}

Future<String?> resolveMxcUrl(
  WidgetRef ref,
  String? mxcUrl, {
  int? width,
  int? height,
}) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  await _ensureMxcCacheLoaded(ref);
  // The calling widget may have been unmounted while the cache load was in
  // flight: `ref.read` below throws on a disposed widget.
  if (!ref.context.mounted) return null;
  final namespace = _mxcStorageNamespace(ref);
  final rawCacheKey = _mxcCacheKey(mxcUrl, width: width, height: height);
  final cacheKey = _scopedMxcCacheKey(namespace, rawCacheKey);

  // Check cache first
  final cache = ref.read(mxcUrlCacheProvider);
  if (cache.containsKey(cacheKey)) return cache[cacheKey];

  try {
    final httpUrl = width != null && height != null
        ? await rust.mxcToHttpThumbnail(
            mxcUrl: mxcUrl,
            width: width,
            height: height,
          )
        : await rust.mxcToHttp(mxcUrl: mxcUrl);
    if (httpUrl == null || httpUrl.isEmpty) return null;
    if (!ref.context.mounted) return null;
    ref.read(mxcUrlCacheProvider.notifier).value = {
      ...cache,
      cacheKey: httpUrl,
    };
    unawaited(_persistMxcCacheEntry(ref, namespace, rawCacheKey, httpUrl));
    return httpUrl;
  } catch (_) {
    return null;
  }
}

/// Convert mxc:// URI to full-quality download HTTP URL.
/// Used for "原图" (original quality) in image preview.
Future<String?> resolveMxcUrlFull(WidgetRef ref, String? mxcUrl) async {
  if (mxcUrl == null || !mxcUrl.startsWith('mxc://')) return null;
  try {
    return await rust.mxcToHttpFull(mxcUrl: mxcUrl);
  } catch (_) {
    return null;
  }
}

/// Room members provider
final roomMembersProvider = FutureProvider.family<List<rust.Contact>, String>((
  ref,
  roomId,
) async {
  if (!ref.watch(sessionReadyProvider)) return [];
  final members = await rust.getRoomMembers(roomId: roomId);
  return members;
});

final pinnedMessagesProvider = FutureProvider.autoDispose
    .family<List<rust.ChatMessage>, RoomAccountKey>((ref, key) async {
      if (ref.watch(activeUserIdProvider) != key.userId) return [];
      return rust.getPinnedMessages(roomId: key.roomId);
    });

final roomKnockRequestsProvider =
    FutureProvider.family<List<rust.KnockRequest>, String>((ref, roomId) async {
      if (!ref.watch(sessionReadyProvider)) return [];
      return rust.getRoomKnockRequests(roomId: roomId);
    });

/// Search rooms provider
final searchRoomsProvider = FutureProvider.family<List<rust.ChatRoom>, String>((
  ref,
  query,
) async {
  if (query.trim().isEmpty) return [];
  final rooms = await ref.watch(allChatRoomsProvider.future);
  ref.watch(hiddenRoomsProvider);
  final hidden = ref.read(hiddenRoomsProvider.notifier);
  final normalizedQuery = query.toLowerCase();
  return rooms
      .where(
        (room) =>
            !hidden.isHidden(room) &&
            room.name.toLowerCase().contains(normalizedQuery),
      )
      .toList();
});

class MessageSearchRequest {
  final String query;
  final String? roomId;
  final int offset;
  final int limit;

  const MessageSearchRequest({
    required this.query,
    this.roomId,
    this.offset = 0,
    this.limit = 30,
  });

  @override
  int get hashCode => Object.hash(query, roomId, offset, limit);

  @override
  bool operator ==(Object other) =>
      other is MessageSearchRequest &&
      query == other.query &&
      roomId == other.roomId &&
      offset == other.offset &&
      limit == other.limit;
}

final messageSearchProvider = FutureProvider.autoDispose
    .family<rust.MessageSearchPage, MessageSearchRequest>((ref, request) async {
      if (request.query.trim().isEmpty) {
        return const rust.MessageSearchPage(
          results: [],
          hasMore: false,
          terms: [],
          historyComplete: true,
        );
      }
      if (!ref.watch(sessionReadyProvider)) {
        throw StateError('消息搜索会话尚未就绪');
      }
      ref.watch(activeUserIdProvider);
      final filter = await _previewIgnoreFilter(ref);
      return rust.searchMessages(
        query: request.query.trim(),
        roomId: request.roomId,
        offset: request.offset,
        limit: request.limit,
        ignoredUserIds: filter.ids?.toList(),
      );
    });

final messageSearchHistoryBackfillProvider =
    Provider<Future<rust.MessageSearchBackfill> Function(String?)>((ref) {
      return (roomId) => rust.backfillMessageSearch(roomId: roomId);
    });

/// Send a reply to a message
Future<void> sendReply(
  Ref ref,
  String roomId,
  String message,
  String replyToEventId,
) async {
  final accountUserId = ref.read(activeUserIdProvider) ?? '';
  await rust.sendReply(
    accountUserId: accountUserId,
    roomId: roomId,
    message: rust.FormattedMessageInput(
      body: message,
      mentionedUserIds: const [],
      mentionsRoom: false,
    ),
    replyToEventId: replyToEventId,
  );
  if (!ref.mounted || ref.read(activeUserIdProvider) != accountUserId) return;
  await refreshMessagesRef(ref, roomId);
  ref.invalidate(chatRoomsProvider);
}

/// Redact (delete) a message
Future<void> redactMessage(
  WidgetRef ref,
  String roomId,
  String eventId, {
  String? reason,
}) async {
  await rust.redactMessage(roomId: roomId, eventId: eventId, reason: reason);
  await refreshMessages(ref, roomId);
  ref.invalidate(chatRoomsProvider);
}

/// The sync event stream subscription. Stays active for the app's lifetime.
/// When sync events arrive, invalidates room/message providers so the UI
/// updates automatically.
///
/// Initialize once after login with: `ref.watch(syncStreamProvider);`
final syncStreamProvider =
    Provider.autoDispose<StreamSubscription<rust.SyncEvent>?>((ref) {
      final sessionReady = ref.watch(sessionReadyProvider);
      final activeUserId = ref.watch(activeUserIdProvider);
      if (!sessionReady || activeUserId == null) {
        return null;
      }

      final stream = rust.watchSyncEvents();
      Timer? messageRefreshTimer;
      Timer? roomRefreshTimer;
      // A `confirmViewedClear` request survives timer cancellations: a
      // message flush cancels and re-arms the room refresh timer without
      // the parameter, and the RoomListChanged echo must not lose its
      // "confirm the viewed room" semantics to that unrelated re-arm.
      var pendingConfirmViewedClear = false;
      var pendingRefreshChatRooms = false;
      var pendingRefreshMembersAndKnocks = false;
      // Per-room debounce for the member/knock provider invalidates:
      // member events can burst (catch-up sync, profile updates), and each
      // invalidate refetches (network /members for knocks and lazy-loaded
      // member lists) — mirroring the pages' own 500ms throttles.
      final memberKnockInvalidateTimers = <String, Timer>{};
      final pendingMessageRefreshes = <String>{};
      final pendingReadAfterRefreshes = <String>{};
      var messageRefreshInFlight = false;
      var messageRefreshTrailing = false;
      var disposed = false;
      late void Function(String roomId, {bool markReadAfterRefresh})
      scheduleMessageRefresh;
      late Future<void> Function({bool skipCachedShortCircuit})
      clearViewedMarkedUnread;
      // Throttle the forced full-list fetch of clearViewedMarkedUnread
      // while the room-list cache is unknown (deep-link before any watcher
      // loaded it): without this, every 500ms sync debounce would fetch
      // the whole room list just to re-check one room.
      DateTime? lastForcedUnreadCheckAt;

      void refreshRooms({
        bool refreshChatRooms = true,
        bool refreshMembersAndKnocks = false,
      }) {
        if (disposed || !ref.mounted) return;
        if (refreshChatRooms) {
          ref.invalidate(allChatRoomsProvider);
          ref.invalidate(chatRoomsProvider);
        }
        ref.invalidate(spacesProvider);
        ref.invalidate(allUngroupedRoomsProvider);
        ref.invalidate(ungroupedRoomsProvider);
        ref.invalidate(allSpaceChildrenProvider);
        ref.invalidate(spaceChildrenProvider);
        ref.invalidate(searchRoomsProvider);
        if (refreshMembersAndKnocks) {
          // Member/knock lists are driven by member-state events (see the
          // RoomMembersChanged case), not by generic sync activity:
          // refetching them on every sync burst would fire a network
          // /members request per incoming message while the management or
          // chat pages are open (their own refresh paths are throttled).
          // Only a full refresh (sync restart) needs the blanket
          // invalidation.
          ref.invalidate(roomKnockRequestsProvider);
          ref.invalidate(roomMembersProvider);
        }
      }

      void scheduleRoomRefresh({
        bool refreshChatRooms = true,
        bool refreshMembersAndKnocks = false,
        // RoomListChanged arrives for an ACTUAL list change (e.g. a
        // cross-device marked-unread echo): the cached snapshot may still
        // predate it, so the short-circuits below must not skip the
        // viewed-room clear — the echo is exactly the "viewer handled it
        // now" signal.
        bool confirmViewedClear = false,
      }) {
        if (disposed || !ref.mounted) return;
        pendingConfirmViewedClear =
            pendingConfirmViewedClear || confirmViewedClear;
        pendingRefreshChatRooms = pendingRefreshChatRooms || refreshChatRooms;
        pendingRefreshMembersAndKnocks =
            pendingRefreshMembersAndKnocks || refreshMembersAndKnocks;
        roomRefreshTimer?.cancel();
        roomRefreshTimer = Timer(const Duration(milliseconds: 500), () {
          roomRefreshTimer = null;
          // Consume the pending confirm request: the echo that armed it is
          // exactly the "viewer handled it now" signal, and the short-
          // circuits below must not skip the viewed-room clear.
          final confirm = pendingConfirmViewedClear;
          pendingConfirmViewedClear = false;
          final refreshChatRooms = pendingRefreshChatRooms;
          pendingRefreshChatRooms = false;
          final refreshMembers = pendingRefreshMembersAndKnocks;
          pendingRefreshMembersAndKnocks = false;
          // Short-circuit the marked-unread check BEFORE invalidating the
          // room list: once refreshRooms() invalidates, the cached value
          // reads as loading and the short-circuit inside
          // clearViewedMarkedUnread never hits — forcing a full room-list
          // fetch on every message when the list has no watcher mounted.
          var needsViewedClear = true;
          if (!confirm) {
            final viewedRoomId = ref.read(currentRoomIdProvider);
            if (viewedRoomId != null) {
              final cachedRooms = ref.read(chatRoomsProvider).asData?.value;
              if (cachedRooms != null) {
                rust.ChatRoom? cachedRoom;
                for (final room in cachedRooms) {
                  if (room.id == viewedRoomId) {
                    cachedRoom = room;
                    break;
                  }
                }
                if (cachedRoom != null && !cachedRoom.isMarkedUnread) {
                  needsViewedClear = false;
                }
              }
            }
          }
          refreshRooms(
            refreshChatRooms: refreshChatRooms,
            refreshMembersAndKnocks: refreshMembers,
          );
          // Timed-out mark-unread writes: lift suppressions whose write
          // has definitively failed (250s past the queue bounds), so a
          // viewed room's auto-reads resume.
          unawaited(
            _convergeTimedOutUnreadSuppressions(
              ref.read,
              isAlive: () => !disposed && ref.mounted,
            ),
          );
          if (needsViewedClear) {
            // A cross-device marked-unread echo lands as a room-list change
            // (and every room refresh re-checks). If the currently viewed
            // room is now marked unread, the viewer is the "handled now"
            // signal — clear it via the auto-read (store-checked: no write
            // when unset, so this is a no-op unless the flag actually
            // arrived).
            unawaited(clearViewedMarkedUnread(skipCachedShortCircuit: confirm));
          }
        });
      }

      /// Clear a `m.marked_unread` flag that arrived from another device
      /// while the user is viewing the room. The room-list refresh above
      /// runs first, so the read sees the echo; guards mirror the
      /// message-flush auto-read (owner, suppression, mid-flight takeover).
      clearViewedMarkedUnread = ({bool skipCachedShortCircuit = false}) async {
        if (disposed || !ref.mounted) return;
        final roomId = ref.read(currentRoomIdProvider);
        if (roomId == null) return;
        if (ref.read(roomAutoReadSuppressedProvider(roomId))) return;
        final startAccount = ref.read(activeUserIdProvider);
        if (startAccount == null ||
            ref.read(roomViewOwnerProvider(roomId)) != startAccount) {
          return;
        }
        // Short-circuit on the cached room list: normally the echo arrives
        // via a RoomListChanged event whose handler already invalidated
        // the list, so a cached `isMarkedUnread == false` means there is
        // nothing to clear. Forcing `chatRoomsProvider` here on EVERY
        // message would turn each 500ms-debounced refresh into a full
        // room-list network request whenever the list is lazy (no watcher
        // mounted); the worst a stale cache costs is one delayed clear
        // cycle. A `RoomListChanged`-driven refresh skips this shortcut:
        // its cached snapshot may still predate the echo that just
        // arrived, and the whole point of the call is to confirm it.
        if (!skipCachedShortCircuit) {
          final cached = ref.read(chatRoomsProvider).asData?.value;
          if (cached != null) {
            rust.ChatRoom? cachedRoom;
            for (final room in cached) {
              if (room.id == roomId) {
                cachedRoom = room;
                break;
              }
            }
            if (cachedRoom != null && !cachedRoom.isMarkedUnread) return;
            // The viewed room is not in the loaded list at all (removed on
            // another device / the user was kicked while viewing): there is
            // nothing to clear — and a full-list refetch here would repeat
            // on every sync burst for a room that can never appear again.
            if (cachedRoom == null) return;
          } else {
            // Cache unknown (deep-link before any watcher loaded the
            // list): throttle the forced full-list fetch — one attempt per
            // 30s is plenty, the list refreshes on its own schedule too.
            final now = clock.now();
            if (lastForcedUnreadCheckAt != null &&
                now.difference(lastForcedUnreadCheckAt!) <
                    const Duration(seconds: 30)) {
              return;
            }
            lastForcedUnreadCheckAt = now;
          }
        }
        List<rust.ChatRoom> rooms;
        try {
          rooms = await ref.read(chatRoomsProvider.future);
        } catch (_) {
          // The room list already surfaces the load error.
          return;
        }
        if (disposed || !ref.mounted) return;
        rust.ChatRoom? unreadRoom;
        for (final room in rooms) {
          if (room.id == roomId) {
            unreadRoom = room;
            break;
          }
        }
        if (unreadRoom == null || !unreadRoom.isMarkedUnread) return;
        // Post-await guards: never send the clear for a viewer that took
        // over the room mid-flight.
        if (ref.read(currentRoomIdProvider) != roomId ||
            ref.read(roomViewOwnerProvider(roomId)) != startAccount ||
            ref.read(roomAutoReadSuppressedProvider(roomId))) {
          return;
        }
        try {
          final cleared = await rust.markRoomAsRead(
            accountUserId: startAccount,
            roomId: roomId,
            explicit: false,
          );
          if (disposed || !ref.mounted) return;
          if (ref.read(roomViewOwnerProvider(roomId)) != startAccount ||
              ref.read(roomAutoReadSuppressedProvider(roomId))) {
            return;
          }
          // Only claim the room is read when the flag was actually cleared:
          // a skipped clear (one already in flight) whose tail later fails
          // must not leave a stale "已读" override masking the server's
          // marked-unread flag.
          if (cleared) {
            ref.read(roomUnreadOverrideProvider(roomId).notifier).value =
                _roomUnreadOverrideFor(unreadRoom, unread: false);
          }
        } catch (error) {
          debugPrint('clear viewed marked unread failed: $error');
        }
      };

      void revalidateIgnoredUsers() {
        // Rust overlays pending confirmed local writes onto its store
        // fallback, so both a specific account-data event and a dropped-event
        // compensation can safely treat that effective snapshot as complete.
        final namespace = ref.read(activeUserIdProvider) ?? '';
        _confirmedIgnoredLists.remove(namespace);
        _pendingIgnoredWriteThroughLists.remove(namespace);
        final version = _ignoredListVersion(namespace) + 1;
        _ignoredListWriteVersions[namespace] = version;
        _authoritativeIgnoredStoreVersions[namespace] = version;
        _revalidateIgnoredUserIds(
          namespace,
          () => ref.invalidate(ignoredUserIdsProvider),
        );
      }

      void scheduleSyncRefresh({
        bool refreshMembersAndKnocks = false,
        bool markCurrentRoomRead = false,
      }) {
        scheduleRoomRefresh(refreshMembersAndKnocks: refreshMembersAndKnocks);
        final currentRoomId = ref.read(currentRoomIdProvider);
        if (currentRoomId != null) {
          scheduleMessageRefresh(
            currentRoomId,
            markReadAfterRefresh: markCurrentRoomRead,
          );
        }
      }

      Future<void> flushMessageRefreshes() async {
        if (disposed) return;
        if (messageRefreshInFlight) {
          messageRefreshTrailing = true;
          return;
        }
        final roomIds = pendingMessageRefreshes.toList();
        pendingMessageRefreshes.clear();
        final readAfterRefreshes = roomIds
            .where(pendingReadAfterRefreshes.remove)
            .toSet();
        if (roomIds.isEmpty) return;

        messageRefreshInFlight = true;
        try {
          // Fetch the room list at most once per flush and share it: every
          // read-after-refresh room below needs it for the unread lookup,
          // and refreshing it per room would fire N identical network
          // requests when several rooms received messages in the same tick.
          Future<List<rust.ChatRoom>>? sharedRoomsFetch;
          await Future.wait(
            roomIds.map((roomId) async {
              await refreshMessagesRef(ref, roomId);
              if (disposed || !ref.mounted) return;
              if (!readAfterRefreshes.contains(roomId) ||
                  ref.read(currentRoomIdProvider) != roomId ||
                  ref.read(roomAutoReadSuppressedProvider(roomId))) {
                return;
              }
              rust.ChatRoom? unreadRoom;
              roomRefreshTimer?.cancel();
              roomRefreshTimer = null;
              // The direct refresh below replaces every chat-list refresh
              // queued before it. A new event arriving while it is in flight
              // can set this flag again and will still get a trailing fetch.
              pendingRefreshChatRooms = false;
              var refreshedRoomList = false;
              try {
                sharedRoomsFetch ??= ref.refresh(chatRoomsProvider.future);
                final rooms = await sharedRoomsFetch!;
                refreshedRoomList = true;
                for (final room in rooms) {
                  if (room.id == roomId) {
                    unreadRoom = room;
                    break;
                  }
                }
              } catch (error) {
                debugPrint(
                  'refresh chat rooms before markRoomAsRead failed: $error',
                );
              }
              if (disposed || !ref.mounted) return;
              // The receipts are written for the account that starts this
              // flush; require the room's viewer to be that same account
              // before sending…
              final startAccount = ref.read(activeUserIdProvider);
              if (startAccount == null ||
                  ref.read(currentRoomIdProvider) != roomId ||
                  // A shared room left open by another account must not
                  // have its read receipts advanced on this account's
                  // behalf.
                  ref.read(roomViewOwnerProvider(roomId)) != startAccount ||
                  ref.read(roomAutoReadSuppressedProvider(roomId))) {
                scheduleRoomRefresh(refreshChatRooms: !refreshedRoomList);
                return;
              }
              // The auto-read must not block the message refresh flush (a
              // slow queue could stall every later refresh for up to 90s);
              // fire it detached, with the unread bookkeeping after it.
              final roomForRead = unreadRoom;
              unawaited(() async {
                try {
                  final cleared = await rust.markRoomAsRead(
                    accountUserId: startAccount,
                    roomId: roomId,
                    explicit: false,
                  );
                  if (disposed ||
                      !ref.mounted ||
                      // …and after the await: never apply the read
                      // bookkeeping to a viewer that took over the room
                      // mid-flight.
                      ref.read(roomViewOwnerProvider(roomId)) != startAccount ||
                      ref.read(roomAutoReadSuppressedProvider(roomId))) {
                    return;
                  }
                  // Only claim the room is read when the flag was actually
                  // cleared (see clearViewedMarkedUnread).
                  if (cleared && roomForRead != null) {
                    ref
                        .read(roomUnreadOverrideProvider(roomId).notifier)
                        .value = _roomUnreadOverrideFor(
                      roomForRead,
                      unread: false,
                    );
                  }
                } catch (error) {
                  debugPrint('markRoomAsRead after refresh failed: $error');
                }
              }());
              scheduleRoomRefresh(refreshChatRooms: !refreshedRoomList);
            }),
          );
        } finally {
          messageRefreshInFlight = false;
          if (!disposed &&
              (messageRefreshTrailing || pendingMessageRefreshes.isNotEmpty)) {
            messageRefreshTrailing = false;
            for (final roomId in pendingMessageRefreshes.toList()) {
              // Carry the read-after flag for rooms that requested it
              // while this flush was in flight: a MessageSent that arrived
              // mid-flush must still get its auto-read, not just a refresh.
              scheduleMessageRefresh(
                roomId,
                markReadAfterRefresh: pendingReadAfterRefreshes.remove(roomId),
              );
            }
          }
        }
      }

      scheduleMessageRefresh =
          (String roomId, {bool markReadAfterRefresh = false}) {
            if (disposed || !ref.mounted) return;
            pendingMessageRefreshes.add(roomId);
            if (markReadAfterRefresh) {
              pendingReadAfterRefreshes.add(roomId);
            }
            if (messageRefreshInFlight) {
              messageRefreshTrailing = true;
              return;
            }
            if (messageRefreshTimer != null) return;
            messageRefreshTimer = Timer(const Duration(milliseconds: 100), () {
              messageRefreshTimer = null;
              unawaited(flushMessageRefreshes());
            });
          };

      final statusTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => pollConnectionStatus(ref),
      );
      Future.microtask(() => pollConnectionStatus(ref));
      final subscription = stream.listen((event) {
        if (disposed || !ref.mounted) return;
        pollConnectionStatus(ref);
        switch (event) {
          case rust.SyncEvent_SyncCompleted():
            scheduleSyncRefresh();
            // A failed ignore-list fetch has no other recovery signal
            // (empty ignore lists never emit IgnoredUsersChanged); retry it
            // now that the connection has produced a sync cycle.
            _recoverIgnoredListError(ref);
          case rust.SyncEvent_FullRefreshRequired():
            // A sync restart may have dropped member/knock events: refresh
            // those lists too. And the event loss means the current room's
            // newly displayed messages never got their per-message
            // MessageSent auto-read — send the receipt now (gated by the
            // usual owner/suppression guards) so the unread badge does not
            // linger until the next single message.
            scheduleSyncRefresh(
              refreshMembersAndKnocks: true,
              markCurrentRoomRead: true,
            );
            ref.invalidate(pinnedMessagesProvider);
            revalidateIgnoredUsers();
          case rust.SyncEvent_RoomListChanged():
            // A real room-list change (e.g. a cross-device marked-unread
            // echo): the viewed-room clear must confirm against the fresh
            // list even when the cached snapshot predates the echo.
            scheduleRoomRefresh(confirmViewedClear: true);
          case rust.SyncEvent_MessageSent(:final roomId):
            if (ref.read(currentRoomIdProvider) == roomId) {
              scheduleMessageRefresh(roomId, markReadAfterRefresh: true);
            }
            scheduleRoomRefresh();
          case rust.SyncEvent_PinnedMessagesChanged(:final roomId):
            final activeUserId = ref.read(activeUserIdProvider);
            if (activeUserId != null) {
              ref.invalidate(
                pinnedMessagesProvider((roomId: roomId, userId: activeUserId)),
              );
            }
          case rust.SyncEvent_RoomMembersChanged(:final roomId):
            // Member state changed: refresh this room's member and knock
            // lists (each provider refetches only when watched — the chat
            // page for members, the management page for knocks). Debounced
            // per room (like the pages' own throttles): member events can
            // burst, and each invalidate would otherwise fire a network
            // /members request.
            memberKnockInvalidateTimers[roomId]?.cancel();
            memberKnockInvalidateTimers[roomId] = Timer(
              const Duration(milliseconds: 500),
              () {
                memberKnockInvalidateTimers.remove(roomId);
                if (disposed || !ref.mounted) return;
                ref.invalidate(roomMembersProvider(roomId));
                ref.invalidate(roomKnockRequestsProvider(roomId));
              },
            );
            scheduleRoomRefresh();
          case rust.SyncEvent_IgnoredUsersChanged():
            revalidateIgnoredUsers();
        }
      });

      ref.onDispose(() {
        disposed = true;
        statusTimer.cancel();
        messageRefreshTimer?.cancel();
        roomRefreshTimer?.cancel();
        for (final timer in memberKnockInvalidateTimers.values) {
          timer.cancel();
        }
        memberKnockInvalidateTimers.clear();
        pendingReadAfterRefreshes.clear();
        subscription.cancel();
      });

      return subscription;
    });

// ── Typing notifications ─────────────────────────────────────────────
//
// `typingUsersProvider(roomId)` exposes the set of user ids currently typing
// in that room. A single subscription to `watchTypingNotifications` fans out
// updates by room id; each room auto-clears after 5s of silence (Matrix typing
// events are ephemeral and may not always send an explicit "stopped" event).

/// Raw per-account typing state, keyed by `{accountId}:{roomId}`. Room ids
/// are global and multiple accounts can share a room, so keying by room
/// alone would leak one account's "is typing" rows into another account's
/// view. Auto-disposed: the value only lives while [typingUsersProvider] is
/// watching it, so a stale entry can never survive into a later session.
final typingUsersStateProvider = NotifierProvider.autoDispose
    .family<MutableState<Set<String>>, Set<String>, String>(
      (_) => MutableState({}),
    );

/// The set of user ids currently typing in [roomId] under the active
/// account. Rebuilds when the account changes and switches to the new
/// account's state key, so an account switch immediately clears the rows.
final typingUsersProvider = Provider.family<Set<String>, String>((ref, roomId) {
  final accountId = ref.watch(activeUserIdProvider);
  if (accountId == null) return const {};
  return ref.watch(typingUsersStateProvider('$accountId:$roomId'));
});

/// Per-room timeout timers so typing status clears after inactivity.
final _typingTimers = <String, Timer>{};

/// Start the global typing-notification listener. Initialize once after login
/// (alongside `syncStreamProvider`). Returns the subscription.
final typingStreamProvider =
    Provider<StreamSubscription<rust.TypingNotification>?>((ref) {
      final sessionReady = ref.watch(sessionReadyProvider);
      final activeUserId = ref.watch(activeUserIdProvider);
      if (!sessionReady || activeUserId == null) {
        return null;
      }

      final stream = rust.watchTypingNotifications();
      final subscription = stream.listen((event) {
        final roomId = event.roomId;
        final stateKey = '$activeUserId:$roomId';
        ref.read(typingUsersStateProvider(stateKey).notifier).value = event
            .userIds
            .toSet();
        // (Re)arm the auto-clear timer for this room+account (the state is
        // keyed per account, so the timer key must match it).
        _typingTimers[stateKey]?.cancel();
        _typingTimers[stateKey] = Timer(const Duration(seconds: 5), () {
          ref.read(typingUsersStateProvider(stateKey).notifier).value = {};
          _typingTimers.remove(stateKey);
        });
      });

      ref.onDispose(() {
        subscription.cancel();
        for (final t in _typingTimers.values) {
          t.cancel();
        }
        _typingTimers.clear();
      });

      return subscription;
    });
