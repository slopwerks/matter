use super::{
    clear_account_runtime_state, enqueue_mutation, merge_ignored_user_overrides,
    reconcile_ignored_user_overrides_inner, reconcile_marked_unread_override, resolve_ignored_user,
    resolve_marked_unread, run_bounded_mutation, IgnoredUserOverride, MarkedUnreadOverride,
    MUTATION_EXECUTION_TIMEOUT_SECS, MUTATION_QUEUE_FULL_MESSAGE, MUTATION_TAILS,
    MUTATION_WAIT_TIMEOUT_SECS,
};
use matrix_sdk::ruma::events::ignored_user_list::{IgnoredUser, IgnoredUserListEventContent};
use std::sync::atomic::Ordering;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tokio::sync::oneshot;

/// Serializes the timeout tests, which override the global
/// MUTATION_WAIT_TIMEOUT_SECS and must not run concurrently. Tokio mutex
/// so the guard may be held across awaits without clippy warnings.
static TEST_TIMEOUT_LOCK: super::Lazy<tokio::sync::Mutex<()>> =
    super::Lazy::new(|| tokio::sync::Mutex::new(()));

/// Restores MUTATION_WAIT_TIMEOUT_SECS on drop, even when a test
/// assertion panics mid-way.
struct TimeoutOverrideGuard;
impl TimeoutOverrideGuard {
    fn acquire() -> Self {
        MUTATION_WAIT_TIMEOUT_SECS.store(1, Ordering::Relaxed);
        TimeoutOverrideGuard
    }
}
impl Drop for TimeoutOverrideGuard {
    fn drop(&mut self) {
        MUTATION_WAIT_TIMEOUT_SECS.store(30, Ordering::Relaxed);
    }
}

/// Restores MUTATION_EXECUTION_TIMEOUT_SECS on drop, even when a test
/// assertion panics mid-way.
struct ExecutionTimeoutOverrideGuard;
impl ExecutionTimeoutOverrideGuard {
    fn acquire() -> Self {
        MUTATION_EXECUTION_TIMEOUT_SECS.store(1, Ordering::Relaxed);
        ExecutionTimeoutOverrideGuard
    }
}
impl Drop for ExecutionTimeoutOverrideGuard {
    fn drop(&mut self) {
        MUTATION_EXECUTION_TIMEOUT_SECS.store(300, Ordering::Relaxed);
    }
}

#[tokio::test]
async fn serializes_mutations_with_the_same_key() {
    let key = format!("test:{}", std::process::id());
    let order = Arc::new(Mutex::new(Vec::new()));
    let first_order = order.clone();
    let (release_first, wait_for_release) = oneshot::channel();
    let (first_started, wait_for_first) = oneshot::channel();
    let first_key = key.clone();
    let first = tokio::spawn(async move {
        enqueue_mutation(first_key, async move {
            first_order.lock().unwrap().push(1);
            let _ = first_started.send(());
            let _ = wait_for_release.await;
            Ok(())
        })
        .await
    });

    wait_for_first.await.unwrap();

    let second_order = order.clone();
    let second = tokio::spawn(async move {
        enqueue_mutation(key, async move {
            second_order.lock().unwrap().push(2);
            Ok(())
        })
        .await
    });

    tokio::task::yield_now().await;
    assert_eq!(*order.lock().unwrap(), [1]);

    let _ = release_first.send(());
    first.await.unwrap().unwrap();
    second.await.unwrap().unwrap();
    assert_eq!(*order.lock().unwrap(), [1, 2]);
}

#[tokio::test]
async fn dropped_mutation_waiter_retains_lifecycle_until_tail_finishes() {
    let lifecycle = Box::leak(Box::new(tokio::sync::RwLock::new(())));
    let protection = Arc::new(lifecycle.read().await);
    let key = format!("test-lifecycle:{}", std::process::id());
    let (release, wait_for_release) = oneshot::channel();
    let (started, wait_for_start) = oneshot::channel();

    let caller = tokio::spawn(run_bounded_mutation(key, protection, async move {
        let _ = started.send(());
        let _ = wait_for_release.await;
        Ok(())
    }));
    wait_for_start.await.unwrap();

    // Cancel the caller just as the 90s wrapper does on timeout. The
    // spawned queue tail must still hold the lifecycle read protection.
    caller.abort();
    let _ = caller.await;
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(50), lifecycle.write())
            .await
            .is_err()
    );

    let _ = release.send(());
    let _write_guard = tokio::time::timeout(std::time::Duration::from_secs(1), lifecycle.write())
        .await
        .expect("tail should release lifecycle protection");
}

