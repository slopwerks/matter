import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'action_failure_message.dart';
import 'chat_timestamp.dart';

class PinnedMessagesPage extends ConsumerStatefulWidget {
  final String roomId;

  const PinnedMessagesPage({super.key, required this.roomId});

  @override
  ConsumerState<PinnedMessagesPage> createState() => _PinnedMessagesPageState();
}

class _PinnedMessagesPageState extends ConsumerState<PinnedMessagesPage> {
  List<rust.ChatMessage>? _messages;
  Object? _loadError;
  bool _loading = true;
  bool _reloadTrailing = false;

  /// Set when the account switched while this page was alive: the page then
  /// shows a neutral placeholder instead of stale data or a bogus error.
  bool _accountSwitched = false;

  /// Message ids whose unpin request is in flight, mapped to the moment the
  /// lock was taken. setPinnedMessage is an idempotent set (re-applying an
  /// already-held state is a server-side no-op), so a repeated unpin cannot
  /// re-pin — the lock exists to keep the button disabled while a write may
  /// still be queued (a stale reload can re-show the row before the removal
  /// is confirmed) and to avoid duplicate concurrent writes. Locks expire
  /// after [_unpinLockTimeout] so a message that gets re-pinned on another
  /// device (or a row that never leaves a stale list) cannot disable its
  /// button forever.
  final Map<String, DateTime> _pendingUnpinIds = {};
  static const Duration _unpinLockTimeout = Duration(seconds: 30);
  Timer? _unpinLockExpiryTimer;

  /// Toggles still awaiting their server response, independent of the lock:
  /// a lock may expire while its toggle is still in flight (very slow
  /// network), and the button must stay disabled either way.
  final Set<String> _inflightUnpinIds = {};

  bool _unpinLocked(String messageId) {
    final lockedAt = _pendingUnpinIds[messageId];
    if (lockedAt == null) return false;
    // Expired entries are removed only by the expiry timer
    // (_scheduleUnpinLockExpiry), never here: build must stay pure.
    return clock.now().difference(lockedAt) < _unpinLockTimeout;
  }

