//! Mutation implementation.

use super::*;

// Used by the mutation-queue tests; production callers go through
// `run_bounded_mutation` / `run_bounded_mutation_undroppable`, which pick
// the drop behavior explicitly.
#[cfg(test)]
pub(super) async fn enqueue_mutation<F, T>(key: String, operation: F) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    enqueue_mutation_inner(key, operation, true).await
}

/// `drop_on_execution_timeout`: see MUTATION_EXECUTION_TIMEOUT_SECS.
/// Operations whose server-side effect is neither idempotent nor verifiable
/// on retry (currently only `create_dm`) pass false: dropping their tail
/// mid-flight can orphan server-side state the client never learns about,
/// so they bound their duration internally instead of being dropped.
pub(super) async fn enqueue_mutation_inner<F, T>(
    key: String,
    operation: F,
    drop_on_execution_timeout: bool,
) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    let id = NEXT_MUTATION_ID.fetch_add(1, Ordering::Relaxed);
    let log_key = key.clone();
    let future = {
        let mut tails = MUTATION_TAILS
            .lock()
            .map_err(|_| api_err("mutation", "操作队列不可用，请重试。".to_string()))?;
        let previous = tails
            .get(&key)
            .map(|tail| (tail.future.clone(), tail.depth));
        // Bound the chain length (see MUTATION_QUEUE_MAX_DEPTH): each
        // chained operation holds a share of the SYNC_LIFECYCLE read lease
        // from enqueue until completion, so an unbounded chain would let a
        // bad server + user retries stall logout/account switch for minutes.
        // Reject the excess instead of extending the chain past
        // 1 running + 2 queued.
        if previous
            .as_ref()
            .is_some_and(|(_, depth)| *depth >= MUTATION_QUEUE_MAX_DEPTH)
        {
            return Err(api_err("mutation", MUTATION_QUEUE_FULL_MESSAGE.to_string()));
        }
        let depth = previous.as_ref().map_or(1, |(_, depth)| depth + 1);
        let previous = previous.map(|(future, _)| future);
        let future = std::panic::AssertUnwindSafe(async move {
            if let Some(previous) = previous {
                // The SDK's HTTP timeout (see bounded_request_config) bounds
                // a single request at ~93s (3 attempts with backoff), but
                // several operations can still back up behind a slow one.
                // State mutations are server-side read-modify-writes:
                // running two
                // concurrently would make one overwrite the other (lost
                // pins, resurrected ignored users).
                let wait_timeout = std::time::Duration::from_secs(
                    MUTATION_WAIT_TIMEOUT_SECS.load(Ordering::Relaxed),
                );
                if tokio::time::timeout(wait_timeout, previous.clone())
                    .await
                    .is_err()
                {
                    // The predecessor outlived the queue wait. Never run
                    // concurrently with it (state mutations are server-side
                    // read-modify-writes), and keep this entry chained so
                    // successors still serialize behind the chain — but once
                    // the predecessor finishes (it is itself bounded by the
                    // HTTP timeout), running our own operation is serial-safe
                    // and honors the user's latest intent. Only when the
                    // predecessor still has not finished do we give up: wait
                    // for it (bounded by the HTTP timeout) so this entry
                    // completes only after the predecessor, keeping
                    // successors chained on it serialized — completing early
                    // would release them to run concurrently with the
                    // in-flight predecessor.
                    app_log(
                        "warn",
                        "mutation",
                        format!(
                            "Mutation queue wait timed out for key {log_key}; waiting for the predecessor to finish."
                        ),
                    );
                    if tokio::time::timeout(std::time::Duration::from_secs(120), previous.clone())
                        .await
                        .is_err()
                    {
                        app_log(
                            "warn",
                            "mutation",
                            format!(
                                "Predecessor for key {log_key} still running; waiting for it to finish before running this operation."
                            ),
                        );
                        // Wait for the predecessor before running our own
                        // operation: this entry must not execute while the
                        // predecessor is still running, or successors chained
                        // on it would run concurrently with it (both
                        // server-side read-modify-writes). The bound is the
                        // predecessor's own completion (its requests are
                        // individually bounded by the HTTP timeout; a chained
                        // queue can accumulate across several predecessors).
                        // Dropping the operation here would silently lose the
                        // user's latest intent AND contradict the caller-side
                        // "操作超时，仍在后台执行" wording (the operation
                        // never ran) — so run it once the predecessor is
                        // done, exactly like the 120s branch.
                        let _ = previous.await;
                    }
                }
            }
            // The execution itself is hard-bounded: the caller-side 90s of
            // `run_bounded_mutation` does not constrain this background tail,
            // so without a total bound a multi-request operation (N rooms x
            // the ~93s HTTP budget) could pin the queue — and its share of
            // the SYNC_LIFECYCLE read lease — for many minutes. On expiry the
            // operation future is dropped: the lease is released, the tail
            // completes with an error, and the cleanup hook frees the queue
            // entry so successors are not stuck behind a dead operation.
            // Non-idempotent operations opt out: dropping their tail
            // mid-flight can orphan server-side state the client never
            // learns about (a created DM room whose response was lost —
            // the retry's reuse scan cannot see it until sync delivers it),
            // so they bound their duration internally instead.
            if !drop_on_execution_timeout {
                return operation.await;
            }
            let execution_timeout = std::time::Duration::from_secs(
                MUTATION_EXECUTION_TIMEOUT_SECS.load(Ordering::Relaxed),
            );
            match tokio::time::timeout(execution_timeout, operation).await {
                Ok(result) => result,
                Err(_) => {
                    app_log(
                        "warn",
                        "mutation",
                        format!(
                            "Mutation for key {log_key} exceeded the total execution bound; dropping it to release the queue."
                        ),
                    );
                    Err("操作超时，请重试。".to_string())
                }
            }
        })
        // A panicking predecessor (or operation) would otherwise unwind
        // through this future, skipping the tail cleanup below and leaving a
        // stale queue entry that panics every successor. Catch it and turn
        // it into a regular error so cleanup always runs.
        .catch_unwind()
        .map(|result| result.unwrap_or_else(|_| Err(api_err("mutation", "操作执行异常，请重试。".to_string()))))
        .boxed()
        .shared();
        // Chain on a unit-typed projection so operations with different
        // payload types can share one queue per key. The cleanup is part of
        // the tail itself: it runs when the operation finishes regardless of
        // whether the caller is still awaiting (a caller that times out in
        // `run_bounded_mutation` drops its future — without the spawn below
        // the shared future would freeze un-polled, and without this cleanup
        // the tail would linger forever).
        let cleanup_id = id;
        let cleanup_key = key.clone();
        let tail_future = future
            .clone()
            .map(move |result| {
                if let Ok(mut tails) = MUTATION_TAILS.lock() {
                    if tails
                        .get(&cleanup_key)
                        .is_some_and(|tail| tail.id == cleanup_id)
                    {
                        tails.remove(&cleanup_key);
                    }
                }
                result.map(|_| ())
            })
            .boxed()
            .shared();
        tails.insert(
            key.clone(),
            MutationTail {
                id,
                depth,
                future: tail_future.clone(),
            },
        );
        // Drive the shared future in the background: `Shared` only polls its
        // inner future while at least one clone is being awaited, so a
        // caller that drops its clone (timeout) would otherwise freeze the
        // operation mid-flight — and a later successor would revive it,
        // double-applying a non-idempotent toggle (pin/unpin). Drive the
        // tail future (not the raw one) so the cleanup hook always runs.
        tokio::spawn(tail_future.clone());
        future
    };

    future.await
}

