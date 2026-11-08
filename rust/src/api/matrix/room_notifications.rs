//! Room notifications implementation.

use super::*;

pub(super) async fn is_room_muted(room_id: String) -> Result<bool, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = joined_non_space_room(&client, &room_id)?;
    // Bounded like the other P0 calls: the notification-settings read holds
    // the client lease for the call's duration (the settings instance is a
    // local store read — push rules arrive via sync — but consistency with
    // the other bounded P0 calls keeps the lease hold bounded).
    run_bounded(async move {
        let user_id = client
            .user_id()
            .map(|id| id.to_string())
            .unwrap_or_default();
        let settings = notification_settings_for(&client, &user_id, None).await;
        Ok(settings
            .get_user_defined_room_notification_mode(room.room_id())
            .await
            == Some(matrix_sdk::notification_settings::RoomNotificationMode::Mute))
    })
    .await
}

pub(super) async fn set_room_muted(
    account_user_id: String,
    room_id: String,
    muted: bool,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("rooms", "No active user".to_string()))?
        .to_string();
    // Capture the account's current client instance id: the queued write
    // must fail fast when a logout+relogin replaced the client before it
    // executes — rebuilding the shared NotificationSettings cache entry
    // with the stale client would shadow the fresh session's instance.
    let expected_instance_id = CLIENTS.read().await.get(&user_id).map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = client.clone();
    run_bounded_mutation(
        format!("muted:{user_id}:{room_id}"),
        lifecycle_protection,
        async move {
            // The write may execute long after the caller enqueued it (deep
            // predecessor chains): if the account was logged out meanwhile, the
            // client's token is dead — fail fast instead of rebuilding a stale
            // NotificationSettings instance (keyed by this user_id, it would
            // shadow a fresh session's settings entry).
            if !mutation_client.matrix_auth().logged_in() {
                return Err(api_err("rooms", "当前账号已登出，请重新登录。".to_string()));
            }
            // `logged_in()` can still pass when the remote logout failed/timed
            // out server-side (the local session kept its token while the
            // server revoked it). Rebuilds of the shared cache entry must also
            // be blocked when this client is no longer the account's CURRENT
            // one — a logout+relogin replaced it, and the stale instance would
            // shadow the fresh session's entry until the next logout.
            let is_current_client =
                CLIENTS.read().await.get(&user_id).map(|e| e.instance_id) == expected_instance_id;
            if !is_current_client {
                return Err(api_err("rooms", "当前账号已切换，请重试。".to_string()));
            }
            // Push-rule updates are read-modify-write server calls; serialize per
            // room so rapid toggles apply in click order instead of racing. The
            // shared per-account instance applies its own writes to its internal
            // ruleset, so a re-toggle right after the previous write cannot
            // misread the pre-write state from the store and no-op.
            let settings = notification_settings_for(
                &mutation_client,
                &user_id,
                // The instance id this closure's guard captured: the cache key
                // must bind to the client the settings are built from, never a
                // re-read of the mapping table (a logout+relogin between the
                // guard and this call must not key the stale handle under the
                // NEW session's id).
                expected_instance_id,
            )
            .await;
            if muted {
                settings
                    .set_room_notification_mode(
                        room.room_id(),
                        matrix_sdk::notification_settings::RoomNotificationMode::Mute,
                    )
                    .await
                    .map_err(|error| api_err("rooms", format!("更新通知设置失败: {error}")))?;
            } else {
                // Unknown encryption state (room joined but `m.room.encryption`
                // not synced yet) must default to encrypted: unmuting with
                // "not encrypted" would downgrade the rule to all-messages in a
                // room that is actually encrypted, leaking notification noise
                // (and hinting the room content to the push gateway).
                let is_encrypted = !matches!(
                    room.latest_encryption_state().await,
                    Ok(state) if !state.is_encrypted()
                );
                // A 1:1 must be classified correctly or unmuting installs the
                // group default rule (mention-only) on it, silencing ordinary
                // messages on every device until the user re-mutes. `is_direct()`
                // only reflects `m.direct` account data (often absent for
                // invites), so fall back to the same member-count heuristic the
                // room list uses (shared predicate, see `is_dm_by_members`).
                let is_one_to_one =
                    room.is_direct().await.unwrap_or(false) || is_dm_by_members(&room).await;
                settings
                    .unmute_room(
                        room.room_id(),
                        matrix_sdk::notification_settings::IsEncrypted::from(is_encrypted),
                        matrix_sdk::notification_settings::IsOneToOne::from(is_one_to_one),
                    )
                    .await
                    .map_err(|error| api_err("rooms", format!("更新通知设置失败: {error}")))?;
            }
            // Broadcast from inside the queued operation: even when the caller
            // times out (90s bound) and this tail keeps running, the room list
            // still learns about the change (like set_pinned_message).
            notify_sync_event_for_generation(generation, SyncEvent::RoomListChanged);
            Ok(())
        },
    )
    .await?;
    Ok(())
}
