//! Sync traditional implementation.

use super::*;

pub(super) async fn sync_once() -> Result<(), String> {
    let client = get_client().await.ok_or_else(|| {
        app_log("error", "sync", "sync_once: no client created".to_string());
        "No client created.".to_string()
    })?;
    if matches!(get_connection_status(), ConnectionStatus::SessionExpired) {
        return Err("登录已失效，请重新登录".to_string());
    }
    let user_id = client.user_id().map(|u| u.to_string()).unwrap_or_default();
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    if !sync_generation_is_active(generation, &user_id).await {
        return Err(api_err(
            "sync",
            "Active account changed before syncing.".to_string(),
        ));
    }
    let hs = client.homeserver().to_string();
    app_log(
        "info",
        "sync",
        format!(
            "sync_once: starting for user {} (homeserver: {hs})",
            user_id
        ),
    );
    set_connection_status_for_generation(generation, ConnectionStatus::Connecting);

    if let Err(error) = client.event_cache().subscribe() {
        set_connection_status_for_generation(generation, ConnectionStatus::Disconnected);
        return Err(api_err(
            "sync",
            format!("Failed to subscribe to the event cache: {error}"),
        ));
    }

    let mut diagnostics = RequestDiagnostics::new(client.homeserver());
    diagnostics.stage = "initial_sync";
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        SYNC_EVENT_GENERATION.scope(
            generation,
            client.sync_once(matrix_sdk::config::SyncSettings::default()),
        ),
    )
    .await;

    if !sync_generation_is_active(generation, &user_id).await {
        return Err(api_err(
            "sync",
            "Active account changed while syncing.".to_string(),
        ));
    }

    match result {
        Ok(Ok(_)) => {
            app_log(
                "info",
                "sync",
                format!("sync_once: completed for user {}", user_id),
            );
            set_connection_status_for_generation(generation, ConnectionStatus::Connected);
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
            Ok(())
        }
        Ok(Err(e)) => {
            diagnostics.status = e
                .as_client_api_error()
                .map(|error| error.status_code.as_u16());
            let msg = format!(
                "sync_once: failed for user {}: {}",
                user_id,
                diagnostics.failure(&e),
            );
            app_log("error", "sync", msg.clone());
            report_session_error(&e);
            set_connection_status_for_generation(generation, ConnectionStatus::Disconnected);
            Err(format!("同步失败: {e}"))
        }
        Err(_) => {
            let msg = format!(
                "sync_once: timed out after 10s for user {} (homeserver: {hs}): {}",
                user_id,
                diagnostics.context(),
            );
            app_log("error", "sync", msg.clone());
            set_connection_status_for_generation(generation, ConnectionStatus::Disconnected);
            Err("同步超时（10 秒），请检查网络连接与服务器地址。".to_string())
        }
    }
}

pub(super) async fn start_sync() -> Result<(), String> {
    // A fresh, explicit start (app launch, manual reconnect) resets any
    // earlier degrade decision so a recovered server can use Sliding Sync
    // again. In-session upgrades from the traditional loop do not clear it.
    {
        let mut degraded = SYNC_DEGRADED_ACCOUNTS.write().await;
        degraded.clear();
    }
    start_sync_internal(false).await
}