/// Enqueue a mutation with a total bound on the caller's side. The queue
/// itself stays correct after a timeout (the tail keeps running to
/// completion under its share of the client lease), but the caller must not
/// wait unboundedly: the queue wait alone can reach 30s + 120s, plus the
/// operation's own HTTP attempts.
pub(super) async fn run_bounded_mutation<F, T>(
    key: String,
    lifecycle_protection: LifecycleProtection,
    operation: F,
) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    run_bounded_mutation_inner(key, lifecycle_protection, operation, true).await
}

/// Variant of [`run_bounded_mutation`] for operations whose server-side
/// effect is neither idempotent nor verifiable on retry (currently only
/// `create_dm`): the tail must NOT be dropped on the execution timeout —
/// a dropped create can orphan a room whose response never arrived, and
/// the retry's reuse scan cannot see it until sync delivers it (a duplicate
/// DM). The operation must bound its own duration instead (create_dm caps
/// its reuse scan; each request is bounded by bounded_request_config).
pub(super) async fn run_bounded_mutation_undroppable<F, T>(
    key: String,
    lifecycle_protection: LifecycleProtection,
    operation: F,
) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    run_bounded_mutation_inner(key, lifecycle_protection, operation, false).await
}

pub(super) async fn run_bounded_mutation_inner<F, T>(
    key: String,
    lifecycle_protection: LifecycleProtection,
    operation: F,
    drop_on_execution_timeout: bool,
) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    // Move a share of the caller's lifecycle lease into the queued operation
    // itself. When the caller times out, the spawned tail can keep using its
    // Client/Room safely while logout or account removal waits for this share.
    let protected_operation = async move {
        let _lifecycle_protection = lifecycle_protection;
        operation.await
    };
    tokio::time::timeout(
        std::time::Duration::from_secs(90),
        enqueue_mutation_inner(key, protected_operation, drop_on_execution_timeout),
    )
    .await
    .map_err(|_| api_err("mutation", MUTATION_TIMEOUT_MESSAGE.to_string()))?
}

/// Total bound for a non-queued P0 write. These hold the client lease
/// (blocking logout/account switch) for their whole duration, and each
/// request inside is individually bounded by `bounded_request_config` — but
/// multi-request operations (name+topic, upload+state, verify+invite)
/// could otherwise hold the lease for minutes.
pub(super) async fn run_bounded<F, T>(operation: F) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    tokio::time::timeout(std::time::Duration::from_secs(90), operation)
        .await
        .map_err(|_| api_err("mutation", "操作超时，请重试。".to_string()))?
}
