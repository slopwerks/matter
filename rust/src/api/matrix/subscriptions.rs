//! Subscriptions implementation.

use super::*;

pub(super) async fn set_subscription_user(user_id: Option<String>) {
    *SUBSCRIPTION_USER.write().await = user_id;
}

pub(super) fn subscription_user_matches(active: Option<&str>, requested: Option<&str>) -> bool {
    requested.is_none_or(|requested| active == Some(requested))
}

pub(super) async fn lock_subscription_state<'a, T>(
    subscription_user: &'a RwLock<Option<String>>,
    state: &'a Mutex<T>,
    account_user_id: Option<&str>,
    inactive_error: &'static str,
) -> Result<
    (
        tokio::sync::RwLockReadGuard<'a, Option<String>>,
        tokio::sync::MutexGuard<'a, T>,
    ),
    String,
> {
    let subscription_user = subscription_user.read().await;
    if !subscription_user_matches(subscription_user.as_deref(), account_user_id) {
        return Err(api_err("sync", inactive_error.to_string()));
    }
    let state = state.lock().await;
    Ok((subscription_user, state))
}

/// Parse the currently desired room ids into owned [`RoomId`]s.
///
/// Sliding Sync 0.19 replaced the incremental `subscribe_to_rooms` /
/// `unsubscribe_to_rooms` pair with the declarative `set_room_subscriptions`,
/// which drops every subscription not present in the given slice. Callers must
/// therefore pass the *whole* desired set, not just the room being changed.
pub(super) fn desired_room_ids(
    desired: &HashMap<String, HashSet<String>>,
) -> Vec<matrix_sdk::ruma::OwnedRoomId> {
    desired
        .keys()
        .filter_map(|room_id| matrix_sdk::ruma::RoomId::parse(room_id.as_str()).ok())
        .collect()
}

pub(super) fn receipt_extension_for_subscribed_rooms(
) -> matrix_sdk::ruma::api::client::sync::sync_events::v5::request::Receipts {
    use matrix_sdk::ruma::api::client::sync::sync_events::v5::request::{
        ExtensionRoomConfig, Receipts,
    };

    let mut receipts = Receipts::default();
    receipts.enabled = Some(true);
    receipts.rooms = Some(vec![ExtensionRoomConfig::AllSubscribed]);
    receipts
}

pub(super) async fn subscribe_room_for_receipts(
    room_id: String,
    account_user_id: Option<String>,
) -> Result<String, String> {
    // Reject a malformed room id up front; the desired set is keyed by string.
    matrix_sdk::ruma::RoomId::parse(room_id.as_str())
        .map_err(|e| api_err("sync", format!("无效的房间 ID: {e}")))?;
    let subscription_id = NEXT_ROOM_SUBSCRIPTION_ID
        .fetch_add(1, Ordering::Relaxed)
        .to_string();
    let (_subscription_user, mut state) = lock_subscription_state(
        &SUBSCRIPTION_USER,
        &ROOM_SUBSCRIPTION,
        account_user_id.as_deref(),
        "Room subscription belongs to an inactive account",
    )
    .await?;
    let first_subscriber = state.add_desired(&room_id, subscription_id.clone());
    if first_subscriber {
        if let Some(sliding_sync) = state.active.as_ref() {
            let owned = desired_room_ids(&state.desired);
            let refs = owned.iter().map(|id| id.as_ref()).collect::<Vec<_>>();
            sliding_sync.set_room_subscriptions(&refs, Some(live_room_subscription()), true);
        }
    }
    Ok(subscription_id)
}

pub(super) async fn unsubscribe_room_for_receipts(
    room_id: String,
    subscription_id: String,
    account_user_id: Option<String>,
) -> Result<(), String> {
    // Reject a malformed room id up front; the desired set is keyed by string.
    matrix_sdk::ruma::RoomId::parse(room_id.as_str())
        .map_err(|e| api_err("sync", format!("无效的房间 ID: {e}")))?;
    let (_subscription_user, mut state) = lock_subscription_state(
        &SUBSCRIPTION_USER,
        &ROOM_SUBSCRIPTION,
        account_user_id.as_deref(),
        "Room subscription belongs to an inactive account",
    )
    .await?;
    let last_subscriber = state.remove_desired(&room_id, &subscription_id);
    if last_subscriber {
        if let Some(sliding_sync) = state.active.as_ref() {
            let owned = desired_room_ids(&state.desired);
            let refs = owned.iter().map(|id| id.as_ref()).collect::<Vec<_>>();
            sliding_sync.set_room_subscriptions(&refs, Some(live_room_subscription()), true);
        }
    }
    Ok(())
}

pub(super) async fn is_connected() -> bool {
    let task_running = SYNC_TASK
        .lock()
        .await
        .as_ref()
        .is_some_and(|task| !task.handle.is_finished());
    task_running
}

pub(super) fn get_connection_status() -> ConnectionStatus {
    CONNECTION_STATE
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

pub(super) async fn init_client() -> Result<(), String> {
    Ok(())
}