#[tokio::test]
async fn timed_out_queue_wait_fails_instead_of_racing() {
    // The two timeout tests share the global MUTATION_WAIT_TIMEOUT_SECS
    // override, so they must not run concurrently.
    let _timeout_lock = TEST_TIMEOUT_LOCK.lock().await;
    let _timeout_override = TimeoutOverrideGuard::acquire();
    let key = format!("test-timeout:{}", std::process::id());
    let (release_first, wait_for_release) = oneshot::channel();
    let (first_started, wait_for_first) = oneshot::channel();
    let first_key = key.clone();
    let first = tokio::spawn(async move {
        enqueue_mutation(first_key, async move {
            let _ = first_started.send(());
            let _ = wait_for_release.await;
            Ok(())
        })
        .await
    });

    wait_for_first.await.unwrap();

    let order = Arc::new(Mutex::new(Vec::new()));
    let second_order = order.clone();
    let second = tokio::spawn(async move {
        enqueue_mutation(key, async move {
            second_order.lock().unwrap().push(2);
            Ok(())
        })
        .await
    });

    // Wait past the 1s queue-wait timeout: the second mutation refuses
    // to run concurrently, but its queue entry stays chained on the
    // (bounded) first mutation, so it must not complete yet either.
    tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
    assert!(!second.is_finished());
    assert_eq!(*order.lock().unwrap(), Vec::<i32>::new());

    // Once the first mutation finishes, the second runs its own
    // operation: serial-safe by then, and it honors the user's latest
    // intent instead of dropping it.
    let _ = release_first.send(());
    first.await.unwrap().unwrap();
    second.await.unwrap().unwrap();
    assert_eq!(*order.lock().unwrap(), [2]);
}

#[tokio::test]
async fn timed_out_waiter_keeps_successors_serialized_behind_the_predecessor() {
    let _timeout_lock = TEST_TIMEOUT_LOCK.lock().await;
    let _timeout_override = TimeoutOverrideGuard::acquire();
    let key = format!("test-restore:{}", std::process::id());
    let (release_first, wait_for_release) = oneshot::channel();
    let (first_started, wait_for_first) = oneshot::channel();
    let first_key = key.clone();
    let first = tokio::spawn(async move {
        enqueue_mutation(first_key, async move {
            let _ = first_started.send(());
            let _ = wait_for_release.await;
            Ok(())
        })
        .await
    });

    wait_for_first.await.unwrap();

    // B queues behind A; C queues behind B.
    let second_key = key.clone();
    let second =
        tokio::spawn(async move { enqueue_mutation(second_key, async move { Ok(()) }).await });
    let third_key = key.clone();
    let order = Arc::new(Mutex::new(Vec::new()));
    let third_order = order.clone();
    let third = tokio::spawn(async move {
        enqueue_mutation(third_key, async move {
            third_order.lock().unwrap().push(3);
            Ok(())
        })
        .await
    });

    // After B's wait times out, neither B nor C may complete: B stays
    // chained on the still-running A, and C stays chained on B. Letting
    // B complete would release C to run concurrently with A (both
    // server-side read-modify-writes racing each other).
    tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
    assert!(!second.is_finished());
    assert!(!third.is_finished());
    assert_eq!(*order.lock().unwrap(), Vec::<i32>::new());

    // Once A finishes, B (then C) runs their own operations in queue
    // order — serial-safe, never concurrent with A.
    let _ = release_first.send(());
    first.await.unwrap().unwrap();
    second.await.unwrap().unwrap();
    third.await.unwrap().unwrap();
    assert_eq!(*order.lock().unwrap(), [3]);
}

