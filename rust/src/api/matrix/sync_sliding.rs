//! Sync sliding implementation.

use super::*;

/// Try to set up Sliding Sync with the SDK's built-in support.
pub(super) async fn try_start_sliding_sync(
    client: Client,
    generation: u64,
    user_id: String,
) -> Result<PendingSyncTask, String> {
    use futures_util::StreamExt;
    use matrix_sdk::ruma::events::StateEventType as RoomStateType;
    use matrix_sdk::sliding_sync::{SlidingSync, SlidingSyncList, SlidingSyncMode, Version};

    // Probe the server before committing to Sliding Sync. `build()` below is
    // purely local and `Version::Native` skips the version check, so without
    // this probe a server without MSC3575 (matrix.org, mozilla.org, …) would
    // fail on the first sync request and then retry forever in the rebuild
    // loop instead of falling back to the traditional sync loop. The probe
    // also returns empty when /versions is unreachable, in which case the
    // traditional loop is the safer choice anyway.
    if client.available_sliding_sync_versions().await.is_empty() {
        return Err("Homeserver does not advertise Sliding Sync (MSC3575) support".to_string());
    }

    async fn build_sliding_sync(client: &Client) -> Result<SlidingSync, String> {
        client
            .sliding_sync("main")
            .map_err(|e| format!("Failed to create Sliding Sync: {e}"))?
            .version(Version::Native)
            .with_all_extensions()
            .with_receipt_extension(receipt_extension_for_subscribed_rooms())
            .add_list(
                SlidingSyncList::builder("all_rooms")
                    .sync_mode(SlidingSyncMode::Growing {
                        batch_size: 50,
                        maximum_number_of_rooms_to_fetch: Some(500),
                    })
                    .required_state(vec![
                        (RoomStateType::RoomName, "".to_owned()),
                        (RoomStateType::RoomAvatar, "".to_owned()),
                        (RoomStateType::RoomCanonicalAlias, "".to_owned()),
                        // Keep normal member state lazy; knock approvals query
                        // the authoritative /members endpoint on demand.
                        (RoomStateType::RoomMember, "$LAZY".to_owned()),
                        (RoomStateType::RoomMember, "$ME".to_owned()),
                        (RoomStateType::RoomTopic, "".to_owned()),
                        // Space membership: without these, get_space_children and
                        // get_ungrouped_rooms see no parent/child relationships and
                        // every grouped room appears "ungrouped".
                        (RoomStateType::SpaceChild, "".to_owned()),
                        (RoomStateType::SpaceParent, "".to_owned()),
                        // Room type (m.room.create) so is_space() resolves reliably
                        // without a second round-trip.
                        (RoomStateType::RoomCreate, "".to_owned()),
                    ])
                    .timeline_limit(10u32),
            )
            .build()
            .await
            .map_err(|e| format!("Failed to build Sliding Sync: {e}"))
    }

    build_sliding_sync(&client).await?;

    // The loop waits until start_sync installs its handle in SYNC_TASK. This
    // makes every response-processing task reachable by account transitions.
    let (start, start_rx) = tokio::sync::oneshot::channel();
    let handle = tokio::spawn(async move {
        if start_rx.await.is_err() {
            return;
        }
        SYNC_EVENT_GENERATION
            .scope(generation, async move {
                app_log("info", "sync", "Sliding Sync loop started".to_string());
                let mut consecutive_failures: u32 = 0;
                'rebuild: loop {
                    if matches!(get_connection_status(), ConnectionStatus::SessionExpired) {
                        clear_published_sync(generation).await;
                        break;
                    }
                    if !sync_generation_is_active(generation, &user_id).await {
                        break;
                    }
                    let sliding_sync = match build_sliding_sync(&client).await {
                        Ok(sync) => sync,
                        Err(e) => {
                            if !sync_generation_is_active(generation, &user_id).await {
                                break;
                            }
                            app_log("error", "sync", format!("Sliding Sync rebuild failed: {e}"));
                            consecutive_failures += 1;
                            set_connection_status_for_generation(
                                generation,
                                sync_retry_status(consecutive_failures),
                            );
                            if consecutive_failures >= DEGRADE_AFTER_FAILURES {
                                degrade_to_traditional_sync(generation, &user_id).await;
                                break;
                            }
                            interruptible_retry_sleep(
                                generation,
                                &user_id,
                                sync_retry_delay(consecutive_failures),
                            )
                            .await;
                            continue;
                        }
                    };
                    if !sync_generation_is_active(generation, &user_id).await {
                        break;
                    }
                    // Atomically publish the live instance and replay mounted rooms'
                    // subscriptions onto it. The old instance (and its sticky
                    // subscriptions) is gone after a reconnect, so without replay the
                    // mounted rooms would stop receiving receipt deltas until re-entry.
                    // subscribe_to_rooms is synchronous, so we do it
                    // under the same lock to keep desired/active consistent.
                    let mut sub_state = ROOM_SUBSCRIPTION.lock().await;
                    if !sync_generation_is_active(generation, &user_id).await {
                        drop(sub_state);
                        break;
                    }
                    sub_state.active = Some(sliding_sync.clone());
                    sub_state.active_generation = Some(generation);
                    let owned = desired_room_ids(&sub_state.desired);
                    let refs = owned.iter().map(|id| id.as_ref()).collect::<Vec<_>>();
                    sliding_sync.set_room_subscriptions(
                        &refs,
                        Some(live_room_subscription()),
                        false,
                    );
                    drop(sub_state);

                    let stream = sliding_sync.sync();
                    futures_util::pin_mut!(stream);
                    let mut received_update = false;
                    let mut diagnostics = RequestDiagnostics::new(client.homeserver());
                    diagnostics.stage = "sliding_sync";
                    while let Some(update) = stream.next().await {
                        if matches!(get_connection_status(), ConnectionStatus::SessionExpired) {
                            clear_published_sync(generation).await;
                            return;
                        }
                        if !sync_generation_is_active(generation, &user_id).await {
                            clear_published_sync(generation).await;
                            return;
                        }
                        match update {
                            Ok(summary) => {
                                received_update = true;
                                app_log(
                                    "info",
                                    "sync",
                                    format!("Sliding Sync update: {} rooms", summary.rooms.len()),
                                );
                                set_connection_status_for_generation(
                                    generation,
                                    ConnectionStatus::Connected,
                                );
                                notify_sync_event_for_generation(
                                    generation,
                                    SyncEvent::SyncCompleted,
                                );
                                consecutive_failures = 0;
                                diagnostics = RequestDiagnostics::new(client.homeserver());
                                diagnostics.stage = "sliding_sync";
                            }
                            Err(e) => {
                                diagnostics.status = e
                                    .as_client_api_error()
                                    .map(|error| error.status_code.as_u16());
                                app_log(
                                    "error",
                                    "sync",
                                    format!(
                                        "Sliding Sync error: attempt={} {}",
                                        consecutive_failures + 1,
                                        diagnostics.failure(&e),
                                    ),
                                );
                                if report_session_error_for_generation(generation, &e) {
                                    clear_published_sync(generation).await;
                                    break 'rebuild;
                                }
                                consecutive_failures += 1;
                                set_connection_status_for_generation(
                                    generation,
                                    sync_retry_status(consecutive_failures),
                                );
                                // The instance has failed; drop the published handle
                                // so subscribe/unsubscribe calls during the retry
                                // delay don't mutate a stale, soon-discarded instance.
                                clear_published_sync(generation).await;
                                if consecutive_failures >= DEGRADE_AFTER_FAILURES {
                                    degrade_to_traditional_sync(generation, &user_id).await;
                                    break 'rebuild;
                                }
                                interruptible_retry_sleep(
                                    generation,
                                    &user_id,
                                    sync_retry_delay(consecutive_failures),
                                )
                                .await;
                                continue 'rebuild;
                            }
                        }
                    }
                    if !sync_generation_is_active(generation, &user_id).await {
                        clear_published_sync(generation).await;
                        break;
                    }
                    app_log(
                        "warn",
                        "sync",
                        "Sliding Sync stream ended; restarting".to_string(),
                    );
                    // The stream ended (e.g. server closed the connection); the
                    // instance is no longer live, so clear the handle before the
                    // retry delay to avoid routing room subscriptions to it.
                    clear_published_sync(generation).await;
                    consecutive_failures =
                        failures_after_stream_end(consecutive_failures, received_update);
                    set_connection_status_for_generation(
                        generation,
                        sync_retry_status(consecutive_failures),
                    );
                    if consecutive_failures >= DEGRADE_AFTER_FAILURES {
                        degrade_to_traditional_sync(generation, &user_id).await;
                        break;
                    }
                    interruptible_retry_sleep(
                        generation,
                        &user_id,
                        sync_retry_delay(consecutive_failures),
                    )
                    .await;
                }
                clear_published_sync(generation).await;
            })
            .await;
    });

    Ok(PendingSyncTask { handle, start })
}

