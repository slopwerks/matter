//! Room reads implementation.

use super::*;

pub(super) async fn mark_room_as_read(
    account_user_id: String,
    room_id: String,
    explicit: bool,
) -> Result<bool, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("account", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("account", "No active user".to_string()))?
        .to_string();
    let override_key = marked_unread_override_key(&client, &room)
        .ok_or_else(|| api_err("account", "No active user".to_string()))?;
    // Capture the account's current client instance id: the queued clear
    // may execute after a logout+relogin replaced the client (deep
    // predecessor chains). Same discipline as the other queued writes.
    let expected_instance_id = CLIENTS.read().await.get(&user_id).map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = client.clone();
    // The clear closure below is `move`; the outer function still needs
    // `user_id` for the queue key, so give the closure its own copy.
    let clear_user_id = user_id.clone();
    // The receipts are not a read-modify-write (the Timeline guards against
    // moving either marker backwards), so they are sent outside the queue —
    // an explicit read must not starve behind a flood of sync-driven
    // auto-reads. The marked-unread clear and the unread-override
    // bookkeeping DO mutate the same account-data event the unread-marker
    // write uses, so they run on the shared `read:{user}:{room}` key (the
    // same one mark_room_unread uses) to stay serialized with it.
    // The receipt step still holds the client lease (initial window
    // pagination can run several network attempts), so it is bounded — and
    // it runs CONCURRENTLY with the clear queue below (they touch disjoint
    // state: receipts vs account data), so the whole call is bounded by the
    // longer of the two (~90s; ~15s for the auto path, which bounds both
    // sides like the receipt send), not their sum.
    let receipt_future = {
        let receipt_room = room.clone();
        let receipt_client = mutation_client.clone();
        run_bounded(async move {
            sdk_timeline::send_read_receipts(&receipt_client, &receipt_room).await
        })
    };
    let clear_operation = async move {
        // Fail fast when the account was logged out or its client was
        // replaced while this clear was queued: writing the account-data
        // flag under a stale session would either 401 (misleading wording)
        // or land on a dead session's data (same discipline as the other
        // queued writes).
        let mutation_client = room.client();
        if !mutation_client.matrix_auth().logged_in() {
            return Err(api_err(
                "account",
                "当前账号已登出，请重新登录。".to_string(),
            ));
        }
        let is_current_client = CLIENTS
            .read()
            .await
            .get(&clear_user_id)
            .map(|e| e.instance_id)
            == expected_instance_id;
        if !is_current_client {
            return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
        }
        let baseline = synced_marked_unread(&room).await;
        let had_pending_unread_override = MARKED_UNREAD_OVERRIDES
            .read()
            .await
            .get(&override_key)
            .is_some_and(|local| {
                // Same TTL semantics as `resolve_marked_unread`: an expired
                // override no longer proves a pending local write — a
                // `true` echo arriving after the TTL is a NEW cross-device
                // mark that must not be suppressed.
                local.desired && local.created_at.elapsed() <= MARKED_UNREAD_OVERRIDE_TTL
            });
        // The store-checked clear below clears the server flag whenever
        // the room is being viewed (its marked_unread has synced
        // locally). That check can lag our own write: `marked_unread
        // = true` was set but its echo has not synced yet, so the store
        // still reads false and the clear is skipped. An explicit read
        // action clears the server flag even then — it must win over a
        // marked-unread state set on any device, including one that has
        // not echoed here yet — while the auto path only clears for our
        // own pending override (avoiding a per-message write
        // amplification).
        // The store-checked clear covers the flag once its echo has landed;
        // the outer clear then only needs to fire when the inner one did not
        // (explicit action against a flag whose echo has not landed here
        // yet, or our own pending unread override). This avoids double
        // writes based on the freshly read store state, not a stale sample.
        let inner_cleared = sdk_timeline::clear_marked_unread_if_set(&room)
            .await
            .map_err(|clear_error| {
                // The receipt ran concurrently (tokio::join!) and may
                // already have been sent: say so instead of a bare clear
                // failure — a retry re-sends both idempotently.
                api_err(
                    "account",
                    format!("已读回执可能已发送，但清除未读标记失败: {clear_error}，请重试。"),
                )
            })?;
        // The explicit branch is deliberately NOT gated on the locally
        // visible marker (baseline or our own pending override): a `false`
        // baseline is ambiguous — it can mean the room has no marker, or
        // that a marker set on another device has not echoed here yet.
        // Gating would silently defeat the explicit action in that window
        // (the flag survives and the room re-shows as unread). Writing
        // `false` when no marker exists is an idempotent no-op, and
        // explicit actions are rare user-initiated operations, so the
        // extra write is negligible. Only the auto path is gated, where
        // per-message write amplification is a real concern. This gating
        // applies to the clear WRITE; the suppression override below is
        // gated separately (only created when the flag was actually set).
        let explicit_clear =
            (explicit && !inner_cleared) || (had_pending_unread_override && !baseline);
        if explicit_clear {
            // A failed clear must still surface as an error (a retry
            // re-sends both idempotently) rather than promising success
            // while the server flag survives. The wording is
            // order-independent: the receipt may or may not have been
            // sent yet.
            sdk_timeline::clear_marked_unread(&room)
                .await
                .map_err(|clear_error| {
                    api_err(
                        "account",
                        format!("清除未读标记失败: {clear_error}，请重试。"),
                    )
                })?;
        }
        // The override suppresses the flag until the clear's echo
        // arrives. When a clear was just issued (explicit action, or our
        // own pending unread override) or the store already held the
        // flag, treat the flag as "was set, now clearing": with
        // baseline=true the override stays effective while a stale `true`
        // echo lands (showing read), and is removed once the `false`
        // echo arrives (showing the cleared store). Without this, a
        // pending `true` echo — including our own mark-unread write whose
        // echo has not landed yet — would briefly resurrect the unread
        // marker. A clean room with no clear intent gets no override.
        // The override is created ONLY when the flag was actually set
        // (visible baseline, or our own pending mark-unread write) — NOT
        // for an explicit read of a room that locally shows no marker: a
        // `{baseline:true, desired:false}` override suppresses any *new*
        // cross-device mark for the whole 30s TTL, swallowing an unread
        // flag the user never handled here. The clear itself is still
        // written unconditionally (an explicit read must win over an
        // un-echoed remote mark), but without an override the stale
        // `true` echo can briefly flash the room unread until the `false`
        // echo lands — that flicker is the accepted price for not hiding a
        // fresh remote mark.
        // Note: while the room keeps being viewed (auto-reads renew this
        // override with a fresh created_at), the suppression is effectively
        // extended — viewing IS the "handled now" signal, so this is
        // intended. Auto-reads only run while the room is viewed (they are
        // gated on the viewer/owner), so the 30s TTL bound starts as soon
        // as viewing stops, and the override cannot suppress a new
        // cross-device mark beyond that.
        let override_baseline = had_pending_unread_override || baseline;
        if override_baseline {
            set_marked_unread_override(override_key, override_baseline, false).await;
        }
        // Broadcast from inside the queued operation (like mute/pin): even
        // when the caller times out and this tail keeps running, the room
        // list still learns about the change. Only broadcast when a clear
        // actually happened: a plain auto-read with no flag set must not
        // invalidate the room list on every incoming message.
        if inner_cleared || explicit_clear {
            notify_sync_event_for_generation(generation, SyncEvent::RoomListChanged);
        }
        Ok(())
    };
    let clear_key = format!("read:{user_id}:{room_id}");
    // `Ok(true)` = the clear ran (or had nothing to clear); `Ok(false)` =
    // the auto path skipped enqueueing because a clear for this room is
    // already in flight (it re-reads the store at execution and covers the
    // current flag state). The receipt-failure wording must tell the two
    // apart: "已清除" would be wrong for a skipped clear.
    let clear_future: std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<bool, String>> + Send>,
    > = if explicit {
        Box::pin(async move {
            run_bounded_mutation(clear_key, lifecycle_protection, clear_operation)
                .await
                .map(|()| true)
        })
    } else {
        Box::pin(async move {
            // Auto-reads are background housekeeping that fire on every
            // message refresh; a backlogged clear queue must not hold the
            // client lease for the full 90s bound (it blocks logout/account
            // switch). Bound the auto path like the receipt side (15s): the
            // queued operation keeps running in its background tail after
            // the timeout, and the next refresh re-checks the store.
            // Explicit reads keep the full budget — they are rare and must
            // win.
            //
            // Under a message flood with a failing clear, the queue tail
            // for this room can chain (each clear waits behind its
            // predecessor's HTTP retries). A queued clear re-reads the
            // store at execution and covers the current flag state, so a
            // duplicate auto-clear adds nothing — skip the enqueue while
            // one is already in flight (the next refresh re-checks).
            if let Ok(tails) = MUTATION_TAILS.lock() {
                if tails.contains_key(&clear_key) {
                    return Ok(false);
                }
            }
            tokio::time::timeout(
                std::time::Duration::from_secs(15),
                run_bounded_mutation(clear_key, lifecycle_protection, clear_operation),
            )
            .await
            .unwrap_or_else(|_| Err(api_err("account", MUTATION_TIMEOUT_MESSAGE.to_string())))
            .map(|()| true)
        })
    };
    let (clear_result, receipt_result) = tokio::join!(clear_future, receipt_future);
    // `Ok(true)` = the marked-unread clear actually ran (or had nothing to
    // clear); `Ok(false)` = the auto path skipped it because a clear for
    // this room is already in flight (it re-reads the store at execution).
    // Dart uses the flag to decide whether a local unread:false override is
    // warranted — a skipped clear whose tail later fails must not leave a
    // stale "已读" override masking the server's marked-unread flag.
    let cleared = match clear_result {
        Ok(cleared) => {
            if cleared {
                receipt_result.map_err(|error| {
                    // The marked-unread clear succeeded (or had nothing to
                    // do); only the receipt send failed. Say so instead of
                    // claiming the whole action failed — a retry re-sends
                    // the receipt only.
                    api_err(
                        "account",
                        format!("未读标记已清除，但已读回执发送失败: {error}"),
                    )
                })?;
            } else {
                // The clear was skipped (one is already in flight and
                // covers this flag state); only the receipt failed.
                receipt_result.map_err(|error| {
                    api_err(
                        "account",
                        format!("已读回执发送失败: {error}（未读标记清除已在后台进行）"),
                    )
                })?;
            }
            cleared
        }
        Err(clear_error) => {
            if receipt_result.is_ok() {
                // The read receipt (the primary action) reached the server;
                // only the marked-unread bookkeeping is unsettled. Say so
                // instead of claiming the whole action failed. A queue-wait
                // timeout is not a failure: the clear never ran and keeps
                // running in its background tail, so neither "失败" nor
                // "请重试" applies.
                if clear_error == MUTATION_TIMEOUT_MESSAGE {
                    return Err(api_err(
                        "account",
                        "已读回执已发送；清除未读标记的操作仍在后台执行，请稍后刷新确认。"
                            .to_string(),
                    ));
                }
                return Err(api_err(
                    "account",
                    format!("已读回执已发送，但清除未读标记失败: {clear_error}，请重试。"),
                ));
            }
            // Both sides failed. When the clear side timed out (its
            // background tail keeps running), the receipt — the primary
            // action — has definitely failed: a hard receipt failure (e.g.
            // a rejected token) means the room stays unread on other
            // devices, so the generic "may have taken effect" line would
            // be wrong. (The receipt error can never equal
            // MUTATION_TIMEOUT_MESSAGE — its own bounded call resolves
            // with its own wording — so no receipt-side "may have been
            // delivered" branch is needed here.)
            if clear_error == MUTATION_TIMEOUT_MESSAGE {
                let receipt_error = receipt_result.unwrap_err();
                return Err(api_err(
                    "account",
                    format!("已读回执发送失败: {receipt_error}；清除未读标记的操作仍在后台执行，请稍后刷新确认。"),
                ));
            }
            // The receipt (the primary action) failed too: surface both
            // errors instead of hiding the receipt failure behind the clear.
            let receipt_error = receipt_result.unwrap_err();
            return Err(api_err(
                "account",
                format!(
                    "已读回执发送失败: {receipt_error}；清除未读标记失败: {clear_error}，请重试。"
                ),
            ));
        }
    };
    Ok(cleared)
}

