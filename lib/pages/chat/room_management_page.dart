import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'action_failure_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import '../settings/avatar_crop_editor_page.dart';
import 'pinned_messages_page.dart';
import 'room_metadata_patch.dart';
import 'room_state_edit_tracker.dart';

class RoomManagementPage extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;

  /// Called when the room is closed (left or removed) so the parent can
  /// react (e.g. close the chat detail page).
  ///
  /// Contract: when this is null, this page is only ever pushed on top of a
  /// chat detail page, and closing it pops both pages. Every current caller
  /// satisfies this (chat_detail_page.dart pushes it directly; the desktop
  /// details panel passes a callback). New callers must either pass a
  /// callback or push from a chat detail page — see `_closeCurrentRoom`.
  final VoidCallback? onRoomClosed;
  final ValueChanged<RoomMetadataPatch>? onRoomDetailsChanged;

  const RoomManagementPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.onRoomClosed,
    this.onRoomDetailsChanged,
  });

  @override
  ConsumerState<RoomManagementPage> createState() => _RoomManagementPageState();
}

class _RoomManagementPageState extends ConsumerState<RoomManagementPage> {
  final _nameController = TextEditingController();
  final _topicController = TextEditingController();
  final _imagePicker = ImagePicker();
  final _roomNameEdit = RoomStateEditTracker();
  final _roomAvatarEdit = RoomStateEditTracker();
  final _roomTopicEdit = RoomStateEditTracker();
  rust.RoomDetails? _details;
  Uint8List? _avatarPreviewBytes;
  List<rust.Contact> _members = const [];
  List<String> _ignoredUsers = const [];

  /// Knockers approved/rejected just now, hidden until the server echo
  /// removes them (or a short grace elapses) so entries don't flicker back.
  /// The grace bounds the hide: a genuine re-knock must become visible again.
  final Map<String, DateTime> _handledKnockUserIds = {};
  // Rate limit for the SyncCompleted-driven knock retry (30s): a
  // persistently failing knock endpoint must not fire a /members request
  // per sync cycle for as long as the page stays open.
  DateTime? _lastKnockAutoRetryAt;
  final Set<String> _pendingKnockUserIds = {};
  static const Duration _handledKnockGrace = Duration(seconds: 10);
  Timer? _handledKnockExpiryTimer;

  /// Trailing throttle for knock-list refetches: membership events can burst,
  /// and each invalidate triggers a /members request.
  Timer? _knockRefreshTimer;

