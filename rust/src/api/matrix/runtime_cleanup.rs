//! Runtime cleanup implementation.

use super::*;

pub(super) async fn notification_settings_for(
    client: &Client,
    user_id: &str,
    expected_instance_id: Option<u64>,
) -> matrix_sdk::notification_settings::NotificationSettings {
    // Key by (user_id, instance_id) so a restored/replaced client can never
    // reuse the old client's handle. Queue-tail callers pass the instance id
    // their own guard captured, so the key always matches the client the
    // settings were built from.
    let instance_id = match expected_instance_id {
        Some(id) => Some(id),
        None => CLIENTS
            .read()
            .await
            .get(user_id)
            .map(|entry| entry.instance_id),
    };
    let cache_key = match instance_id {
        Some(id) => format!("{user_id}:{id}"),
        None => user_id.to_string(),
    };
    if let Some(settings) = NOTIFICATION_SETTINGS.read().await.get(&cache_key) {
        return settings.clone();
    }
    let settings = client.notification_settings().await;
    NOTIFICATION_SETTINGS
        .write()
        .await
        .entry(cache_key)
        .or_insert(settings)
        .clone()
}

/// Request configuration for user-initiated operations.
///
/// The SDK default already has a 30s per-request timeout and does not retry
/// network failures, but it retries transient server errors (5xx/429)
/// indefinitely, bounded only by a 15-minute total delay — a server stuck in
/// an error loop would leave a P0 operation (leave, invite, rename, mute,
/// pin, read markers, ignore, knock) spinning without feedback for minutes.
/// `retry_limit(3)` caps that at three attempts (~93s worst case with
/// backoff, matching the 90s call-side bounds closely), at the cost of also
/// retrying network failures up to twice — a bounded, user-visible failure
/// either way (an operation that outlives the call-side bound keeps running
/// in its background queue task). Sliding Sync builds its own request config
/// and is unaffected. Media uploads inherit the retry limit but override the
/// timeout by size; media downloads also inherit the retry limit (their
/// timeout is lifted to unlimited) — a flaky-network large download fails
/// after three attempts instead of retrying forever.
pub(super) fn bounded_request_config() -> RequestConfig {
    RequestConfig::new()
        .timeout(std::time::Duration::from_secs(30))
        .retry_limit(3)
}

/// Drop per-account runtime state whenever a client is removed or replaced
/// (logout, account removal, or login replacing an existing client), so a
/// later session never reuses state bound to the old client or sync position.
pub(super) async fn clear_account_runtime_state(user_id: &str) {
    {
        // Prefix match: since the instance-keyed change, entries are
        // `{user_id}:{instance_id}` (the bare `{user_id}` key survives from
        // before the change).
        let mut settings = NOTIFICATION_SETTINGS.write().await;
        settings.retain(|key, _| key != user_id && !key.starts_with(&format!("{user_id}:")));
    }
    {
        let mut overrides = MARKED_UNREAD_OVERRIDES.write().await;
        overrides.retain(|key, _| !key.starts_with(&format!("{user_id}:")));
    }
    {
        let mut overrides = IGNORED_USER_OVERRIDES.write().await;
        overrides.retain(|key, _| !key.starts_with(&format!("{user_id}:")));
    }
    {
        let mut backfills = SEARCH_CACHE_BACKFILL_PROGRESS.lock().await;
        backfills.retain(|key, _| !key.starts_with(&format!("{user_id}\n")));
    }
    {
        let mut generations = SEARCH_QUERY_GENERATIONS.lock().await;
        generations.retain(|key, _| !key.starts_with(&format!("{user_id}\n")));
    }
    {
        let mut backfills = SEARCH_HISTORY_BACKFILLS.lock().await;
        backfills.retain(|key, _| !key.starts_with(&format!("{user_id}\n")));
    }
    {
        let mut complete = SEARCH_HISTORY_COMPLETE.lock().await;
        complete.retain(|key| !key.starts_with(&format!("{user_id}\n")));
    }
    // Queued mutations for this account (keys are `{kind}:{user_id}:...`,
    // `ignored:{user_id}`, or the room-scoped `pinned:{room_id}` shared
    // across accounts) are deliberately NOT dropped. Their background tails
    // retain lifecycle read protection until completion, so teardown drains
    // them before revoking the session or deleting its store. Keeping the
    // queue entries also preserves serialization with any successor.
    // Note: Matrix user IDs contain a colon (`@alice:example.org`), so the
    // kind must be split off with `split_once`, never by splitting the whole
    // key on colons.
}