pub(super) async fn mark_room_unread(
    account_user_id: String,
    room_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    use matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent;

    let client = get_client()
        .await
        .ok_or_else(|| api_err("account", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("account", "No active user".to_string()))?
        .to_string();
    let mutation_key = format!("read:{user_id}:{room_id}");
    let override_key = marked_unread_override_key(&client, &room)
        .ok_or_else(|| api_err("account", "No active user".to_string()))?;
    // Capture the account's current client instance id: the queued write
    // shares `read:{user}:{room}` with the clear path and may execute after
    // a logout+relogin replaced the client (deep predecessor chains). Same
    // discipline as the clear path and the other queued writes.
    let expected_instance_id = CLIENTS.read().await.get(&user_id).map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = room.client().clone();
    let clear_user_id = user_id.clone();
    run_bounded_mutation(mutation_key, lifecycle_protection, async move {
        // Fail fast when the account was logged out or its client was
        // replaced while this write was queued: a stale session must not
        // apply a late unread marker (and its wording would otherwise
        // mislead).
        if !mutation_client.matrix_auth().logged_in() {
            return Err(api_err(
                "account",
                "当前账号已登出，请重新登录。".to_string(),
            ));
        }
        let is_current_client = CLIENTS
            .read()
            .await
            .get(&clear_user_id)
            .map(|e| e.instance_id)
            == expected_instance_id;
        if !is_current_client {
            return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
        }
        let baseline = synced_marked_unread(&room).await;
        room.set_account_data(MarkedUnreadEventContent::new(true))
            .await
            .map(|_| ())
            .map_err(|error| api_err("account", format!("标记房间为未读失败: {error}")))?;
        set_marked_unread_override(override_key, baseline, true).await;
        // Broadcast from inside the queued operation (like mute/pin/read):
        // even when the caller times out and this tail keeps running, the
        // room list still learns about the change.
        notify_sync_event_for_generation(generation, SyncEvent::RoomListChanged);
        Ok(())
    })
    .await?;
    Ok(())
}