#[tokio::test]
async fn account_runtime_cleanup_keeps_inflight_mutations_serialized() {
    let (release_me, wait_me) = oneshot::channel();
    let (started_me, wait_started_me) = oneshot::channel();
    let my_key = "muted:@me:example.org:!room:example.org".to_string();
    let my_task = tokio::spawn({
        let key = my_key.clone();
        async move {
            enqueue_mutation(key, async move {
                let _ = started_me.send(());
                let _ = wait_me.await;
                Ok(())
            })
            .await
        }
    });
    wait_started_me.await.unwrap();

    // Account cleanup (logout/removal) must NOT drop the in-flight tail:
    // after a same-account relogin, a new operation on the same key must
    // still serialize behind the running one — removing the tail would
    // let both run concurrently as server-side read-modify-writes.
    clear_account_runtime_state("@me:example.org").await;

    let order = Arc::new(Mutex::new(Vec::new()));
    let second_order = order.clone();
    let second = tokio::spawn({
        let key = my_key.clone();
        async move {
            enqueue_mutation(key, async move {
                second_order.lock().unwrap().push(2);
                Ok(())
            })
            .await
        }
    });

    // The successor must not run while the in-flight operation is still
    // pending.
    tokio::task::yield_now().await;
    assert_eq!(*order.lock().unwrap(), Vec::<i32>::new());

    let _ = release_me.send(());
    my_task.await.unwrap().unwrap();
    second.await.unwrap().unwrap();
    assert_eq!(*order.lock().unwrap(), [2]);
}

