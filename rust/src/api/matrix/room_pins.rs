//! Room pins implementation.

use super::*;

pub(super) async fn get_pinned_event_ids(
    account_user_id: String,
    room_id: String,
) -> Result<Vec<String>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("pinned", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    run_bounded(async move {
        // Bound the server read more tightly than the client default (the
        // SDK's RequestConfig already caps a single request at 30s, but
        // with 3 retries a dead network could still stall the long-press
        // menu well past the 90s outer bound).
        let ids = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            room.load_pinned_events(),
        )
        .await
        .map_err(|_| api_err("pinned", "加载置顶状态超时，请重试".to_string()))?
        .map_err(|error| api_err("pinned", format!("加载置顶状态失败，请重试: {error}")))?
        .unwrap_or_default();
        Ok(ids.into_iter().map(|id| id.to_string()).collect())
    })
    .await
}

pub(super) async fn set_pinned_message(
    account_user_id: String,
    room_id: String,
    event_id: String,
    pinned: bool,
) -> Result<bool, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("pinned", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let event_id = matrix_sdk::ruma::EventId::parse(event_id)
        .map_err(|error| api_err("pinned", format!("无效的事件 ID: {error}")))?;
    // Capture the account's current client instance id: the queued write
    // may execute after a logout+relogin replaced the client (deep
    // predecessor chains). Same discipline as `set_room_muted` /
    // `create_dm` / `set_user_ignored`.
    let expected_instance_id = CLIENTS
        .read()
        .await
        .get(&account_user_id)
        .map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let pinned_result = Arc::new(AtomicBool::new(false));
    let queued_result = pinned_result.clone();
    run_bounded_mutation(
        format!("pinned:{room_id}"),
        lifecycle_protection,
        async move {
            // Fail fast when the account was logged out or its client was
            // replaced while this write was queued (the pinned list is
            // room-shared state, but writing under a stale session's token
            // would mislead with an unrelated error).
            let mutation_client = room.client();
            if !mutation_client.matrix_auth().logged_in() {
                return Err(api_err(
                    "pinned",
                    "当前账号已登出，请重新登录。".to_string(),
                ));
            }
            let is_current_client = CLIENTS
                .read()
                .await
                .get(&account_user_id)
                .map(|e| e.instance_id)
                == expected_instance_id;
            if !is_current_client {
                return Err(api_err("pinned", "当前账号已切换，请重试。".to_string()));
            }
            // RMW against the authoritative server state: the SDK's in-memory
            // room state lags our own writes until the sync echo, so rapid
            // pin/unpin sequences would otherwise overwrite each other.
            // load_pinned_events is a server read that maps a missing
            // m.room.pinned_events state (first-ever pin) to an empty list.
            // The key is room-scoped (not per account): the pinned list is
            // room-shared state, so two accounts toggling the same room must
            // serialize or their read-modify-writes would clobber each other.
            let mut pinned_ids = room
                .load_pinned_events()
                .await
                .map_err(|error| api_err("pinned", format!("加载置顶状态失败: {error}")))?
                .unwrap_or_default();
            let already_pinned = pinned_ids.iter().any(|id| id == &event_id);
            let changed = if pinned {
                if !already_pinned {
                    // Matrix clients append newly pinned events. The pinned
                    // timeline also reads the bounded cache from the tail,
                    // so preserving that order keeps the newest 128 cached.
                    pinned_ids.push(event_id.to_owned());
                    true
                } else {
                    false
                }
            } else if already_pinned {
                pinned_ids.retain(|id| id != &event_id);
                true
            } else {
                false
            };
            if changed {
                room.send_state_event(
                matrix_sdk::ruma::events::room::pinned_events::RoomPinnedEventsEventContent::new(
                    pinned_ids,
                ),
            )
            .await
            .map_err(|error| api_err("pinned", format!("更新置顶消息失败: {error}")))?;
                // Broadcast from inside the queued operation: even when the
                // caller times out (90s bound) and this tail keeps running, the
                // pinned page still learns about the change.
                notify_sync_event_for_generation(
                    generation,
                    SyncEvent::PinnedMessagesChanged { room_id },
                );
            }
            queued_result.store(pinned, Ordering::Relaxed);
            Ok(())
        },
    )
    .await?;
    let pinned = pinned_result.load(Ordering::Relaxed);
    Ok(pinned)
}

pub(super) async fn get_pinned_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("pinned", "No client created.".to_string()))?;
    let room = joined_non_space_room(&client, &room_id)?;
    // The load holds the client lease (SYNC_LIFECYCLE read lock) for its
    // whole duration, blocking logout/account switch, which need the write
    // lock. The internal stages are individually bounded (15s list read +
    // 20s cache wait + 10s pinned-timeline build + 25s focused fetch =
    // 70s; cache setup steps before them are unbounded, so headroom is
    // kept generous), and the total bound below exceeds that sum so the
    // inner stage timeouts (which degrade to partial results) fire before
    // the outer one (which fails the whole page) even when several expire
    // in the same tick.
    tokio::time::timeout(
        std::time::Duration::from_secs(90),
        sdk_timeline::get_pinned_messages(&room),
    )
    .await
    .map_err(|_| api_err("pinned", "加载置顶消息超时。".to_string()))?
}