  void _scheduleKnockRefresh() {
    _knockRefreshTimer?.cancel();
    _knockRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || !_accountActive()) return;
      ref.invalidate(roomKnockRequestsProvider(widget.roomId));
    });
  }

  /// Trailing throttle for event-driven member-list refetches: membership
  /// events can burst (catch-up sync, profile updates also emit member
  /// events), and each triggers a getRoomMembers read.
  Timer? _membersRefreshTimer;

  void _scheduleMembersRefresh() {
    _membersRefreshTimer?.cancel();
    _membersRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || !_accountActive()) return;
      unawaited(_refreshMembers());
    });
  }

  Object? _mutedLoadError;
  Object? _membersLoadError;
  Object? _ignoredUsersLoadError;
  bool _muted = false;
  bool _muteSaving = false;
  // Set while a "标记为已读/未读" write is in flight: the tiles disable
  // and show a spinner (the writes can wait behind the queue for up to
  // 90s, which must not look like a frozen UI).
  bool _markSaving = false;

  /// Set when a mute write timed out (the write may still land server-side):
  /// reads must not overwrite the optimistic value until the write is
  /// confirmed (a matching read) or the user retries manually.
  bool _muteTimedOut = false;

  /// The ignored-users sheet's context while it is open (null once it
  /// closes): an account switch must dismiss the sheet through it, or the
  /// sheet would hover over the "account switched" placeholder showing the
  /// new account's list (same discipline as the space detail add-room
  /// sheet).
  BuildContext? _ignoredUsersSheetContext;

  /// Failure text rendered inside the ignored-users sheet. LIVES ON THE
  /// STATE (not in the Consumer builder): a provider rebuild recreates the
  /// builder's locals, so a local variable would orphan the error written
  /// by an in-flight callback (the text would vanish mid-error).
  String? _ignoredUsersSheetError;

  /// Late convergence read after a timed-out mute write: fires well past
  /// the queue bounds (30s + 120s) plus the operation's HTTP retries. Uses
  /// the matching-read discipline (not the force-adopt of the manual
  /// retry): deep predecessor chains can exceed the timer, so a
  /// contradicting read must not flip the switch back — the manual retry
  /// tile (still shown) or a later sync refresh settles it.
  Timer? _muteConvergenceTimer;

  void _scheduleMuteConvergence() {
    _muteConvergenceTimer?.cancel();
    // 250s covers the queue wait bound (30s + 120s) plus the queued
    // operation's own HTTP retries (~93s): by then a write that ultimately
    // failed has definitely failed, and a write that landed has been
    // confirmed by a sync refresh (clearing the marker) before this read
    // adopts the server value. Chains of multiple predecessors can exceed
    // this — handled by the matching-read discipline in `_retryMuted`.
    _muteConvergenceTimer = Timer(const Duration(seconds: 250), () {
      _muteConvergenceTimer = null;
      // The account may have switched while the timer was armed: the
      // convergence read must run under the account that issued the write.
      // The switch-back listener re-arms the timer (see initState).
      if (!mounted || !_muteTimedOut || !_accountActive()) return;
      unawaited(_retryMuted(force: false));
    });
  }

  /// Generation counter for mute state: refresh/retry reads apply their
  /// value only if no toggle started after the read was issued, closing the
  /// window where a slow read lands after the toggle finished.
  int _muteEpoch = 0;
  bool _loading = true;
  int _ignoredUsersRevision = 0;
  bool _saving = false;
  bool _leavingRoom = false;

  /// Number of member reads currently in flight (`_load`'s fetch and
  /// `_refreshMembers` each hold their own share). Zero means the gate is
  /// open for a new refresh. A count, not a boolean, keeps ownership
  /// unambiguous: a load that bailed early leaves its share to its
  /// in-flight read (released on completion), and a load that inherited a
  /// refresh's in-flight read must not release that read's share — each
  /// reader decrements exactly its own increment, so the gate opens only
  /// when the last in-flight read finishes.
  int _membersReadsInFlight = 0;

  /// Bumped by `_refreshMembers` each time it finishes writing members.
  /// `_load` skips its own (older) member snapshot when a refresh completed
  /// in between — a slow ignored-list read must not let the load's stale
  /// snapshot overwrite fresher refresh data.
  int _membersWriteSeq = 0;
  bool _membersRefreshTrailing = false;
  // A concurrent `_load` (an initial load racing a switch-back reload)
  // would clear the shared member-refresh flag out from under the first
  // one; defer the second to a trailing run instead.
  bool _loadInFlight = false;
  bool _loadTrailing = false;

  /// Set once the full-page-error recovery has re-requested members, so the
  /// recovery check does not re-fire on every later sync cycle (e.g. for
  /// rooms whose member list is legitimately empty).
  bool _membersRecoveryAttempted = false;
  bool _roomStateRefreshInFlight = false;
  bool _roomStateRefreshTrailing = false;
  String? _error;

  /// The account this page was opened under. P0 actions and sync-driven
  /// refreshes must not apply to another account after a switch: the page
  /// can outlive its account (desktop panels, tab stacks), and writing
  /// through the new account's client would silently affect the wrong
  /// account.
  String? _openedUserId;

  /// Users with an ignored-toggle write in flight (double-tap guard for the
  /// member tiles' ignore buttons).
  final Set<String> _pendingIgnoreUserIds = {};

  /// Set when the account switched while this page was alive: the page then
  /// shows a neutral placeholder instead of stale data, a bogus error, or a
  /// null-crash on the unloaded details.
  bool _accountSwitched = false;
  late final StreamSubscription<rust.SyncEvent> _syncSubscription;
  late final ProviderSubscription<AsyncValue<Set<String>>>
  _ignoredUsersSubscription;

  /// True while this page's original account is still the active one.
  bool _accountActive() =>
      mounted && ref.read(activeUserIdProvider) == _openedUserId;

  @override
  void initState() {
    super.initState();
    _openedUserId = ref.read(activeUserIdProvider);
    _ignoredUsersSubscription = ref.listenManual(ignoredUserIdsProvider, (
      _,
      next,
    ) {
      if (!_accountActive()) return;
      next.when(
        data: (ids) {
          setState(() {
            _ignoredUsersRevision++;
            _ignoredUsers = ids.toList()..sort();
            _ignoredUsersLoadError = null;
          });
        },
        error: (error, _) {
          setState(() {
            _ignoredUsersRevision++;
            _ignoredUsersLoadError = error;
          });
        },
        loading: () {},
      );
    });
    _load();
    // Switching accounts while this page stays mounted must surface the
    // neutral placeholder immediately — the page otherwise keeps showing the
    // old account's room data with dead buttons and no explanation.
    // Switching back reloads proactively (sync events may be slow to arrive,
    // and the placeholder must not linger).
    ref.listenManual(activeUserIdProvider, (_, next) {
      if (!mounted) return;
      if (_openedUserId == null && next != null) {
        // Opened before login completed: adopt the first account and load
        // its data instead of showing the placeholder forever.
        _openedUserId = next;
        setState(() => _accountSwitched = false);
        unawaited(_load());
        return;
      }
      if (next != _openedUserId) {
        // Dismiss an open ignored-users sheet: it must not hover over the
        // placeholder showing the new account's list (same discipline as
        // the space detail add-room sheet). `isCurrent` guard: another
        // modal may sit above the sheet — popping then would dismiss that
        // dialog instead.
        final sheetContext = _ignoredUsersSheetContext;
        if (sheetContext != null &&
            sheetContext.mounted &&
            ModalRoute.of(sheetContext)?.isCurrent == true) {
          Navigator.of(sheetContext).pop();
        }
        // Drop the knock-hide bookkeeping: it records actions of the
        // previous account (the grace period is about who handled the
        // request), and the expiry timer must not fire into the new
        // account's request list.
        _handledKnockExpiryTimer?.cancel();
        _handledKnockUserIds.clear();
        setState(() {
          _loading = false;
          _accountSwitched = true;
        });
      } else {
        unawaited(_load());
        // A timed-out mute write may still be pending; re-arm its
        // convergence read now that this account is active again (the
        // timer's earlier fire was swallowed by the account guard).
        if (_muteTimedOut && _muteConvergenceTimer == null) {
          _scheduleMuteConvergence();
        }
      }
    });
    _syncSubscription = rust.watchSyncEvents().listen((event) {
      if (!_accountActive()) return;
      switch (event) {
        case rust.SyncEvent_SyncCompleted():
          unawaited(_refreshRoomState());
          // No knock-list refresh on every sync: SyncCompleted fires per
          // roundtrip, and refetching each time would hammer /members.
          // Knocks are member-state changes (RoomMembersChanged below) —
          // but a FAILED knock load has no other recovery signal, so once
          // the connection has produced a sync cycle, retry it. The retry
          // is additionally rate-limited (30s): while the endpoint keeps
          // failing, an unrestricted retry would fire a /members request
          // per sync cycle for as long as the page stays open.
          if (ref.read(roomKnockRequestsProvider(widget.roomId)).hasError &&
              (_lastKnockAutoRetryAt == null ||
                  clock.now().difference(_lastKnockAutoRetryAt!) >=
                      const Duration(seconds: 30))) {
            _lastKnockAutoRetryAt = clock.now();
            _scheduleKnockRefresh();
          }
        case rust.SyncEvent_RoomMembersChanged(:final roomId)
            when roomId == widget.roomId:
          // Membership events can arrive in bursts (catch-up sync, large
          // rooms, profile updates); throttle the member refetch. The
          // knock list is already invalidated by the global sync stream's
          // own debounced handler — arming a second timer here would
          // double the /members requests per burst.
          _scheduleMembersRefresh();
        case rust.SyncEvent_FullRefreshRequired():
          unawaited(_refreshMembers());
          unawaited(_refreshRoomState());
        // The knock list is invalidated by the global sync stream's
        // family-level handler on full refresh; arming a second timer
        // here would double the /members requests per restart.
        case _:
          break;
      }
    });
  }

  @override
  void dispose() {
    _handledKnockExpiryTimer?.cancel();
    _knockRefreshTimer?.cancel();
    _membersRefreshTimer?.cancel();
    _muteConvergenceTimer?.cancel();
    _syncSubscription.cancel();
    _ignoredUsersSubscription.close();
    _nameController.dispose();
    _topicController.dispose();
    super.dispose();
  }

  Future<({T? value, Object? error})> _attempt<T>(Future<T> future) async {
    try {
      return (value: await future, error: null);
    } catch (error) {
      return (value: null, error: error);
    }
  }

  Future<void> _load() async {
    if (!_accountActive()) return;
    // A save/avatar/mute write may be in flight (e.g. a switch-back reload
    // raced an in-progress edit): applying server values would clobber the
    // user's in-progress input. Skip; the trailing refresh flags re-run it.
    // The room-state trailing only covers details/mute — the members list
    // needs its own trailing flag, or it would stay stale until the next
    // member event.
    if (_saving || _muteSaving) {
      _roomStateRefreshTrailing = true;
      _membersRefreshTrailing = true;
      return;
    }
    // Defer a concurrent load (see the fields' comment) to a trailing run.
    if (_loadInFlight) {
      _loadTrailing = true;
      return;
    }
    _loadInFlight = true;
    _loadTrailing = false;
    // This load's member fetch (the membersFuture below) holds one share of
    // the in-flight gate; every exit path below releases exactly this share
    // (success/catch after the read completes, fail-fast via whenComplete).
    _membersReadsInFlight++;
    // Captured for the member-write guard below: a member refresh that
    // finishes after this load's read started owns the display.
    final membersWriteSeq = _membersWriteSeq;
    setState(() {
      _loading = true;
      _error = null;
      // A reload while a timed-out mute write is still unconverged must not
      // hide the retry entry: the matching-read discipline below decides
      // whether the marker survives.
      if (!_muteTimedOut) _mutedLoadError = null;
      _membersLoadError = null;
      _ignoredUsersLoadError = null;
    });
    try {
      final muteEpoch = _muteEpoch;
      // All four reads run concurrently: each is individually bounded, and
      // serializing them could hold the page's spinner for minutes offline.
      final detailsFuture = _attempt(
        rust.getRoomDetails(roomId: widget.roomId),
      );
      final mutedFuture = _attempt(rust.isRoomMuted(roomId: widget.roomId));
      final membersFuture = _attempt(
        rust.getRoomMembers(roomId: widget.roomId),
      );
      final ignoredUsersRevision = _ignoredUsersRevision;
      final ignoredFuture = _attempt(ref.read(ignoredUserIdsProvider.future));
      final details = await detailsFuture;
      if (details.error != null) {
        // Fail fast on the details error (the room is gone, or the network
        // is down): the members/muted/ignored reads are already in flight
        // concurrently and can take far longer on a bad network — the
        // error page must not wait for them.
        // The account may have switched while the request was in flight:
        // the failure may just be the new account not knowing this room,
        // so surface the neutral placeholder instead of a misleading error.
        // This load's member read is still in flight: release its share of
        // the in-flight gate when it finishes. The count, not a generation
        // check, owns the gate: a newer load's read holds its own share,
        // and the gate opens only when the last in-flight read finishes —
        // no leak when a newer load bails early too (its own share is
        // released by its own whenComplete).
        unawaited(
          membersFuture.whenComplete(() {
            _membersReadsInFlight--;
            // A member refresh deferred while this load's read was in
            // flight may still be waiting on the gate: the count reaching
            // zero does not notify anyone, so kick the pending refresh
            // here when this is the last read to finish.
            if (_membersReadsInFlight == 0 &&
                _membersRefreshTrailing &&
                mounted) {
              unawaited(_refreshMembers());
            }
          }),
        );
        if (!mounted) return;
        if (ref.read(activeUserIdProvider) != _openedUserId) {
          setState(() {
            _loading = false;
            _accountSwitched = true;
          });
          return;
        }
        setState(() {
          _loading = false;
          // The account is the original one again: a load failure is a
          // regular error with its retry entry, not "账号已切换".
          _accountSwitched = false;
          _error = '${details.error}';
        });
        // Consume trailing refresh requests the same way the success path
        // does: a refresh deferred while this load was in flight must not
        // linger until the next sync cycle. (The member refresh may re-defer
        // itself while this load's member read is still in flight — the
        // whenComplete above kicks it once the gate opens.)
        if (_membersRefreshTrailing) unawaited(_refreshMembers());
        if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
        return;
      }
      final muted = await mutedFuture;
      final members = await membersFuture;
      // The member read is done: release its share of the in-flight gate so
      // later member refreshes (sync-triggered or trailing) are not
      // deferred forever. A background refresh's share (if any) is its own
      // to release.
      _membersReadsInFlight--;
      final ignoredUsers = await ignoredFuture;
      final roomDetails = details.value!;
      // The account may have switched while the requests were in flight:
      // applying the old account's data would show a stale A/B mixture.
      // The page outlives its account, so also leave the loading state (a
      // stuck spinner) and mark the switched placeholder instead. Never
      // touch the state after the page was popped: `_accountActive()` is
      // false for a defunct State too, so check `mounted` first.
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != _openedUserId) {
        setState(() {
          _loading = false;
          _accountSwitched = true;
        });
        return;
      }
      setState(() {
        _mergeRemoteDetails(roomDetails);
        // A member refresh that finished after this load's read started
        // owns the member display: skip the load's older snapshot/error so
        // it cannot overwrite fresher refresh data.
        if (_membersWriteSeq == membersWriteSeq) {
          _membersLoadError = members.error;
        }
        if (_ignoredUsersRevision == ignoredUsersRevision) {
          _ignoredUsersLoadError = ignoredUsers.error;
          if (ignoredUsers.value case final value?) {
            _ignoredUsers = value.toList()..sort();
          }
        }
        if (_muteEpoch == muteEpoch) {
          // A toggle started after this load's read owns the switch state
          // and its error display (same discipline as _refreshRoomState): a
          // stale read failure must not disable a switch the user just
          // toggled successfully.
          // A read failure while a timed-out write is still unconverged
          // must not overwrite the write-timeout wording (the retry tile's
          // subtitle explains the actual problem); convergence is owned by
          // the timer, not this read.
          if (muted.error != null && !_muteTimedOut) {
            _mutedLoadError = muted.error;
          }
          if (muted.value case final value?) {
            if (_muteTimedOut) {
              // A timed-out toggle may still be landing server-side: only
              // adopt the read when it matches the optimistic value (the
              // write landed). A contradicting read must not auto-roll back
              // (the queued write may still land seconds later, flipping the
              // switch twice), and must not clear the error tile — the read
              // succeeded, so the write's outcome is still unknown: keep the
              // retry entry and re-arm the convergence timer so a write that
              // ultimately failed still settles.
              if (value == _muted) {
                // The write landed: clear the marker and the stale error
                // display (whose subtitle still claims a failure). The
                // convergence timer is moot once the marker is gone.
                _muteTimedOut = false;
                _mutedLoadError = null;
                _muteConvergenceTimer?.cancel();
              } else {
                // A contradicting read must not push the convergence timer
                // back on every sync cycle (that would starve it): re-arm
                // only when the timer already fired — a live timer fires on
                // schedule and performs the convergence read itself.
                if (_muteConvergenceTimer == null) {
                  _scheduleMuteConvergence();
                }
              }
            } else {
              _muted = value;
              _mutedLoadError = null;
            }
          }
        }
        if (members.value case final value?) {
          // Same freshness guard as `_membersLoadError` above.
          if (_membersWriteSeq == membersWriteSeq) _members = value;
        }
        _loading = false;
        _accountSwitched = false;
      });
      if (_membersRefreshTrailing) unawaited(_refreshMembers());
      if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
      // The knock provider is keyed by room only and may hold the previous
      // account's data after a switch-back; force it to refetch under the
      // restored account.
      ref.invalidate(roomKnockRequestsProvider(widget.roomId));
    } catch (error) {
      // No share release here: the success path already decremented right
      // after `await membersFuture`, and every throwing point in this try
      // (the `_attempt`-wrapped awaits cannot throw; `details.value!` and
      // the `ref.read` checks sit after that decrement) is past it. A
      // second decrement would silently drive the in-flight count negative.
      // Same as above: never leave the spinner up after a mid-flight switch,
      // and never touch a defunct State.
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != _openedUserId) {
        setState(() {
          _loading = false;
          _accountSwitched = true;
        });
        return;
      }
      setState(() {
        _loading = false;
        // The account is the original one again: a load failure is a
        // regular error, not "账号已切换" (the placeholder must not mask the
        // error and its retry entry).
        _accountSwitched = false;
        _error = '$error';
      });
      if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
      if (_membersRefreshTrailing) unawaited(_refreshMembers());
    } finally {
      _loadInFlight = false;
      if (_loadTrailing) {
        _loadTrailing = false;
        unawaited(_load());
      }
    }
  }

  void _showSnackBar(String message) {
    neuToast(context, message);
  }

  /// Map a failed write's error to the unified wording — delegates to the
  /// shared [actionFailureMessage] so the timeout mapping and partial-
  /// success keyword list stay in one place.
  String _actionFailureMessage(Object error) => actionFailureMessage(error);

  /// Surface a failed action with the queue-timeout wording discipline: a
  /// queue-wait timeout means the write may still be landing in its
  /// background tail, so say so instead of claiming a failure.
  void _showActionFailure(Object error) {
    _showSnackBar(_actionFailureMessage(error));
  }

  Future<void> _retryPartialLoad<T>({
    required Future<T> Function() load,
    required void Function(T value) updateValue,
    required void Function(Object? error) updateError,
  }) async {
    final result = await _attempt(load());
    // The account may have switched while the read was in flight.
    if (!_accountActive()) return;
    setState(() {
      updateError(result.error);
      if (result.value case final value?) updateValue(value);
    });
  }

  Future<void> _retryMuted({bool force = true}) {
    final epoch = _muteEpoch;
    return _retryPartialLoad(
      load: () => rust.isRoomMuted(roomId: widget.roomId),
      updateValue: (value) {
        // A mute toggle issued after this retry's read started owns the
        // switch state, even if the toggle has already finished by the time
        // the read lands.
        if (_muteEpoch != epoch) return;
        if (force) {
          // The manual retry is the user explicitly asking for the server
          // state: adopt it even while the timed-out marker is set (the
          // mute set is idempotent, so a late-landing write cannot flip it
          // again — worst case the next sync refresh jumps to the landed
          // value). The read confirms the server state, so the error
          // display (and its disabled switch) clears too. The convergence
          // timer is moot once the marker is gone.
          _muteTimedOut = false;
          _muted = value;
          _mutedLoadError = null;
          _muteConvergenceTimer?.cancel();
        } else if (_muteTimedOut) {
          // Convergence read (the 250s timer): the timed-out write may
          // still be queued (deep predecessor chains can exceed the timer),
          // so only adopt a read that matches the optimistic value — the
          // write landed. A contradicting read must not flip the switch
          // back; the manual retry tile (still shown) or a later matching
          // sync read settles it.
          if (value == _muted) {
            _muteTimedOut = false;
            // The state is confirmed: the stale error display must not
            // keep the switch disabled (its subtitle still claims a
            // failure). The convergence timer is moot once the marker is
            // gone.
            _mutedLoadError = null;
            _muteConvergenceTimer?.cancel();
          }
        } else {
          _muted = value;
        }
      },
      updateError: (error) {
        if (_muteEpoch != epoch) return;
        final message = '$error';
        // A deterministic "room unreachable" error (kicked/removed/deleted
        // while this page stayed mounted) can never converge: stop the
        // convergence loop and surface it plainly instead of re-arming the
        // 250s timer forever.
        final roomUnreachable =
            message.contains('not a joined non-space room') ||
            message.contains('not a joined space') ||
            message.contains('Room not found') ||
            message.contains('不是已加入状态') ||
            message.contains('非空间房间') ||
            message.contains('房间不存在') ||
            message.contains('不是空间');
        if (force) {
          // The manual retry read failed: keep the timed-out marker — a
          // contradicting later read must not flip the switch back while
          // the queued write may still land — and re-arm the convergence
          // timer. Only a SUCCESSFUL force read adopts the server value
          // (see updateValue). An unreachable room is the exception: the
          // marker and timer are moot.
          if (_muteTimedOut) {
            if (roomUnreachable) {
              _muteTimedOut = false;
              _muteConvergenceTimer?.cancel();
            } else {
              _scheduleMuteConvergence();
            }
          }
          _mutedLoadError = error;
        } else if (_muteTimedOut) {
          if (roomUnreachable) {
            // The room is gone: nothing to converge on. Drop the marker
            // and the timer, show the read error.
            _muteTimedOut = false;
            _mutedLoadError = error;
            _muteConvergenceTimer?.cancel();
          } else {
            // The write's outcome is still unknown; keep the existing error
            // display and marker. The convergence read itself failed (e.g.
            // the network dropped again): re-arm the timer so a later attempt
            // still settles the marker — the sync-refresh path does the same
            // on a contradicting read, and without this a permanently failing
            // network would strand the marker on the manual retry tile alone.
            _scheduleMuteConvergence();
          }
        } else {
          _mutedLoadError = error;
        }
      },
    );
  }

  Future<void> _retryMembers() => _refreshMembers();

  Future<void> _refreshRoomState() async {
    if (!_accountActive()) return;
    if (_loading || _saving || _muteSaving || _roomStateRefreshInFlight) {
      _roomStateRefreshTrailing = true;
      return;
    }
    do {
      _roomStateRefreshTrailing = false;
      _roomStateRefreshInFlight = true;
      final muteEpoch = _muteEpoch;
      final detailsFuture = _attempt(
        rust.getRoomDetails(roomId: widget.roomId),
      );
      final mutedFuture = _attempt(rust.isRoomMuted(roomId: widget.roomId));
      final details = await detailsFuture;
      final muted = await mutedFuture;
      _roomStateRefreshInFlight = false;
      // The account may have switched while the reads were in flight:
      // applying the new account's values would show a stale A/B mixture.
      if (!_accountActive()) return;
      setState(() {
        // A successful refresh means the original account is active again.
        _accountSwitched = false;
        if (_muteEpoch == muteEpoch) {
          // A mute toggle issued after this read started owns the switch
          // state — including its error display: a stale read failure must
          // not disable a switch the user just toggled successfully. A read
          // failure while a timed-out write is still unconverged must not
          // overwrite the write-timeout wording either (the retry tile's
          // subtitle explains the actual problem); the convergence timer
          // owns that display.
          if (muted.error != null && !_muteTimedOut) {
            _mutedLoadError = muted.error;
          }
          if (muted.value case final value?) {
            if (_muteTimedOut) {
              // A timed-out toggle may still be landing server-side: the
              // read can return the pre-write value. Only adopt it when it
              // matches the optimistic value (the write landed). A
              // contradicting read must not auto-roll back (the queued write
              // may still land seconds later), and must not clear the error
              // tile — the read succeeded, so the write's outcome is still
              // unknown: keep the retry entry and re-arm the convergence
              // timer so a write that ultimately failed still settles.
              if (value == _muted) {
                // The write landed: clear the marker and the stale error
                // display (whose subtitle still claims a failure). The
                // convergence timer is moot once the marker is gone.
                _muteTimedOut = false;
                _mutedLoadError = null;
                _muteConvergenceTimer?.cancel();
              } else {
                // A contradicting read must not push the convergence timer
                // back on every sync cycle (that would starve it): re-arm
                // only when the timer already fired — a live timer fires on
                // schedule and performs the convergence read itself.
                if (_muteConvergenceTimer == null) {
                  _scheduleMuteConvergence();
                }
              }
            } else {
              _muted = value;
              _mutedLoadError = null;
            }
          }
        }
        if (details.value case final value?) {
          _mergeRemoteDetails(value);
          // A background refresh recovering after an initial load failure
          // must leave the full-page error state, or the page would hold
          // valid data while still rendering the error screen.
          _error = null;
        } else if (details.error != null) {
          debugPrint('refresh room details failed: ${details.error}');
        }
      });
      if (!_membersRecoveryAttempted &&
          _members.isEmpty &&
          _membersLoadError == null &&
          mounted) {
        // The full-page error path never loaded members (their future was
        // discarded by the failed initial _load). Restore them once, or the
        // recovered page would silently show "成员 0" with no retry entry.
        _membersRecoveryAttempted = true;
        unawaited(_refreshMembers());
      }
    } while (_roomStateRefreshTrailing && mounted);
  }

  void _mergeRemoteDetails(rust.RoomDetails remote) {
    final current = _details;
    if (current == null) {
      _details = remote;
      _nameController.text = remote.hasExplicitName ? remote.name : '';
      _topicController.text = remote.topic ?? '';
      _avatarPreviewBytes = null;
      return;
    }

    final currentNameText = current.hasExplicitName ? current.name : '';
    final currentTopicText = current.topic ?? '';
    final nameEdited = _nameController.text != currentNameText;
    final topicEdited = _topicController.text != currentTopicText;
    final acceptName =
        !nameEdited && _roomNameEdit.shouldAccept(remote.nameEventId);
    final acceptTopic =
        !topicEdited && _roomTopicEdit.shouldAccept(remote.topicEventId);
    final acceptAvatar = _roomAvatarEdit.shouldAccept(remote.avatarEventId);
    final avatarChanged =
        acceptAvatar &&
        (current.avatarUrl != remote.avatarUrl ||
            current.avatarEventId != remote.avatarEventId);

    if (acceptName) {
      _nameController.text = remote.hasExplicitName ? remote.name : '';
    }
    if (acceptTopic) {
      _topicController.text = remote.topic ?? '';
    }
    if (acceptAvatar && (_avatarPreviewBytes != null || avatarChanged)) {
      _avatarPreviewBytes = null;
    }

    _details = rust.RoomDetails(
      id: remote.id,
      name: acceptName ? remote.name : current.name,
      hasExplicitName: acceptName
          ? remote.hasExplicitName
          : current.hasExplicitName,
      avatarUrl: acceptAvatar ? remote.avatarUrl : current.avatarUrl,
      nameEventId: acceptName ? remote.nameEventId : current.nameEventId,
      avatarEventId: acceptAvatar
          ? remote.avatarEventId
          : current.avatarEventId,
      topicEventId: acceptTopic ? remote.topicEventId : current.topicEventId,
      topic: acceptTopic ? remote.topic : current.topic,
    );
  }

  Future<void> _refreshMembers() async {
    if (!_accountActive()) return;
    if (_membersReadsInFlight > 0) {
      _membersRefreshTrailing = true;
      return;
    }
    do {
      _membersRefreshTrailing = false;
      _membersReadsInFlight++;
      final result = await _attempt(rust.getRoomMembers(roomId: widget.roomId));
      _membersReadsInFlight--;
      // The account may have switched while the read was in flight.
      if (!_accountActive()) return;
      setState(() {
        _membersLoadError = result.error;
        if (result.value case final value?) _members = value;
        // A fresher write than any in-flight `_load`'s snapshot: `_load`
        // checks this seq before applying its own member data.
        _membersWriteSeq++;
      });
    } while (_membersRefreshTrailing && mounted);
  }

  Future<void> _retryKnocks() async {
    ref.invalidate(roomKnockRequestsProvider(widget.roomId));
    try {
      await ref.read(roomKnockRequestsProvider(widget.roomId).future);
    } catch (_) {
      // The provider exposes the retry error in the section.
    }
  }

  Future<void> _retryIgnoredUsers() async {
    ref.invalidate(ignoredUserIdsProvider);
    try {
      await ref.read(ignoredUserIdsProvider.future);
    } catch (_) {
      // The provider listener exposes the retry error in the section.
    }
  }

  void _invalidateRoom() {
    if (!mounted) return;
    ref.invalidate(chatRoomsProvider);
    ref.invalidate(ungroupedRoomsProvider);
    ref.invalidate(spaceChildrenProvider);
    ref.invalidate(searchRoomsProvider);
    ref.invalidate(roomMembersProvider(widget.roomId));
    ref.invalidate(roomKnockRequestsProvider(widget.roomId));
  }

  void _closeCurrentRoom() {
    final handledByParent = widget.onRoomClosed != null;
    // Fire the parent callback even when this page was already popped (its
    // route is gone but the chat page below is still in the navigator):
    // a leave that completes after the user backed out of the management
    // page would otherwise strand the chat page on a room that is left.
    widget.onRoomClosed?.call();
    if (!mounted) return;
    final navigator = Navigator.of(context);
    // An async room action may complete after the user already popped this
    // page (e.g. back button while the action was in flight). Popping the
    // chat underneath then would kick the user out of the conversation they
    // intended to stay in, so only close when this page is still the active
    // route. During a pop animation the route is already removed from the
    // navigator history, which `isCurrent` reflects immediately.
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    if (navigator.canPop()) navigator.pop();
    if (!handledByParent && navigator.canPop()) navigator.pop();
  }

  Future<void> _saveDetails() async {
    if (!_accountActive()) return;
    if (_saving) return;
    final details = _details;
    if (details == null) return;
    final name = _nameController.text.trim();
    if (details.hasExplicitName && name.isEmpty) {
      _showSnackBar('房间名称不能为空');
      return;
    }
    final updateName = details.hasExplicitName
        ? name != details.name
        : name.isNotEmpty;
    final topic = _topicController.text.trim().isEmpty
        ? null
        : _topicController.text.trim();
    final updateTopic = topic != details.topic;
    if (!updateName && !updateTopic) {
      _showSnackBar('没有需要保存的修改');
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await rust.updateRoomDetails(
        accountUserId: _openedUserId ?? '',
        roomId: widget.roomId,
        name: name,
        updateName: updateName,
        updateTopic: updateTopic,
        topic: updateTopic ? topic : null,
      );
      // The account may have switched while the request was in flight: the
      // write itself was guarded server-side, so skip the local bookkeeping
      // and parent patches (the page shows the switched placeholder).
      if (!_accountActive()) return;
      _invalidateRoom();
      if (!mounted) return;
      final currentDetails = _details;
      if (currentDetails == null) return;
      final nameUpdated = updateName && result.nameError == null;
      if (nameUpdated) {
        _roomNameEdit.record(
          currentEventId: currentDetails.nameEventId,
          nextEventId: result.nameEventId,
        );
      }
      if (updateTopic && result.topicError == null) {
        _roomTopicEdit.record(
          currentEventId: currentDetails.topicEventId,
          nextEventId: result.topicEventId,
        );
      }
      final updatedDetails = rust.RoomDetails(
        id: currentDetails.id,
        name: nameUpdated ? name : currentDetails.name,
        hasExplicitName: currentDetails.hasExplicitName || nameUpdated,
        avatarUrl: currentDetails.avatarUrl,
        nameEventId: nameUpdated
            ? result.nameEventId
            : currentDetails.nameEventId,
        avatarEventId: currentDetails.avatarEventId,
        topicEventId: updateTopic && result.topicError == null
            ? result.topicEventId
            : currentDetails.topicEventId,
        topic: updateTopic && result.topicError == null
            ? topic
            : currentDetails.topic,
      );
      final detailsChanged = updatedDetails != currentDetails;
      if (detailsChanged) {
        setState(() => _details = updatedDetails);
      }
      if (nameUpdated) {
        widget.onRoomDetailsChanged?.call(
          RoomNamePatch(
            roomId: currentDetails.id,
            name: name,
            nameEventId: result.nameEventId,
          ),
        );
      }
      final failures = [
        if (result.nameError case final error?) '房间名称更新失败: $error',
        if (result.topicError case final error?) '主题更新失败: $error',
      ];
      // Either way the write proved the full-page error (possibly stale
      // from a failed reload) is outdated: leave the error screen so the
      // form is visible again.
      if (mounted) setState(() => _error = null);
      if (failures.isEmpty) {
        _showSnackBar('房间信息已更新');
      } else {
        final prefix = detailsChanged ? '部分更新成功：' : '';
        _showSnackBar('$prefix${failures.join('；')}');
      }
    } catch (error) {
      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
      if (!mounted || !_accountActive()) return;
      if (mounted) _showActionFailure(error);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
        // A load skipped while the save was in flight also left the
        // member list stale; consume its trailing flag too.
        if (_membersRefreshTrailing) unawaited(_refreshMembers());
      }
    }
  }

  Future<void> _pickAvatar() async {
    if (!_accountActive()) return;
    if (_saving) return;
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 95,
      );
      if (picked == null || !mounted) return;
      final sourceBytes = await picked.readAsBytes();
      if (!mounted) return;
      final bytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => AvatarCropEditorPage(imageBytes: sourceBytes),
        ),
      );
      if (bytes == null || !mounted) return;
      setState(() => _saving = true);
      final avatarUpdate = await rust.uploadRoomAvatar(
        accountUserId: _openedUserId ?? '',
        roomId: widget.roomId,
        contentType: 'image/jpeg',
        data: bytes,
      );
      // The account may have switched while the upload ran (the Rust side
      // re-verifies it before applying the state event): skip the local
      // bookkeeping and parent patches.
      if (!_accountActive()) return;
      _invalidateRoom();
      if (!mounted) return;
      final details = _details!;
      _roomAvatarEdit.record(
        currentEventId: details.avatarEventId,
        nextEventId: avatarUpdate.eventId,
      );
      final updatedDetails = rust.RoomDetails(
        id: details.id,
        name: details.name,
        hasExplicitName: details.hasExplicitName,
        avatarUrl: avatarUpdate.avatarUrl,
        nameEventId: details.nameEventId,
        avatarEventId: avatarUpdate.eventId,
        topicEventId: details.topicEventId,
        topic: details.topic,
      );
      setState(() {
        _details = updatedDetails;
        _avatarPreviewBytes = bytes;
      });
      widget.onRoomDetailsChanged?.call(
        RoomAvatarPatch(
          roomId: details.id,
          avatarUrl: avatarUpdate.avatarUrl,
          avatarEventId: avatarUpdate.eventId,
        ),
      );
      _showSnackBar('房间头像已更新');
    } catch (error) {
      // The account may have switched while the upload was in flight (the
      // Rust guard then rejects deterministically): the page shows the
      // switched placeholder — don't surface a failure snackbar that
      // contradicts it (same discipline as `_setMuted`).
      if (!mounted || !_accountActive()) return;
      if (mounted) {
        final message = '$error';
        // An upload timeout means the upload never happened — the generic
        // "may have taken effect, refresh to confirm" wording would be
        // misleading (there is nothing to refresh): retry is the right
        // advice. State-event timeouts (after a successful upload) still
        // go through _showActionFailure.
        if (message.contains('上传超时') || message.contains('已上传')) {
          // Upload-stage timeout: the upload never happened, retry. Or the
          // upload landed but the state-event step failed/timed out: the
          // Rust wording already explains it — "刷新确认" would have
          // nothing to confirm. Either way, pass the message through.
          _showSnackBar(message);
        } else {
          _showActionFailure(error);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
        // A load skipped while the save was in flight also left the
        // member list stale; consume its trailing flag too.
        if (_membersRefreshTrailing) unawaited(_refreshMembers());
      }
    }
  }

  Future<void> _setMuted(bool muted) async {
    if (!_accountActive()) return;
    if (_muteSaving) return;
    _muteEpoch++;
    setState(() {
      _muteSaving = true;
      _muted = muted;
    });
    try {
      await rust.setRoomMuted(
        accountUserId: _openedUserId ?? '',
        roomId: widget.roomId,
        muted: muted,
      );
      // The account may have switched while the request was in flight: skip
      // the bookkeeping (the page shows the switched placeholder).
      if (!_accountActive()) return;
      if (!mounted) return;
      // A successful toggle also clears any stale error state from reads
      // that raced it.
      setState(() {
        _mutedLoadError = null;
        _muteTimedOut = false;
      });
      // A convergence timer armed by an earlier timed-out write is now
      // moot: the write landed, so its late read would only no-op.
      _muteConvergenceTimer?.cancel();
      _invalidateRoom();
      _showSnackBar(muted ? '已开启免打扰' : '已关闭免打扰');
    } catch (error) {
      // The account may have switched while the request was in flight (the
      // Rust-side guard then rejects the write deterministically): the page
      // shows the switched placeholder — don't roll the switch back or show
      // a failure snackbar that contradicts it. The next load under the
      // original account re-reads the real state.
      if (!mounted || !_accountActive()) return;
      final timedOut = isMutationTimeout(error);
      if (timedOut) {
        // A timeout may still land server-side: keep the optimistic value
        // and let the next sync refresh reconcile the switch (a matching
        // read clears the marker; a contradicting read keeps it). Schedule
        // a late convergence read well past the queue's bounds (30s + 120s)
        // so a write that ultimately failed is still reconciled: by then
        // `_retryMuted` (which adopts the server value) is safe to run.
        setState(() {
          _mutedLoadError = error;
          _muteTimedOut = true;
        });
        _scheduleMuteConvergence();
        // Honest wording: a SUCCESSFUL late write converges via the next
        // sync, but a failed one only settles via the retry tile below.
        // The bare timeout wording must not appear inside the failure
        // prefix (it already advises "刷新确认", conflicting with the
        // retry advice in the same sentence).
        _showSnackBar('通知设置更新超时，请稍后刷新确认；若未生效请点击重试同步');
      } else {
        // A deterministic rejection: the server state is unchanged, so
        // roll the switch back and surface the failure.
        setState(() {
          _muted = !muted;
          _mutedLoadError = error;
          _muteTimedOut = false;
        });
        _showSnackBar('通知设置更新失败: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _muteSaving = false);
        if (_roomStateRefreshTrailing) unawaited(_refreshRoomState());
        // A load skipped while the mute write was in flight also left the
        // member list stale; consume its trailing flag too.
        if (_membersRefreshTrailing) unawaited(_refreshMembers());
      }
    }
  }

  void _showInviteDialog() {
    if (!_accountActive()) return;
    var invitedUserId = '';
    var inviting = false;
    String? inviteError;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => PopScope(
          // The request may run for up to 90s (queue bound): the dialog
          // must stay dismissible (barrier tap, system back, cancel) so a
          // mis-tap is not a 90s lock-in. The write keeps running in its
          // server/queue tail and converges via invalidation; both the
          // success and the failure paths fall back to the page snackbar
          // when the dialog is gone.
          canPop: true,
          child: Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: const EdgeInsets.symmetric(horizontal: 32),
            child: GlassPanel(
              radius: NeuRadius.nav,
              padding: const EdgeInsets.all(22),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '邀请用户',
                      style: Theme.of(dialogContext).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    NeuTextField(
                      hint: '@user:server.example',
                      autofocus: true,
                      onChanged: (value) => invitedUserId = value,
                    ),
                    if (inviteError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          inviteError!,
                          style: Theme.of(dialogContext).textTheme.bodyMedium
                              ?.copyWith(color: dialogContext.neu.error),
                        ),
                      ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: NeuButton(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            onPressed: inviting
                                ? null
                                : () => Navigator.of(dialogContext).pop(),
                            child: const Center(child: Text('取消')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: NeuButton(
                            accent: true,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            onPressed: inviting
                                ? null
                                : () async {
                                    // Entry guard (not only the disabled button): the
                                    // rebuild lags a frame, so a second tap on the old
                                    // widget could otherwise issue a duplicate invite.
                                    if (inviting) return;
                                    final userId = invitedUserId.trim();
                                    if (userId.isEmpty) return;
                                    setDialogState(() {
                                      inviting = true;
                                      inviteError = null;
                                    });
                                    try {
                                      await rust.inviteUserToRoom(
                                        accountUserId: _openedUserId ?? '',
                                        roomId: widget.roomId,
                                        userId: userId,
                                      );
                                      // Close the dialog first, then report: if the page
                                      // is gone (dismissal race), the dialog must not
                                      // stay stuck in its non-dismissible in-flight state
                                      // — mirror the error path. `isCurrent` guard: the
                                      // dialog may already be in its exit animation —
                                      // popping then would pop the page below it.
                                      if (dialogContext.mounted &&
                                          ModalRoute.of(
                                                dialogContext,
                                              )?.isCurrent ==
                                              true) {
                                        Navigator.of(dialogContext).pop();
                                      }
                                      // The account may have switched while the request
                                      // was in flight: the invite itself was guarded
                                      // server-side, so skip the local bookkeeping (the
                                      // page shows the switched placeholder).
                                      if (!mounted || !_accountActive()) return;
                                      // Room invalidation and the feedback must not
                                      // depend on the dialog still being up.
                                      _invalidateRoom();
                                      _showSnackBar('邀请已发送');
                                      // Fire the member refetch detached, like the knock
                                      // approval path: the invitee must appear without
                                      // waiting for the server join event.
                                      unawaited(_retryMembers());
                                    } catch (error) {
                                      if (!mounted) {
                                        // The page is gone: close the dialog so it is
                                        // not stuck in its non-dismissible in-flight
                                        // state.
                                        if (dialogContext.mounted &&
                                            ModalRoute.of(
                                                  dialogContext,
                                                )?.isCurrent ==
                                                true) {
                                          Navigator.of(dialogContext).pop();
                                        }
                                        return;
                                      }
                                      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
                                      if (!_accountActive()) {
                                        if (dialogContext.mounted &&
                                            ModalRoute.of(
                                                  dialogContext,
                                                )?.isCurrent ==
                                                true) {
                                          Navigator.of(dialogContext).pop();
                                        }
                                        return;
                                      }
                                      if (dialogContext.mounted) {
                                        setDialogState(() {
                                          inviting = false;
                                          // Render the failure inside the dialog: a
                                          // page-level snackbar would sit beneath the
                                          // modal barrier and stay invisible while the
                                          // dialog stays open for retry.
                                          inviteError = _actionFailureMessage(
                                            error,
                                          );
                                        });
                                      } else if (mounted) {
                                        // The dialog was dismissed while the request was
                                        // in flight: fall back to the page snackbar so
                                        // the failure is not completely silent.
                                        _showActionFailure(error);
                                      }
                                    }
                                  },
                            child: const Center(child: Text('邀请')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Returns whether the server write succeeded (false on failure or a
  /// mid-flight account switch), so callers can decide e.g. whether to
  /// close their sheet. When [onError] is provided, the failure message is
  /// delivered through it instead of the page snackbar — for callers whose
  /// UI (e.g. an open bottom sheet) would hide a page-level snackbar.
  Future<bool> _setUserIgnored(
    String userId,
    bool ignored, {
    void Function(String message)? onError,
    void Function(String message)? onSuccess,
  }) async {
    if (!_accountActive()) return false;
    // Entry guard: a second tap before the first write resolves would
    // issue a duplicate ignored-list write (serialized server-side, but
    // with contradictory feedback when the first one fails).
    if (!_pendingIgnoreUserIds.add(userId)) return false;
    // Captured before the await: the write-through must run even if this
    // page is popped while the server request is in flight.
    final namespace = _openedUserId ?? '';
    try {
      final updated = await rust.setUserIgnored(
        accountUserId: namespace,
        userId: userId,
        ignored: ignored,
      );
      // The server write succeeded: write the returned full list through to
      // the local snapshot so open timelines hide/show the sender's messages
      // now, without waiting for a background refresh that may fail offline.
      // Persisting the complete list (not a delta) also keeps other ignored
      // users when no local snapshot exists yet. The write-through itself
      // revalidates ignoredUserIdsProvider app-wide, so this stays correct
      // even when the page is popped before the request completes.
      await persistIgnoredUserList(namespace, updated.toSet());
      // The account may have switched while the request was in flight: the
      // write itself was guarded server-side (and namespaced to the opened
      // account), so just skip the local bookkeeping — the page shows the
      // switched placeholder anyway.
      if (!_accountActive()) return false;
      setState(() {
        _ignoredUsers = updated.toList()..sort();
      });
      final message = ignored ? '已忽略 $userId' : '已取消忽略 $userId';
      if (onSuccess != null) {
        // The caller (e.g. an open bottom sheet) delivers the message after
        // closing its UI, so it is not hidden behind the modal barrier.
        onSuccess(message);
      } else {
        _showSnackBar(message);
      }
      return true;
    } catch (error) {
      // The account may have switched while the request was in flight (the
      // Rust guard then rejects deterministically): the page shows the
      // switched placeholder — don't surface a failure snackbar that
      // contradicts it (same discipline as `_setMuted`).
      if (!mounted || !_accountActive()) return false;
      if (mounted) {
        // Shared wording: timeout mapping and partial-success passthrough
        // come from the single `actionFailureMessage` source.
        final failure = _actionFailureMessage(error);
        if (onError != null) {
          onError(failure);
        } else {
          _showSnackBar(failure);
        }
      }
      return false;
    } finally {
      _pendingIgnoreUserIds.remove(userId);
    }
  }

  void _showIgnoredUsers() {
    showNeuSheet<void>(
      context: context,
      // Watch the provider inside the sheet so a retry (or the initial
      // load) updates the sheet in place, and a load error renders an
      // error row with a retry entry instead of a misleading "暂无".
      child: Consumer(
        builder: (context, ref, _) {
          final ignoredAsync = ref.watch(ignoredUserIdsProvider);
          final ignoredUsers = [...?ignoredAsync.value]..sort();
          final loadError = ignoredAsync.hasError ? ignoredAsync.error : null;
          // Failure feedback must render inside the sheet: a page-level
          // snackbar would appear beneath the open sheet and stay
          // invisible. Kept on the STATE so a provider rebuild of this
          // builder cannot orphan an in-flight error write.
          return StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              // Track the sheet's context: an account switch dismisses the
              // sheet through it (see the activeUserIdProvider listener).
              _ignoredUsersSheetContext = sheetContext;
              final colors = sheetContext.neu;
              if (loadError != null) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '加载已忽略用户失败',
                        style: Theme.of(
                          sheetContext,
                        ).textTheme.bodyMedium?.copyWith(color: colors.error),
                      ),
                      const SizedBox(height: 12),
                      NeuButton(
                        onPressed: () => ref.invalidate(ignoredUserIdsProvider),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                );
              }
              if (ignoredUsers.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '暂无已忽略用户',
                    style: Theme.of(sheetContext).textTheme.bodyMedium,
                  ),
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_ignoredUsersSheetError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: Text(
                        _ignoredUsersSheetError!,
                        style: Theme.of(
                          sheetContext,
                        ).textTheme.bodyMedium?.copyWith(color: colors.error),
                      ),
                    ),
                  for (var index = 0; index < ignoredUsers.length; index++) ...[
                    if (index > 0) const NeuSheetDivider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(
                                ignoredUsers[index],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(
                                  sheetContext,
                                ).textTheme.bodyLarge,
                              ),
                            ),
                          ),
                          NeuIconButton(
                            icon: Icons.person_add_alt_rounded,
                            size: 38,
                            tooltip: '取消忽略',
                            onPressed: () async {
                              // Only close the sheet when the server write
                              // succeeded; on failure keep the list visible
                              // so the user can retry, and surface the error
                              // inside the sheet (see onError).
                              await _setUserIgnored(
                                ignoredUsers[index],
                                false,
                                onError: (message) {
                                  if (sheetContext.mounted) {
                                    setSheetState(
                                      () => _ignoredUsersSheetError = message,
                                    );
                                  } else if (mounted) {
                                    // The sheet was dismissed while the
                                    // request was in flight: fall back to
                                    // the page snackbar (same discipline as
                                    // the invite dialog) — a silent failure
                                    // would look like a stuck row.
                                    _showSnackBar(message);
                                  }
                                },
                                onSuccess: (message) {
                                  // Close the sheet first, then report: a
                                  // page snackbar queued while the sheet is
                                  // still up would sit hidden behind its
                                  // barrier. `isCurrent` guard: the sheet may
                                  // already be in its exit animation.
                                  if (sheetContext.mounted &&
                                      ModalRoute.of(sheetContext)?.isCurrent ==
                                          true) {
                                    Navigator.of(sheetContext).pop();
                                  }
                                  if (context.mounted) {
                                    _showSnackBar(message);
                                  }
                                },
                              );
                              // The success path pops the sheet and reports
                              // via onSuccess; a failure keeps it open for
                              // retry.
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    ).whenComplete(() {
      _ignoredUsersSheetContext = null;
      _ignoredUsersSheetError = null;
    });
  }

  Future<void> _runKnockAction(rust.KnockRequest request, bool approve) async {
    if (!_accountActive()) return;
    if (_pendingKnockUserIds.contains(request.userId)) return;
    setState(() => _pendingKnockUserIds.add(request.userId));
    try {
      if (approve) {
        await rust.approveRoomKnock(
          accountUserId: _openedUserId ?? '',
          roomId: widget.roomId,
          userId: request.userId,
        );
      } else {
        await rust.rejectRoomKnock(
          accountUserId: _openedUserId ?? '',
          roomId: widget.roomId,
          userId: request.userId,
        );
      }
      // The account may have switched while the request was in flight:
      // skip the local bookkeeping (the page shows the switched
      // placeholder).
      if (!_accountActive()) return;
      if (!mounted) return;
      setState(() => _handledKnockUserIds[request.userId] = clock.now());
      _scheduleHandledKnockExpiry();
      _invalidateRoom();
      // Report first: the member refetch below can take a while (bounded)
      // and must not delay the success feedback.
      _showSnackBar(approve ? '已批准加入请求' : '已拒绝加入请求');
      if (approve) {
        // Fire the member refetch detached: it can take up to 90s (bounded)
        // and must not keep this knocker's button busy that long.
        unawaited(_retryMembers());
      }
    } catch (error) {
      // The account may have switched while the request was in flight (the
      // Rust guard then rejects deterministically): the page shows the
      // switched placeholder — don't surface a failure snackbar that
      // contradicts it (same discipline as `_setMuted`).
      if (!mounted || !_accountActive()) return;
      final errorText = '$error';
      if (errorText.contains('已不再是此房间的加入请求')) {
        // The server-side pre-verify found the current membership is no
        // longer a knock: our own earlier attempt (e.g. after a timeout or
        // when the 10s hide grace expired before the echo landed), another
        // admin, or the user's withdrawal may have already processed it.
        // Report it as "possibly handled" instead of a bare failure, hide
        // the entry and let the refetch confirm the real state.
        setState(() {
          _handledKnockUserIds[request.userId] = clock.now();
        });
        _scheduleHandledKnockExpiry();
        _invalidateRoom();
        _showSnackBar('该请求可能已被处理，正在刷新确认');
      } else {
        _showActionFailure(error);
      }
    } finally {
      if (mounted) {
        setState(() => _pendingKnockUserIds.remove(request.userId));
      }
    }
  }

  Future<void> _confirmLeave() async {
    // A previous leave may still be in flight after its confirm sheet was
    // dismissed (the request keeps running): keep the page-level flag — a
    // re-opened confirm must not fire a second concurrent leave. The
    // request's finally resets the flag once it ends, so a later reopen
    // renders a clean state.
    if (_leavingRoom) {
      _showSnackBar('正在退出房间，请稍候');
      return;
    }
    final confirmed = await showNeuConfirm(
      context,
      title: '退出房间',
      message: '退出后将无法继续接收此房间的新消息。',
      confirmLabel: '退出',
      danger: true,
    );
    if (!confirmed || !mounted || !_accountActive()) return;
    setState(() => _leavingRoom = true);
    try {
      await rust.leaveRoom(
        accountUserId: _openedUserId ?? '',
        roomId: widget.roomId,
      );
      // The account may have switched while the request was in flight (the
      // write itself landed under the previous account): skip the local
      // bookkeeping — the page shows the switched placeholder.
      if (!_accountActive()) return;
      _invalidateRoom();
      _closeCurrentRoom();
    } catch (error) {
      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
      if (!mounted || !_accountActive()) return;
      _showActionFailure(error);
    } finally {
      if (mounted) {
        setState(() => _leavingRoom = false);
      }
    }
  }

  bool _isKnockHidden(String userId) {
    final handledAt = _handledKnockUserIds[userId];
    return handledAt != null &&
        clock.now().difference(handledAt) < _handledKnockGrace;
  }

  void _scheduleHandledKnockExpiry() {
    _handledKnockExpiryTimer?.cancel();
    if (_handledKnockUserIds.isEmpty) return;
    final now = clock.now();
    final nextExpiry = _handledKnockUserIds.values
        .map((handledAt) => handledAt.add(_handledKnockGrace))
        .reduce((earlier, later) => earlier.isBefore(later) ? earlier : later);
    final delay = nextExpiry.difference(now);
    _handledKnockExpiryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        if (!mounted) return;
        setState(() {
          _handledKnockUserIds.removeWhere(
            (_, handledAt) =>
                !handledAt.add(_handledKnockGrace).isAfter(nextExpiry),
          );
        });
        _scheduleHandledKnockExpiry();
      },
    );
  }

  Widget _header(rust.RoomDetails? details) {
    final colors = context.neu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeuSpacing.sm,
        NeuSpacing.sm,
        NeuSpacing.md,
        NeuSpacing.xs,
      ),
      child: Row(
        children: [
          NeuIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 40,
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: NeuSpacing.sm),
          Expanded(
            child: Text(
              '房间管理',
              style: Theme.of(context).textTheme.titleLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_saving)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  color: colors.accent,
                  strokeWidth: 2,
                ),
              ),
            )
          else
            NeuIconButton(
              icon: Icons.save_outlined,
              size: 40,
              tooltip: '保存房间信息',
              onPressed: details == null ? null : _saveDetails,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep the shared sync handler alive so ignoredUserIdsProvider receives
    // account-data and lag-compensation invalidations even when this page is
    // tested or presented outside the usual app shell.
    ref.watch(syncStreamProvider);
    final details = _details;
    final knockRequestsAsync = ref.watch(
      roomKnockRequestsProvider(widget.roomId),
    );
    ref.listen(roomKnockRequestsProvider(widget.roomId), (_, next) {
      // The provider follows the active session; after an account switch it
      // would carry the new account's data into this page's hidden-set
      // bookkeeping, so ignore it entirely.
      if (!_accountActive()) return;
      // Mutating _handledKnockUserIds here is safe without setState: this
      // page watches the same provider, so the notification that fires this
      // listener also rebuilds the widget, and the build reads the updated
      // set through _isKnockHidden.
      next.whenData((requests) {
        final activeUserIds = requests.map((request) => request.userId).toSet();
        _handledKnockUserIds.removeWhere(
          (userId, _) =>
              !activeUserIds.contains(userId) || !_isKnockHidden(userId),
        );
        _scheduleHandledKnockExpiry();
      });
    });
    final knockRequests =
        // `value` keeps the previous list while a refresh is in flight
        // (`asData` is null during loading), so the section does not blink
        // out of existence on every sync cycle.
        (knockRequestsAsync.value ?? const <rust.KnockRequest>[])
            .where((request) => !_isKnockHidden(request.userId))
            .toList();
    final knocksLoadError = knockRequestsAsync.hasError
        ? knockRequestsAsync.error
        : null;
    final colors = context.neu;
    return Scaffold(
      backgroundColor: colors.base,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: SafeArea(bottom: false, child: _header(details)),
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                color: colors.accent,
                strokeWidth: 2,
              ),
            )
          : _accountSwitched
          ? Center(
              child: Text(
                '账号已切换',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          : _error != null
          ? Center(
              child: NeuButton(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _load,
                child: Text('加载失败: $_error'),
              ),
            )
          : Padding(
              // CustomScrollView has no `padding` parameter; pad the viewport
              // itself with the insets the ListView used to carry.
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _section(
                      title: '房间信息',
                      child: Column(
                        children: [
                          Center(
                            child: Stack(
                              children: [
                                if (_avatarPreviewBytes case final bytes?)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      NeuRadius.content,
                                    ),
                                    child: Image.memory(
                                      bytes,
                                      width: 76,
                                      height: 76,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                else
                                  AppAvatar(
                                    fallback: details!.name,
                                    size: 76,
                                    radius: NeuRadius.content,
                                    url: details.avatarUrl,
                                  ),
                                Positioned(
                                  right: -4,
                                  bottom: -4,
                                  child: NeuIconButton(
                                    icon: Icons.edit_rounded,
                                    size: 36,
                                    tooltip: '修改房间头像',
                                    onPressed: _saving ? null : _pickAvatar,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          NeuTextField(
                            controller: _nameController,
                            hint: '房间名称',
                          ),
                          const SizedBox(height: 12),
                          NeuTextField(
                            controller: _topicController,
                            hint: '房间主题',
                            maxLines: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  SliverToBoxAdapter(
                    child: _section(
                      title: _membersLoadError == null
                          ? '成员 ${_members.length}'
                          : '成员',
                      action: NeuIconButton(
                        icon: Icons.person_add_alt_1_rounded,
                        size: 38,
                        tooltip: '邀请用户',
                        onPressed: _showInviteDialog,
                      ),
                      child: _membersLoadError != null && _members.isEmpty
                          ? _partialLoadErrorTile(
                              label: '无法加载成员',
                              onRetry: _retryMembers,
                            )
                          : Column(
                              children: [
                                // Keep previously loaded members visible when a
                                // refresh fails; only a first load with no data
                                // at all shows the error tile instead.
                                if (_membersLoadError != null) ...[
                                  _partialLoadErrorTile(
                                    label: '成员刷新失败，显示缓存数据',
                                    onRetry: _retryMembers,
                                  ),
                                  const Divider(height: 1),
                                ],
                              ],
                            ),
                    ),
                  ),
                  // Only the member tiles are virtualized: off-screen entries
                  // are built lazily, so a rebuild no longer constructs every
                  // tile up front. The tiles keep the section card's surface
                  // background and horizontal padding so the section still
                  // reads as one card.
                  SliverList.builder(
                    itemCount: _members.length,
                    itemBuilder: (context, index) {
                      final member = _members[index];
                      return ColoredBox(
                        color: context.neu.card,
                        child: _memberTile(member),
                      );
                    },
                  ),
                  if (knocksLoadError != null || knockRequests.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    SliverToBoxAdapter(
                      child: _section(
                        title: knocksLoadError == null
                            ? '加入请求 ${knockRequests.length}'
                            : '加入请求',
                        child: knocksLoadError != null && knockRequests.isEmpty
                            ? _partialLoadErrorTile(
                                label: '无法加载加入请求',
                                onRetry: _retryKnocks,
                              )
                            : Column(
                                children: [
                                  if (knocksLoadError != null) ...[
                                    _partialLoadErrorTile(
                                      label: '加入请求刷新失败，显示缓存数据',
                                      onRetry: _retryKnocks,
                                    ),
                                    const Divider(height: 1),
                                  ],
                                ],
                              ),
                      ),
                    ),
                    // The knock tiles are virtualized like the member tiles.
                    SliverList.builder(
                      itemCount: knockRequests.length,
                      itemBuilder: (context, index) {
                        final request = knockRequests[index];
                        return ColoredBox(
                          color: context.neu.card,
                          child: _knockTile(request),
                        );
                      },
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  SliverToBoxAdapter(
                    child: _section(
                      title: '通知与消息',
                      child: Column(
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            activeThumbColor: context.neu.accent,
                            title: Text(
                              '免打扰',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            subtitle: Text(
                              _mutedLoadError == null
                                  ? '不接收此房间的推送通知'
                                  : '通知设置加载/更新失败，点击重试',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            value: _muted,
                            onChanged: _mutedLoadError == null && !_muteSaving
                                ? _setMuted
                                : null,
                            secondary: _muteSaving
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      color: context.neu.accent,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : _mutedLoadError == null
                                ? null
                                : NeuIconButton(
                                    icon: Icons.refresh_rounded,
                                    size: 38,
                                    tooltip: '重试',
                                    onPressed: _muteSaving ? null : _retryMuted,
                                  ),
                          ),
                          _actionTile(
                            icon: Icons.push_pin_rounded,
                            label: '置顶消息',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    PinnedMessagesPage(roomId: widget.roomId),
                              ),
                            ),
                          ),
                          _actionTile(
                            icon: Icons.done_all_rounded,
                            label: '标记为已读',
                            saving: _markSaving,
                            onTap: _markSaving
                                ? null
                                : () async {
                                    // Entry guard (not only the disabled
                                    // button): the rebuild lags a frame, so a
                                    // same-frame second tap could otherwise
                                    // issue a duplicate write.
                                    if (!_accountActive() || _markSaving) {
                                      return;
                                    }
                                    setState(() => _markSaving = true);
                                    final suppression =
                                        roomAutoReadSuppressedProvider(
                                          widget.roomId,
                                        );
                                    final suppressionNotifier = ref.read(
                                      suppression.notifier,
                                    );
                                    final previousSuppression =
                                        suppressionNotifier.value;
                                    final suppressionToken =
                                        setRoomAutoReadSuppressed(
                                          ref,
                                          widget.roomId,
                                          suppressed: false,
                                        );
                                    try {
                                      await rust.markRoomAsRead(
                                        accountUserId: _openedUserId ?? '',
                                        roomId: widget.roomId,
                                        explicit: true,
                                      );
                                      // The account may have switched while the
                                      // request was in flight: the write itself
                                      // was guarded server-side, so skip ALL
                                      // feedback on an account switch (the page
                                      // shows the switched placeholder — same
                                      // discipline as `_setMuted`). On a pure
                                      // token takeover the server write
                                      // succeeded regardless: still report it;
                                      // only the override and list invalidation
                                      // belong to the token holder (a takeover
                                      // owns that bookkeeping).
                                      if (!mounted || !_accountActive()) return;
                                      if (suppressionToken.isCurrent) {
                                        setRoomUnreadOverrideById(
                                          ref,
                                          widget.roomId,
                                          unread: false,
                                        );
                                        _invalidateRoom();
                                      }
                                      _showSnackBar('已标记为已读');
                                    } catch (error) {
                                      // The provider bookkeeping restores even
                                      // when the page is gone (the writes are
                                      // global); only the snackbar needs it.
                                      if (suppressionToken.isCurrent) {
                                        // Only the actor holding the suppression
                                        // token restores it; a takeover (chat
                                        // page re-activation) owns its own
                                        // bookkeeping.
                                        suppressionNotifier.value =
                                            previousSuppression;
                                        // A STALE-armed restoration (a previous
                                        // mark-unread timeout left it true) must
                                        // still be converged: the old entry's
                                        // revision no longer matches after this
                                        // write bumped it, so register afresh
                                        // (same discipline as the mark-unread
                                        // branch).
                                        if (previousSuppression) {
                                          noteTimedOutUnreadSuppression(
                                            widget.roomId,
                                            revision: suppressionToken.value,
                                          );
                                        }
                                      }
                                      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
                                      if (!mounted || !_accountActive()) return;
                                      if (mounted) {
                                        // The write failed regardless of the
                                        // takeover: surface it (the snackbar
                                        // shows on the visible page even when
                                        // the management page sits below the
                                        // chat).
                                        _showActionFailure(error);
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() => _markSaving = false);
                                      }
                                    }
                                  },
                          ),
                          _actionTile(
                            icon: Icons.mark_unread_chat_alt_rounded,
                            label: '标记为未读',
                            saving: _markSaving,
                            onTap: _markSaving
                                ? null
                                : () async {
                                    // Entry guard (not only the disabled
                                    // button): the rebuild lags a frame, so a
                                    // same-frame second tap could otherwise
                                    // issue a duplicate write.
                                    if (!_accountActive() || _markSaving) {
                                      return;
                                    }
                                    setState(() => _markSaving = true);
                                    final suppression =
                                        roomAutoReadSuppressedProvider(
                                          widget.roomId,
                                        );
                                    final suppressionNotifier = ref.read(
                                      suppression.notifier,
                                    );
                                    final previousSuppression =
                                        suppressionNotifier.value;
                                    final unreadOverrideNotifier = ref.read(
                                      roomUnreadOverrideProvider(
                                        widget.roomId,
                                      ).notifier,
                                    );
                                    final previousUnreadOverride =
                                        unreadOverrideNotifier.value;
                                    final suppressionToken =
                                        setRoomAutoReadSuppressed(
                                          ref,
                                          widget.roomId,
                                          suppressed: true,
                                        );
                                    setRoomUnreadOverrideById(
                                      ref,
                                      widget.roomId,
                                      unread: true,
                                    );
                                    try {
                                      await rust.markRoomUnread(
                                        accountUserId: _openedUserId ?? '',
                                        roomId: widget.roomId,
                                      );
                                      if (!mounted || !_accountActive()) return;
                                      // The server write succeeded regardless of
                                      // the token: still report it. The
                                      // invalidation and the room close belong
                                      // to the token holder (a takeover owns
                                      // that bookkeeping — closing the room
                                      // under a new viewer would be wrong).
                                      if (suppressionToken.isCurrent) {
                                        _invalidateRoom();
                                        _closeCurrentRoom();
                                      }
                                      _showSnackBar('已标记为未读');
                                    } catch (error) {
                                      // The provider bookkeeping restores even
                                      // when the page is gone (the writes are
                                      // global); only the snackbar needs it.
                                      if (suppressionToken.isCurrent) {
                                        // Only the actor holding the suppression
                                        // token restores it; a takeover (chat
                                        // page re-activation) owns its own
                                        // bookkeeping.
                                        //
                                        // A timeout is not a failure: the queued
                                        // write's tail may still land (same
                                        // discipline as the mute timeout marker).
                                        // Keep the suppression armed so a later
                                        // auto-read cannot revoke a marker that
                                        // did land — drop only the optimistic
                                        // override (its TTL covers a real
                                        // failure). A confirmed failure restores
                                        // both.
                                        unreadOverrideNotifier.value =
                                            previousUnreadOverride;
                                        if (!isMutationTimeout(error)) {
                                          suppressionNotifier.value =
                                              previousSuppression;
                                          // Restoring a STALE-armed suppression
                                          // (a previous write's timeout left it
                                          // true) must still be converged: the
                                          // old entry may already be gone (its
                                          // revision no longer matches after
                                          // this write bumped it) — register
                                          // afresh with the current revision so
                                          // the sync flow can still lift the
                                          // suppression once this write is
                                          // definitively failed.
                                          if (previousSuppression) {
                                            noteTimedOutUnreadSuppression(
                                              widget.roomId,
                                              revision: suppressionToken.value,
                                            );
                                          }
                                        } else {
                                          // The suppression stays armed: register
                                          // the room so the sync flow converges
                                          // it if the write ultimately failed
                                          // (same discipline as the mute 250s
                                          // convergence read). The token's
                                          // revision is the value captured when
                                          // the write armed the suppression —
                                          // read before the await, so this works
                                          // even if the page was disposed.
                                          noteTimedOutUnreadSuppression(
                                            widget.roomId,
                                            revision: suppressionToken.value,
                                          );
                                        }
                                      }
                                      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
                                      if (!mounted || !_accountActive()) return;
                                      if (mounted) {
                                        // The write failed regardless of the
                                        // takeover: surface it (the snackbar
                                        // shows on the visible page even when
                                        // the management page sits below the
                                        // chat).
                                        _showActionFailure(error);
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() => _markSaving = false);
                                      }
                                    }
                                  },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  SliverToBoxAdapter(
                    child: _section(
                      title: '隐私',
                      child: _actionTile(
                        icon: _ignoredUsersLoadError == null
                            ? Icons.block_rounded
                            : Icons.refresh_rounded,
                        label: _ignoredUsersLoadError == null
                            ? '已忽略用户 (${_ignoredUsers.length})'
                            : '无法加载已忽略用户',
                        onTap: _ignoredUsersLoadError == null
                            ? _showIgnoredUsers
                            : _retryIgnoredUsers,
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  SliverToBoxAdapter(
                    child: _section(
                      title: '危险操作',
                      child: _actionTile(
                        icon: Icons.exit_to_app_rounded,
                        label: '退出房间',
                        danger: true,
                        onTap: _confirmLeave,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _knockTile(rust.KnockRequest request) {
    final colors = context.neu;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AppAvatar(
        fallback: request.displayName,
        size: 40,
        radius: NeuRadius.content,
        url: request.avatarUrl,
      ),
      title: Text(
        request.displayName,
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        request.reason?.isNotEmpty == true
            ? '${request.userId}\n${request.reason}'
            : request.userId,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      isThreeLine: request.reason?.isNotEmpty == true,
      trailing: Wrap(
        spacing: 2,
        children: [
          IconButton(
            tooltip: '批准',
            icon: Icon(Icons.check_rounded, color: colors.accent),
            onPressed: _pendingKnockUserIds.contains(request.userId)
                ? null
                : () => _runKnockAction(request, true),
          ),
          IconButton(
            tooltip: '拒绝',
            icon: Icon(Icons.close_rounded, color: colors.error),
            onPressed: _pendingKnockUserIds.contains(request.userId)
                ? null
                : () => _runKnockAction(request, false),
          ),
        ],
      ),
    );
  }

  Widget _memberTile(rust.Contact member) {
    final activeUserId = ref.read(activeUserIdProvider);
    final isCurrentUser = member.id == activeUserId;
    final ignored = _ignoredUsers.contains(member.id);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AppAvatar(
        fallback: member.name,
        size: 40,
        radius: NeuRadius.content,
        url: member.avatarUrl,
      ),
      title: Text(
        member.name,
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(member.id, style: Theme.of(context).textTheme.bodySmall),
      trailing: isCurrentUser
          ? null
          : NeuIconButton(
              icon: ignored
                  ? Icons.person_add_alt_rounded
                  : Icons.block_rounded,
              size: 38,
              accent: ignored,
              tooltip: _ignoredUsersLoadError != null
                  ? '无法加载忽略状态'
                  : ignored
                  ? '取消忽略'
                  : '忽略用户',
              onPressed: _ignoredUsersLoadError == null
                  ? () => _setUserIgnored(member.id, !ignored)
                  : null,
            ),
    );
  }

  Widget _partialLoadErrorTile({
    required String label,
    required VoidCallback onRetry,
  }) {
    final colors = context.neu;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.error_outline_rounded, color: colors.textTertiary),
      title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      trailing: NeuIconButton(
        icon: Icons.refresh_rounded,
        size: 38,
        tooltip: '重试',
        onPressed: onRetry,
      ),
    );
  }

  Widget _section({
    required String title,
    required Widget child,
    Widget? action,
  }) {
    return NeuSurface(
      color: context.neu.card,
      radius: NeuRadius.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ?action,
            ],
          ),
          child,
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool danger = false,
    bool saving = false,
  }) {
    final colors = context.neu;
    final color = danger ? colors.error : colors.text;
    return NeuAction(
      radius: NeuRadius.button,
      label: label,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: danger ? colors.error : colors.accent),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: color),
              ),
            ),
            if (saving)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  color: colors.accent,
                  strokeWidth: 2,
                ),
              )
            else
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colors.textTertiary,
              ),
          ],
        ),
      ),
    );
  }
}