/// Shared implementation behind [`start_sync`]. `force_traditional` is used
/// by the sync loops themselves when they decide to switch modes at runtime:
/// a Sliding Sync loop that fails repeatedly degrades to the traditional
/// loop, and the traditional loop re-probes for MSC3575 support and upgrades
/// back — the probe (and the /versions request it makes) is skipped when
/// forcing the traditional mode to avoid a pointless round-trip.
pub(super) fn start_sync_internal(
    force_traditional: bool,
) -> std::pin::Pin<Box<dyn futures_util::Future<Output = Result<(), String>> + Send + 'static>> {
    Box::pin(async move {
        let client = get_client().await.ok_or_else(|| {
            app_log("error", "sync", "start_sync: no client created".to_string());
            "No client created.".to_string()
        })?;
        if matches!(get_connection_status(), ConnectionStatus::SessionExpired) {
            return Err("登录已失效，请重新登录".to_string());
        }
        let user_id = client.user_id().map(|u| u.to_string()).unwrap_or_default();
        let hs = client.homeserver().to_string();
        app_log(
            "info",
            "sync",
            format!(
                "start_sync: beginning for user {} (homeserver: {hs})",
                user_id
            ),
        );

        let generation = stop_sync_task(None, true).await;
        if !sync_generation_is_active(generation, &user_id).await {
            return Err(api_err(
                "sync",
                "Active account changed while starting sync.".to_string(),
            ));
        }
        if let Err(error) = client.event_cache().subscribe() {
            set_connection_status_for_generation(generation, ConnectionStatus::Disconnected);
            return Err(api_err(
                "sync",
                format!("Failed to subscribe to the event cache: {error}"),
            ));
        }

        // Try Sliding Sync first
        let pending = if force_traditional {
            Err("Traditional sync mode forced by the running sync loop".to_string())
        } else {
            try_start_sliding_sync(client.clone(), generation, user_id.clone()).await
        };
        let pending = match pending {
            Ok(pending) => {
                app_log(
                    "info",
                    "sync",
                    format!("start_sync: Sliding Sync started for user {}", user_id),
                );
                pending
            }
            Err(e) => {
                app_log(
                    "warn",
                    "sync",
                    format!(
                    "start_sync: Sliding Sync failed ({}), falling back to traditional sync loop",
                    e
                ),
                );
                // Fallback: traditional sync loop
                let loop_user_id = user_id.clone();
                // Spawn with a bare `Client` (Deref'd out of the lease): the
                // lease holds the SYNC_LIFECYCLE read lock, and this loop can
                // outlive start_sync_internal — holding the guard here would
                // deadlock every account switch/logout/removal (they take the
                // write lock) until the loop exits.
                let loop_client = client.clone();
                let (start, start_rx) = tokio::sync::oneshot::channel();
                let handle = tokio::spawn(async move {
                    if start_rx.await.is_err() {
                        return;
                    }
                    SYNC_EVENT_GENERATION
                        .scope(generation, async move {
                            app_log(
                                "info",
                                "sync",
                                format!("Traditional sync loop started for user {}", loop_user_id),
                            );
                            // Re-probe for MSC3575 after a few successful syncs.
                            // The initial probe may have failed because /versions
                            // was unreachable (server up but network flaky at
                            // startup); upgrading back to Sliding Sync restores
                            // receipt push and the room subscription extension.
                            let mut successful_syncs: u32 = 0;
                            let mut consecutive_errors: u32 = 0;
                            loop {
                                if matches!(
                                    get_connection_status(),
                                    ConnectionStatus::SessionExpired
                                ) {
                                    clear_published_sync(generation).await;
                                    break;
                                }
                                if !sync_generation_is_active(generation, &loop_user_id).await {
                                    break;
                                }
                                // `Updating` marks an actual catch-up (the
                                // loop's first sync, or the first one after an
                                // error). A steady-state long-poll wait is a
                                // healthy connection, not "syncing": setting it
                                // every iteration kept the UI on 同步中… for
                                // the whole 30s poll window while messages
                                // kept arriving.
                                if successful_syncs == 0 {
                                    set_connection_status_for_generation(
                                        generation,
                                        ConnectionStatus::Updating,
                                    );
                                }
                                let mut diagnostics =
                                    RequestDiagnostics::new(loop_client.homeserver());
                                diagnostics.stage = "traditional_sync";
                                match loop_client
                                    .sync_once(matrix_sdk::config::SyncSettings::default())
                                    .await
                                {
                                    Ok(_) => {
                                        if !sync_generation_is_active(generation, &loop_user_id)
                                            .await
                                        {
                                            break;
                                        }
                                        app_log(
                                            "info",
                                            "sync",
                                            "Traditional sync completed".to_string(),
                                        );
                                        set_connection_status_for_generation(
                                            generation,
                                            ConnectionStatus::Connected,
                                        );
                                        notify_sync_event_for_generation(
                                            generation,
                                            SyncEvent::SyncCompleted,
                                        );
                                        successful_syncs += 1;
                                        consecutive_errors = 0;
                                        // Only upgrade back to Sliding Sync when
                                        // this session never degraded away from it
                                        // (the probe was flaky at startup). After
                                        // an explicit degrade, re-probing would
                                        // ping-pong: fail 5x -> traditional ->
                                        // probe OK -> sliding -> fail 5x -> ...
                                        let degraded = SYNC_DEGRADED_ACCOUNTS
                                            .read()
                                            .await
                                            .contains(&loop_user_id);
                                        if successful_syncs >= 10
                                            && !degraded
                                            && !loop_client
                                                .available_sliding_sync_versions()
                                                .await
                                                .is_empty()
                                        {
                                            app_log(
                                                "info",
                                                "sync",
                                                "Sliding Sync support detected; upgrading loop"
                                                    .to_string(),
                                            );
                                            // Switch mode by restarting the whole
                                            // sync task (this task ends first, so
                                            // the restart is not self-aborting).
                                            // Fire-and-forget: the restarted task
                                            // stops this one via stop_sync_task.
                                            let _handle = tokio::spawn(async move {
                                                let _ = start_sync_internal(false).await;
                                            });
                                            break;
                                        }
                                    }
                                    Err(e) => {
                                        if !sync_generation_is_active(generation, &loop_user_id)
                                            .await
                                        {
                                            break;
                                        }
                                        diagnostics.status = e
                                            .as_client_api_error()
                                            .map(|error| error.status_code.as_u16());
                                        app_log(
                                            "error",
                                            "sync",
                                            format!(
                                                "Traditional sync error: attempt={} {}",
                                                consecutive_errors + 1,
                                                diagnostics.failure(&e),
                                            ),
                                        );
                                        if report_session_error_for_generation(generation, &e) {
                                            clear_published_sync(generation).await;
                                            break;
                                        }
                                        consecutive_errors += 1;
                                        successful_syncs = 0;
                                        set_connection_status_for_generation(
                                            generation,
                                            sync_retry_status(consecutive_errors),
                                        );
                                        interruptible_retry_sleep(
                                            generation,
                                            &loop_user_id,
                                            sync_retry_delay(consecutive_errors),
                                        )
                                        .await;
                                    }
                                }
                            }
                        })
                        .await;
                });
                PendingSyncTask { handle, start }
            }
        };

        if !sync_generation_is_active(generation, &user_id).await {
            pending.handle.abort();
            clear_published_sync(generation).await;
            return Err(api_err(
                "sync",
                "Active account changed while starting sync.".to_string(),
            ));
        }

        let mut current_task = SYNC_TASK.lock().await;
        if !sync_generation_is_active(generation, &user_id).await {
            pending.handle.abort();
            drop(current_task);
            clear_published_sync(generation).await;
            return Err(api_err(
                "sync",
                "Active account changed while starting sync.".to_string(),
            ));
        }
        if let Some(running) = current_task.take() {
            running.handle.abort();
        }
        *current_task = Some(SyncTask {
            user_id,
            generation,
            handle: pending.handle,
        });
        let _ = pending.start.send(());
        Ok(())
    })
}