  void _scheduleUnpinLockExpiry() {
    _unpinLockExpiryTimer?.cancel();
    if (_pendingUnpinIds.isEmpty) return;
    final now = clock.now();
    final nextExpiry = _pendingUnpinIds.values
        .map((lockedAt) => lockedAt.add(_unpinLockTimeout))
        .reduce((earlier, later) => earlier.isBefore(later) ? earlier : later);
    final delay = nextExpiry.difference(now);
    _unpinLockExpiryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (!mounted) return;
      setState(() {
        _pendingUnpinIds.removeWhere(
          (_, lockedAt) => !lockedAt.add(_unpinLockTimeout).isAfter(nextExpiry),
        );
      });
      _scheduleUnpinLockExpiry();
    });
  }

  Completer<void>? _reloadCompletion;
  late final StreamSubscription<rust.SyncEvent> _syncSubscription;
  Future<String?> _roomSubscription = Future.value(null);

  /// Whether the room subscription is currently active; a failed subscribe
  /// is re-attempted on the next successful reload. `_subscriptionPending`
  /// distinguishes "in flight" (no retry yet) from "failed" (retry).
  bool _subscriptionPending = false;
  bool _subscriptionActive = false;

  /// Set when an account switch happens while a subscribe may be in flight:
  /// the Rust side resets the subscription state on switch, so the in-flight
  /// registration (if any) is gone even if the RPC later reports success.
  /// The success handler re-subscribes instead of trusting the stale id.
  bool _subscriptionDirty = false;

  /// The account this page was opened under. The sync event stream is global
  /// across accounts, so after an account switch it may still fire for the
  /// old room; reloading then would query the new account's client for a
  /// room it may not even know.
  String? _subscribedUserId;

  Future<String?> _subscribeForReceipts() {
    // A fresh subscribe consumes any switch-dirtiness: only an in-flight
    // subscribe started before the switch needs the success handler's
    // re-check (see below).
    _subscriptionDirty = false;
    _subscriptionPending = true;
    return rust
        .subscribeRoomForReceipts(
          roomId: widget.roomId,
          // Use the page's account snapshot, not the live provider: the
          // async call could otherwise register under a switched account
          // while the page still identifies with its original one.
          accountUserId: _subscribedUserId,
        )
        .then<String?>((subscriptionId) {
          _subscriptionPending = false;
          if (_subscriptionDirty) {
            // An account switch happened while this subscribe was in
            // flight: the Rust side may have cleared the registration
            // (switch resets the subscription state). If the page's
            // account is active again, re-subscribe now; otherwise the
            // switch-back handler will.
            _subscriptionDirty = false;
            if (mounted &&
                ref.read(activeUserIdProvider) == _subscribedUserId) {
              _roomSubscription = _subscribeForReceipts();
            }
            return null;
          }
          _subscriptionActive = true;
          return subscriptionId;
        })
        .catchError((error) {
          debugPrint('subscribe pinned room updates failed: $error');
          _subscriptionPending = false;
          _subscriptionActive = false;
          return null;
        });
  }

  @override
  void initState() {
    super.initState();
    _subscribedUserId = ref.read(activeUserIdProvider);
    unawaited(_reload());
    _syncSubscription = rust.watchSyncEvents().listen((event) {
      final shouldReload = switch (event) {
        rust.SyncEvent_PinnedMessagesChanged(:final roomId) =>
          roomId == widget.roomId,
        rust.SyncEvent_FullRefreshRequired() => true,
        _ => false,
      };
      if (shouldReload && mounted) {
        unawaited(_reload());
      }
    });
    // Keep room-level state in Sliding Sync while this page covers the chat.
    _roomSubscription = _subscribeForReceipts();
    // Switching away must drop the old account's data for the neutral
    // placeholder immediately (not wait for a reload to notice), and
    // switching back must re-subscribe (the Rust side cleared it) and reload.
    ref.listenManual(activeUserIdProvider, (_, next) {
      if (!mounted) return;
      if (_subscribedUserId == null && next != null) {
        // Opened before login completed: adopt the first account and load
        // its data instead of showing the placeholder forever.
        _subscribedUserId = next;
        setState(() => _accountSwitched = false);
        if (!_subscriptionPending) {
          _roomSubscription = _subscribeForReceipts();
        }
        unawaited(_reload());
        return;
      }
      if (next != _subscribedUserId) {
        // A switch happened while a subscribe may be in flight: mark it so
        // the success handler re-checks (the Rust side resets the
        // subscription state on switch, so a "successful" pre-switch
        // registration is gone).
        _subscriptionDirty = true;
        setState(() {
          _loading = false;
          _loadError = null;
          _messages = null;
          _accountSwitched = true;
          _pendingUnpinIds.clear();
          _inflightUnpinIds.clear();
          _scheduleUnpinLockExpiry();
        });
      } else {
        // Skip if a subscription is already in flight: re-subscribing now
        // would register a second desired entry whose id nothing unsubscribes.
        if (!_subscriptionPending) {
          _roomSubscription = _subscribeForReceipts();
        }
        unawaited(_reload());
      }
    });
  }

  @override
  void dispose() {
    _syncSubscription.cancel();
    _unpinLockExpiryTimer?.cancel();
    unawaited(_unsubscribeAfterSubscribe());
    super.dispose();
  }

  Future<void> _unsubscribeAfterSubscribe() async {
    // Runs after dispose via unawaited(), so the page's UI never blocks on
    // it. Wait for the in-flight subscribe to land (a fast local
    // registration) so the subscription id is never lost — dropping it
    // would leave the room in the sliding-sync subscription set until the
    // next account switch/logout.
    final subscriptionId = await _roomSubscription;
    if (subscriptionId == null) return;
    try {
      await rust.unsubscribeRoomForReceipts(
        roomId: widget.roomId,
        subscriptionId: subscriptionId,
        accountUserId: _subscribedUserId,
      );
    } catch (error) {
      debugPrint('unsubscribe pinned room updates failed: $error');
    }
  }

  Future<void> _reload({bool showLoading = false}) {
    final active = _reloadCompletion;
    if (active != null) {
      _reloadTrailing = true;
      return active.future;
    }
    if (showLoading && _messages == null) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    final completion = Completer<void>();
    _reloadCompletion = completion;
    unawaited(_runReloads(completion));
    return completion.future;
  }

  Future<void> _runReloads(Completer<void> completion) async {
    try {
      do {
        _reloadTrailing = false;
        try {
          // The page may have been popped while a previous iteration was in
          // flight: `ref.read` on an unmounted widget throws.
          if (!mounted) return;
          if (ref.read(activeUserIdProvider) != _subscribedUserId) {
            // The page outlived its account: stop loading (and stop the
            // spinner a `showLoading: true` reload may have started) and
            // drop stale data in favor of a neutral placeholder — stale
            // rows rendered with the new account's ignore list would be a
            // mixed-account view.
            if (mounted) {
              setState(() {
                _loading = false;
                _loadError = null;
                _messages = null;
                _accountSwitched = true;
                _pendingUnpinIds.clear();
                _inflightUnpinIds.clear();
                _scheduleUnpinLockExpiry();
              });
            }
            return;
          }
          final messages = await rust.getPinnedMessages(roomId: widget.roomId);
          // The account may have switched while the request was in flight:
          // the result belongs to whatever account was active on the Rust
          // side, so re-check before applying it. Never touch the ref after
          // the page was popped (reading through an unmounted ref throws).
          if (!mounted) return;
          if (ref.read(activeUserIdProvider) != _subscribedUserId) {
            if (mounted) {
              setState(() {
                _loading = false;
                _loadError = null;
                _messages = null;
                _accountSwitched = true;
                _pendingUnpinIds.clear();
                _inflightUnpinIds.clear();
                _scheduleUnpinLockExpiry();
              });
            }
            return;
          }
          if (!mounted) return;
          setState(() {
            _messages = messages;
            _loadError = null;
            _loading = false;
            _accountSwitched = false;
            // Release only the locks whose message left the list. A reload
            // can serve a stale snapshot (the offline store fallback, or a
            // concurrent toggle still queued on the server), so a row that
            // is still present keeps its lock until a later reload removes
            // it — otherwise the unlocked row invites a re-pinning tap.
            // Locked ids whose row left the list are settled either way.
            _pendingUnpinIds.removeWhere(
              (id, _) => !messages.any((message) => message.id == id),
            );
            _scheduleUnpinLockExpiry();
          });
          // Re-attempt a failed room subscription (only after it finished
          // with an error, never while one is in flight): without it, pinned
          // changes stop streaming in until the page is rebuilt.
          if (!_subscriptionPending && !_subscriptionActive) {
            _roomSubscription = _subscribeForReceipts();
          }
        } catch (error) {
          // Same re-check: a mid-flight switch must surface the neutral
          // placeholder, not a bogus "加载失败" for the wrong account.
          // Reading through an unmounted ref throws; guard first.
          if (!mounted) return;
          if (ref.read(activeUserIdProvider) != _subscribedUserId) {
            if (mounted) {
              setState(() {
                _loading = false;
                _loadError = null;
                _messages = null;
                _accountSwitched = true;
                _pendingUnpinIds.clear();
                _inflightUnpinIds.clear();
                _scheduleUnpinLockExpiry();
              });
            }
            return;
          }
          if (!mounted) return;
          setState(() {
            _loadError = error;
            _loading = false;
            // The account is the original one again: a load failure is a
            // regular error with its retry entry, not "账号已切换".
            _accountSwitched = false;
          });
          // The reload failed, but a broken subscription must still heal
          // (a failed subscribe is retried here just like on success).
          if (!_subscriptionPending && !_subscriptionActive) {
            _roomSubscription = _subscribeForReceipts();
          }
        }
      } while (_reloadTrailing && mounted);
    } finally {
      _reloadCompletion = null;
      completion.complete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final ignoredUserIdsAsync = ref.watch(ignoredUserIdsProvider);
    return Scaffold(
      backgroundColor: colors.base,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NeuSpacing.sm,
                NeuSpacing.sm,
                NeuSpacing.lg,
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
                      '置顶消息',
                      style: Theme.of(context).textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody(ignoredUserIdsAsync)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AsyncValue<Set<String>> ignoredUserIdsAsync) {
    final colors = context.neu;
    if (_loading && _messages == null) {
      return Center(
        child: CircularProgressIndicator(color: colors.accent, strokeWidth: 2),
      );
    }
    if (_messages == null) {
      if (_accountSwitched) {
        return Center(
          child: Text('账号已切换', style: Theme.of(context).textTheme.bodyMedium),
        );
      }
      return Center(
        child: NeuButton(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () {
            unawaited(_reload(showLoading: true));
          },
          child: Text('加载失败: $_loadError'),
        ),
      );
    }
    final ignoredUserIds = ignoredUserIdsAsync.value;
    // An unknown ignore list must not degrade into "nobody is ignored".
    if (ignoredUserIds == null) {
      if (ignoredUserIdsAsync.hasError) {
        return Center(
          child: NeuButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(ignoredUserIdsProvider),
            child: const Text('无法加载忽略列表，消息已隐藏'),
          ),
        );
      }
      return Center(
        child: CircularProgressIndicator(color: colors.accent, strokeWidth: 2),
      );
    }
    // Ignored senders' rows are KEPT (with hidden content): the row's
    // unpin button is the only way to remove a pin the user placed before
    // ignoring the sender — filtering the row away would strand the pin.
    final messages = _messages!;
    if (messages.isEmpty) {
      return RefreshIndicator(
        color: colors.accent,
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: _loadError == null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const NeuIconButton(
                            icon: Icons.push_pin_outlined,
                            size: 84,
                            onPressed: null,
                          ),
                          const SizedBox(height: NeuSpacing.lg),
                          Text(
                            '暂无置顶消息',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      )
                    : _refreshErrorTile(),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: colors.accent,
      onRefresh: _reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          NeuSpacing.lg,
          NeuSpacing.md,
          NeuSpacing.lg,
          NeuSpacing.xl,
        ),
        itemCount: messages.length + (_loadError == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (_loadError != null && index == 0) return _refreshErrorTile();
          final message = messages[index - (_loadError == null ? 0 : 1)];
          final ignoredSender =
              !message.isMe && ignoredUserIds.contains(message.senderId);
          final content = ignoredSender
              ? '来自已忽略用户的消息'
              : message.content.trim().isEmpty
              ? (message.filename ?? '媒体消息')
              : message.content;
          final locked =
              _unpinLocked(message.id) ||
              _inflightUnpinIds.contains(message.id);
          return Padding(
            key: ValueKey('pinned-message:${message.id}'),
            padding: const EdgeInsets.only(bottom: NeuSpacing.md),
            child: NeuAction(
              radius: NeuRadius.content,
              onTap: ignoredSender
                  ? null
                  : () => Navigator.of(context).pop(message.id),
              child: NeuSurface(
                color: colors.card,
                radius: NeuRadius.content,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AppAvatar(
                          fallback: message.senderName,
                          size: 34,
                          radius: NeuRadius.content,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message.senderName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(
                                formatChatListTime(message.timestamp),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                        NeuIconButton(
                          icon: Icons.push_pin_outlined,
                          size: 36,
                          tooltip: '取消置顶',
                          onPressed: locked
                              ? null
                              : () => unawaited(_unpin(message)),
                        ),
                      ],
                    ),
                    const SizedBox(height: NeuSpacing.sm),
                    Text(
                      content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _unpin(rust.ChatMessage message) async {
    if (_unpinLocked(message.id) || _inflightUnpinIds.contains(message.id)) {
      return;
    }
    if (_messages == null) return;
    if (ref.read(activeUserIdProvider) != _subscribedUserId) return;
    final originalIndex = _messages!.indexWhere((m) => m.id == message.id);
    setState(() {
      _pendingUnpinIds[message.id] = clock.now();
      _inflightUnpinIds.add(message.id);
      _scheduleUnpinLockExpiry();
      // Drop the row optimistically (the server confirmation comes with
      // the reload): keeping the row visible would invite a second tap
      // that re-pins the message while the write is still in flight. A
      // failed write restores the row below.
      _messages = List.of(_messages!)..removeWhere((m) => m.id == message.id);
    });
    try {
      // Idempotent set: the request always targets the unpinned state. The
      // lock stays until a reload confirms the row left the list (see
      // _runReloads) or times out — a stale reload snapshot must not unlock
      // it early, and a cross-device re-pin must not lock it forever.
      await rust.setPinnedMessage(
        accountUserId: _subscribedUserId ?? '',
        roomId: widget.roomId,
        eventId: message.id,
        pinned: false,
      );
      // The account may have switched while the request was in flight: the
      // write itself was guarded server-side, so just skip the local
      // bookkeeping (the page shows the switched placeholder anyway).
      if (!mounted || ref.read(activeUserIdProvider) != _subscribedUserId) {
        return;
      }
      setState(() {
        _inflightUnpinIds.remove(message.id);
        _scheduleUnpinLockExpiry();
      });
      neuToast(context, '已取消置顶');
      // Refresh towards the server state: after a removal the row stays
      // gone.
      unawaited(_reload());
    } catch (error) {
      if (!mounted || ref.read(activeUserIdProvider) != _subscribedUserId) {
        // The account switched mid-flight: the page shows the placeholder,
        // so skip the restore, snack bar, and reload entirely.
        return;
      }
      final timedOut = isMutationTimeout(error);
      setState(() {
        // The server still has the pin (the request failed
        // deterministically) or its state is unknown (a timeout — the
        // write may still be landing server-side): either way, restore the
        // row at its previous position (the list is ordered by the
        // server's pinned state, so appending at the top would
        // misrepresent it) and release the lock so the user can retry. The
        // retry is safe even while a timed-out write is still queued:
        // setPinnedMessage is an idempotent set, so the repeated
        // pinned:false write is a no-op once the pin is gone — the late
        // operation cannot flip it back.
        _pendingUnpinIds.remove(message.id);
        _inflightUnpinIds.remove(message.id);
        _scheduleUnpinLockExpiry();
        if (_messages != null &&
            !_messages!.any((entry) => entry.id == message.id) &&
            // `originalIndex` comes from this page's own pre-removal list,
            // so it is always valid here. A concurrent reload may already
            // have replaced the list (reconciling the server state,
            // possibly without this pin): restoring the row is then
            // transient — the reload below re-reads the server and settles
            // the final list.
            originalIndex >= 0) {
          final insertAt = originalIndex.clamp(0, _messages!.length);
          _messages = List.of(_messages!)..insert(insertAt, message);
        }
      });
      neuToast(
        context,
        // A timeout may still land server-side, so its wording advises a
        // refresh to confirm and points at the restored row's button for a
        // retry — that advice must not go through the failure prefix (the
        // bare timeout line already suggests "刷新确认", conflicting with
        // the retry hint in the same sentence). Plain failures share the
        // single `actionFailureMessage` mapping (timeout-worded errors map
        // to the "操作超时" line, partial-success passthrough stays intact).
        timedOut
            ? '取消置顶超时，请稍后刷新确认；若未生效请重试'
            : '取消置顶失败: ${actionFailureMessage(error)}',
      );
      // Reconcile against the server: the write may have partially landed
      // (request reached the server, response lost), so re-read the list
      // instead of trusting the local restore.
      unawaited(_reload());
    }
  }

  Widget _refreshErrorTile() {
    final colors = context.neu;
    return Padding(
      padding: const EdgeInsets.only(bottom: NeuSpacing.md),
      child: NeuSurface(
        color: colors.surfaceStrong,
        radius: NeuRadius.content,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.sync_problem_rounded, color: colors.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '刷新失败，当前显示上次结果',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: colors.text),
                  ),
                  Text(
                    '$_loadError',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            NeuIconButton(
              icon: Icons.refresh_rounded,
              size: 36,
              tooltip: '重试刷新',
              onPressed: () => unawaited(_reload()),
            ),
          ],
        ),
      ),
    );
  }
}
