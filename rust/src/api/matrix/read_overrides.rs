//! Read overrides implementation.

use super::*;

pub(super) async fn synced_marked_unread(room: &Room) -> bool {
    room.account_data_static::<matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent>()
        .await
        .ok()
        .flatten()
        .and_then(|raw| raw.deserialize().ok())
        .is_some_and(|event| event.content.unread)
}

pub(super) fn marked_unread_override_key(client: &Client, room: &Room) -> Option<String> {
    client
        .user_id()
        .map(|user_id| format!("{user_id}:{}", room.room_id()))
}

pub(super) fn resolve_marked_unread(
    synced: bool,
    local: Option<MarkedUnreadOverride>,
) -> (bool, bool) {
    match local {
        // A fresh override matching the synced value is effective. A
        // `{baseline:true, desired:false}` clear in flight must ALSO be
        // effective while the store still reads false — the window between
        // issuing the clear and the pending `true` echo of the cleared
        // flag. Without this, the first read in that window would drop the
        // override as stale (synced != baseline) and the pending `true`
        // echo would briefly resurrect the unread marker. The TTL still
        // bounds the whole suppression: an expired override is stale
        // regardless of the synced value — a `true` arriving long after a
        // clear was issued is a *new* cross-device mark that must not be
        // suppressed for the rest of the session.
        Some(local)
            if local.created_at.elapsed() <= MARKED_UNREAD_OVERRIDE_TTL
                && (synced == local.baseline || (local.baseline && !local.desired && !synced)) =>
        {
            (local.desired, false)
        }
        Some(_) => (synced, true),
        None => (synced, false),
    }
}

pub(super) async fn effective_marked_unread(client: &Client, room: &Room) -> bool {
    let synced = synced_marked_unread(room).await;
    let Some(key) = marked_unread_override_key(client, room) else {
        return synced;
    };
    let mut overrides = MARKED_UNREAD_OVERRIDES.write().await;
    let (effective, stale) = resolve_marked_unread(synced, overrides.get(&key).copied());
    if stale {
        overrides.remove(&key);
    }
    effective
}

pub(super) async fn set_marked_unread_override(key: String, baseline: bool, desired: bool) {
    let mut overrides = MARKED_UNREAD_OVERRIDES.write().await;
    if baseline == desired {
        overrides.remove(&key);
    } else {
        overrides.insert(
            key,
            MarkedUnreadOverride {
                baseline,
                desired,
                created_at: std::time::Instant::now(),
            },
        );
    }
}

pub(super) fn reconcile_marked_unread_override(
    overrides: &mut HashMap<String, MarkedUnreadOverride>,
    key: &str,
    synced: bool,
) {
    // The override lives until the synced value reaches its baseline (the
    // state it was snapshot against); a different synced value means the
    // snapshot is stale. Crucially, a `{baseline:true, desired:false}`
    // override (a clear in flight) must survive the pending `true` echo —
    // synced == baseline — to keep suppressing the marker until the `false`
    // echo arrives. The TTL bounds that suppression: a `true` arriving long
    // after the clear was issued is a *new* cross-device mark, not the
    // pending echo, and must not be hidden for the rest of the session.
    if overrides.get(key).is_some_and(|local| {
        synced != local.baseline || local.created_at.elapsed() > MARKED_UNREAD_OVERRIDE_TTL
    }) {
        overrides.remove(key);
    }
}