#[tokio::test]
async fn overlong_queue_chains_are_rejected() {
    let key = format!("test-depth:{}", std::process::id());
    let (release_first, wait_for_release) = oneshot::channel();
    let (first_started, wait_for_first) = oneshot::channel();
    let first_key = key.clone();
    let first = tokio::spawn(async move {
        enqueue_mutation(first_key, async move {
            let _ = first_started.send(());
            let _ = wait_for_release.await;
            Ok(())
        })
        .await
    });

    wait_for_first.await.unwrap();

    // Fill the queue up to the depth limit (1 running + 2 queued).
    let second_key = key.clone();
    let second =
        tokio::spawn(async move { enqueue_mutation(second_key, async move { Ok(()) }).await });
    let third_key = key.clone();
    let third =
        tokio::spawn(async move { enqueue_mutation(third_key, async move { Ok(()) }).await });

    // Wait until both successors have actually chained (tail depth 3).
    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        loop {
            let depth = MUTATION_TAILS
                .lock()
                .map(|tails| tails.get(&key).map_or(0, |tail| tail.depth))
                .unwrap_or(0);
            if depth >= 3 {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("successors should chain onto the running mutation");

    // A fourth operation for the same key is rejected outright instead
    // of extending the chain: every chained operation holds a share of
    // the SYNC_LIFECYCLE read lease, so an unbounded chain would stall
    // logout/account switch behind a backlog.
    let fourth_key = key.clone();
    let fourth =
        tokio::spawn(async move { enqueue_mutation(fourth_key, async move { Ok(()) }).await });
    assert_eq!(
        fourth.await.unwrap().unwrap_err(),
        MUTATION_QUEUE_FULL_MESSAGE.to_string()
    );

    // The queue still drains in order once the running mutation
    // finishes; the rejected fourth operation never ran.
    let _ = release_first.send(());
    first.await.unwrap().unwrap();
    second.await.unwrap().unwrap();
    third.await.unwrap().unwrap();
}

#[tokio::test]
async fn overlong_operation_is_dropped_to_release_the_queue() {
    // Shares the global-timeout override discipline with the other
    // timeout tests (TEST_TIMEOUT_LOCK), so they never run concurrently.
    let _timeout_lock = TEST_TIMEOUT_LOCK.lock().await;
    let _execution_timeout_override = ExecutionTimeoutOverrideGuard::acquire();
    let key = format!("test-exec-timeout:{}", std::process::id());
    let (started, wait_started) = oneshot::channel();
    let first_key = key.clone();
    let first = tokio::spawn(async move {
        enqueue_mutation(first_key, async move {
            let _ = started.send(());
            // Never completes on its own: only the tail's total execution
            // bound can end this operation.
            std::future::pending::<()>().await;
            Ok(())
        })
        .await
    });
    wait_started.await.unwrap();

    // The operation outlives the 1s execution bound: the tail drops it,
    // completes with an error, and frees the queue entry — a caller that
    // is still around gets the failure instead of hanging forever.
    let result = tokio::time::timeout(std::time::Duration::from_secs(10), first)
        .await
        .expect("tail should complete once the execution bound expires")
        .unwrap();
    assert_eq!(result, Err("操作超时，请重试。".to_string()));

    // The cleanup hook removes the queue entry (driven by the spawned
    // tail, so poll briefly for it).
    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        loop {
            let removed = MUTATION_TAILS
                .lock()
                .map(|tails| !tails.contains_key(&key))
                .unwrap_or(false);
            if removed {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("dropped operation should free its queue entry");

    // A successor enqueued afterwards runs normally: the queue is not
    // stuck behind the dropped operation.
    let order = Arc::new(Mutex::new(Vec::new()));
    let second_order = order.clone();
    let second = tokio::spawn(async move {
        enqueue_mutation(key, async move {
            second_order.lock().unwrap().push(2);
            Ok(())
        })
        .await
    });
    second.await.unwrap().unwrap();
    assert_eq!(*order.lock().unwrap(), [2]);
}

#[test]
fn marked_unread_override_expires_when_sync_advances() {
    let local = MarkedUnreadOverride {
        baseline: false,
        desired: true,
        created_at: std::time::Instant::now(),
    };
    assert_eq!(resolve_marked_unread(false, Some(local)), (true, false));
    assert_eq!(resolve_marked_unread(true, Some(local)), (true, true));

    let local = MarkedUnreadOverride {
        baseline: true,
        desired: false,
        created_at: std::time::Instant::now(),
    };
    assert_eq!(resolve_marked_unread(true, Some(local)), (false, false));
    // synced=false with a fresh clear-in-flight override: the store can
    // lag the clear (the pending `true` echo of the cleared flag has
    // not landed — or a forced-baseline install where the flag never
    // synced locally). Keeping the override effective (showing read)
    // prevents the pending `true` echo from briefly resurrecting the
    // marker; the reconcile at the `false` echo or the TTL expiry drops
    // it. A genuinely cleared flag displays read either way.
    assert_eq!(resolve_marked_unread(false, Some(local)), (false, false));
}

#[test]
fn marked_unread_event_reconciles_an_aba_override() {
    let key = "@me:example.org:!room:example.org";
    let mut overrides = HashMap::from([(
        key.to_owned(),
        MarkedUnreadOverride {
            baseline: false,
            desired: true,
            created_at: std::time::Instant::now(),
        },
    )]);

    // A sync event is newer than the confirmed local write even when its
    // final boolean coalesces back to the same pre-write value: the
    // synced `true` no longer matches the baseline snapshot `false`.
    reconcile_marked_unread_override(&mut overrides, key, true);

    assert!(!overrides.contains_key(key));
}

#[test]
fn clear_in_flight_override_survives_the_pending_true_echo() {
    let key = "@me:example.org:!room:example.org";
    let mut overrides = HashMap::from([(
        key.to_owned(),
        MarkedUnreadOverride {
            baseline: true,
            desired: false,
            created_at: std::time::Instant::now(),
        },
    )]);

    // A clear was issued while the store lagged; the pending `true` echo
    // matches the override's baseline, so the override must keep
    // suppressing the marker (no unread flicker) until the `false` echo.
    reconcile_marked_unread_override(&mut overrides, key, true);
    assert!(overrides.contains_key(key));

    reconcile_marked_unread_override(&mut overrides, key, false);
    assert!(!overrides.contains_key(key));
}

#[test]
fn ignored_user_override_expires_when_sync_advances() {
    let local = IgnoredUserOverride {
        baseline: false,
        desired: true,
        event_seen: None,
    };
    assert_eq!(resolve_ignored_user(false, Some(local)), (true, false));
    assert_eq!(resolve_ignored_user(true, Some(local)), (true, true));

    let local = IgnoredUserOverride {
        baseline: true,
        desired: false,
        event_seen: None,
    };
    assert_eq!(resolve_ignored_user(true, Some(local)), (false, false));
    assert_eq!(resolve_ignored_user(false, Some(local)), (false, true));

    assert_eq!(resolve_ignored_user(true, None), (true, false));
}

#[test]
fn ignored_user_override_heals_before_another_device_unignores() {
    // 1. Local ignore: the store has not caught up; the override hides.
    let local = IgnoredUserOverride {
        baseline: false,
        desired: true,
        event_seen: None,
    };
    assert_eq!(resolve_ignored_user(false, Some(local)), (true, false));
    // 2. Echo lands: the override is stale and must be dropped. This
    //    consult has to happen even while the write-through list still
    //    hides the sender (see room_to_chat_room), or step 3 goes wrong.
    assert_eq!(resolve_ignored_user(true, Some(local)), (true, true));
    // 3. Another device un-ignores: no override remains; the store wins.
    assert_eq!(resolve_ignored_user(false, None), (false, false));
}

#[test]
fn account_data_event_reconciles_ignored_user_overrides() {
    let prefix = "@me:example.org:";
    let mut echoed = IgnoredUserListEventContent::default();
    echoed.ignored_users.insert(
        matrix_sdk::ruma::OwnedUserId::try_from("@target:example.org").unwrap(),
        IgnoredUser::default(),
    );
    let mut overrides = HashMap::from([
        // Target present in the authoritative content: stale either way.
        (
            format!("{prefix}@target:example.org"),
            IgnoredUserOverride {
                baseline: false,
                desired: true,
                event_seen: None,
            },
        ),
        // Target absent and desired=false: the server confirmed the
        // un-ignore, stale.
        (
            format!("{prefix}@unignored:example.org"),
            IgnoredUserOverride {
                baseline: true,
                desired: false,
                event_seen: None,
            },
        ),
        // Target absent and desired=true: may still await its echo; the
        // override survives this round (TTL handles the ABA case later).
        (
            format!("{prefix}@pending:example.org"),
            IgnoredUserOverride {
                baseline: false,
                desired: true,
                event_seen: None,
            },
        ),
        // Overrides of other accounts are never touched.
        (
            "@someoneelse:example.org:@target:example.org".to_owned(),
            IgnoredUserOverride {
                baseline: false,
                desired: true,
                event_seen: None,
            },
        ),
    ]);

    reconcile_ignored_user_overrides_inner(prefix, &echoed, &mut overrides);

    assert!(!overrides.contains_key(&format!("{prefix}@target:example.org")));
    assert!(!overrides.contains_key(&format!("{prefix}@unignored:example.org")));
    assert!(overrides.contains_key(&format!("{prefix}@pending:example.org")));
    assert!(overrides.contains_key("@someoneelse:example.org:@target:example.org"));
}

#[test]
fn account_data_event_starts_ttl_only_once() {
    let prefix = "@me:example.org:";
    let key = format!("{prefix}@pending:example.org");
    // Target absent and desired=true: survives the event, and the TTL
    // clock starts on the FIRST such event. Global account data arrives
    // on every sync response even when unchanged; refreshing the clock
    // each time would keep the override alive forever in the ABA case.
    let mut overrides = HashMap::from([(
        key.clone(),
        IgnoredUserOverride {
            baseline: false,
            desired: true,
            event_seen: None,
        },
    )]);
    let empty = IgnoredUserListEventContent::default();

    reconcile_ignored_user_overrides_inner(prefix, &empty, &mut overrides);
    let first_seen = overrides.get(&key).unwrap().event_seen;
    assert!(first_seen.is_some());

    // A second unchanged event must NOT reset the clock.
    reconcile_ignored_user_overrides_inner(prefix, &empty, &mut overrides);
    let second_seen = overrides.get(&key).unwrap().event_seen;
    assert_eq!(first_seen.unwrap(), second_seen.unwrap());
}

#[test]
fn store_fallback_applies_pending_local_ignore_overrides() {
    let prefix = "@me:example.org:";
    let ignored = matrix_sdk::ruma::OwnedUserId::try_from("@ignored:example.org").unwrap();
    let unignored = matrix_sdk::ruma::OwnedUserId::try_from("@unignored:example.org").unwrap();
    let mut content = IgnoredUserListEventContent::default();
    content
        .ignored_users
        .insert(unignored.clone(), IgnoredUser::new());
    let mut overrides = HashMap::from([
        (
            format!("{prefix}{ignored}"),
            IgnoredUserOverride {
                baseline: false,
                desired: true,
                event_seen: None,
            },
        ),
        (
            format!("{prefix}{unignored}"),
            IgnoredUserOverride {
                baseline: true,
                desired: false,
                event_seen: None,
            },
        ),
    ]);

    merge_ignored_user_overrides(prefix, &mut content, &mut overrides);

    assert!(content.ignored_users.contains_key(&ignored));
    assert!(!content.ignored_users.contains_key(&unignored));
    assert_eq!(overrides.len(), 2);
}
