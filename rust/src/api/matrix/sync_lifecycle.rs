//! Sync lifecycle implementation.

use super::*;

pub(super) async fn stop_sync_task(user_id: Option<&str>, preserve_subscriptions: bool) -> u64 {
    let mut task = SYNC_TASK.lock().await;
    let should_stop = user_id.is_none()
        || task
            .as_ref()
            .is_some_and(|running| user_id.is_some_and(|id| running.user_id == id));
    let generation = if should_stop {
        advance_sync_generation()
    } else {
        SYNC_GENERATION.load(Ordering::SeqCst)
    };
    if should_stop {
        let running = task.take();
        // A same-account restart must retain mounted rooms registered before
        // start_sync. Account changes clear them so they cannot be replayed
        // into another account's Sliding Sync instance.
        let mut sub = ROOM_SUBSCRIPTION.lock().await;
        let graceful_stop = running.as_ref().and_then(|running| {
            (sub.active_generation == Some(running.generation))
                .then(|| sub.active.clone())
                .flatten()
        });
        let graceful_stop_requested = graceful_stop
            .as_ref()
            .is_some_and(|sliding_sync| sliding_sync.stop_sync().is_ok());
        sub.reset(preserve_subscriptions);
        drop(sub);
        if !preserve_subscriptions {
            let mut typing = TYPING_TASK.lock().await;
            if let Some(task) = typing.take() {
                task.handle.abort();
            }
        }
        if let Some(running) = running {
            if !graceful_stop_requested {
                running.handle.abort();
            }
            // Drop the task lock before awaiting the old loop: a hung SDK
            // task must not block start_sync (or logout/switch) forever.
            // The generation barrier already isolates the old loop's
            // callbacks, so waiting outside the lock stays safe.
            drop(task);
            // Sliding Sync deliberately finishes response processing in an
            // uncancellable SDK task. Waiting for the loop after stop_sync()
            // drains that work before an A -> B -> A account transition can
            // make its old handlers look current again. The timeout bounds
            // the wait for the pathological case where the SDK task never
            // exits (the SDK has no HTTP timeout); after it fires, the
            // generation barrier alone keeps the old loop inert.
            let user_id = running.user_id;
            let abort_handle = running.handle.abort_handle();
            if tokio::time::timeout(std::time::Duration::from_secs(10), running.handle)
                .await
                .is_err()
            {
                // The old loop did not exit in time (a hung SDK task with no
                // HTTP timeout). Abort it so it stops holding the old client
                // and connection; the generation barrier already keeps its
                // callbacks from surfacing to the UI.
                abort_handle.abort();
                app_log(
                    "warn",
                    "sync",
                    format!("Sync loop for user {user_id} did not exit in time; aborted."),
                );
            }
            app_log(
                "info",
                "sync",
                format!("Stopped sync loop for user {user_id}"),
            );
        }
    }
    generation
}

pub(super) async fn sync_generation_is_active(generation: u64, user_id: &str) -> bool {
    if SYNC_GENERATION.load(Ordering::SeqCst) != generation {
        return false;
    }
    let matches = ACTIVE_USER.read().await.as_deref() == Some(user_id);
    matches && SYNC_GENERATION.load(Ordering::SeqCst) == generation
}

/// Retry-delay sleep that aborts early once the sync generation is no longer
/// active. Without this, `stop_sync_task` (account switch, logout, restart)
/// would wait out the whole delay while the loop sits in this sleep, because
/// `stop_sync()` cannot interrupt a `sleep()`.
pub(super) async fn interruptible_retry_sleep(
    generation: u64,
    user_id: &str,
    duration: std::time::Duration,
) {
    let deadline = tokio::time::Instant::now() + duration;
    loop {
        if !sync_generation_is_active(generation, user_id).await {
            return;
        }
        let now = tokio::time::Instant::now();
        if now >= deadline {
            return;
        }
        let remaining = deadline - now;
        tokio::time::sleep(remaining.min(std::time::Duration::from_millis(100))).await;
    }
}

pub(super) async fn clear_published_sync(generation: u64) {
    let mut subscriptions = ROOM_SUBSCRIPTION.lock().await;
    subscriptions.clear_active_for_generation(generation);
}