/// Hand the sync loop over to the traditional mode by restarting the whole
/// sync task. Called from inside the running loop, so it must not touch the
/// loop's own generation bookkeeping; the restarted `start_sync_internal`
/// stops the current task via `stop_sync_task` and installs a fresh
/// traditional loop.
pub(super) async fn degrade_to_traditional_sync(generation: u64, user_id: &str) {
    app_log(
        "warn",
        "sync",
        format!(
            "Sliding Sync failing repeatedly (generation {generation}); degrading to traditional sync"
        ),
    );
    {
        let mut degraded = SYNC_DEGRADED_ACCOUNTS.write().await;
        degraded.insert(user_id.to_string());
    }
    clear_published_sync(generation).await;
    // Fire-and-forget: the restarted task stops this one via stop_sync_task.
    // Re-check the active account inside the spawn: if the user switched
    // accounts while this degrade was in flight, restarting sync now would
    // stop the NEW account's (possibly healthy) loop and pin it to
    // traditional mode. The degraded marker stays — the next explicit
    // start_sync() clears it and re-probes Sliding Sync for that account.
    let degraded_user_id = user_id.to_string();
    let _handle = tokio::spawn(async move {
        let active_user = ACTIVE_USER.read().await.clone();
        if active_user.as_deref() != Some(degraded_user_id.as_str()) {
            app_log(
                "info",
                "sync",
                format!(
                    "Skipping degrade restart for {degraded_user_id}: the account is no longer active"
                ),
            );
            return;
        }
        let _ = start_sync_internal(true).await;
    });
}
