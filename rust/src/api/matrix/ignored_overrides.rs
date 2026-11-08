//! Ignored overrides implementation.

use super::*;

pub(super) fn ignored_override_expired(local: &IgnoredUserOverride) -> bool {
    local
        .event_seen
        .is_some_and(|seen| seen.elapsed() >= IGNORED_OVERRIDE_TTL)
}

pub(super) fn ignored_user_override_key(
    client: &Client,
    target: &matrix_sdk::ruma::UserId,
) -> Option<String> {
    client
        .user_id()
        .map(|user_id| format!("{user_id}:{target}"))
}

pub(super) fn resolve_ignored_user(
    synced: bool,
    local: Option<IgnoredUserOverride>,
) -> (bool, bool) {
    match local {
        Some(local) if synced == local.baseline => (local.desired, false),
        Some(_) => (synced, true),
        None => (synced, false),
    }
}

/// Effective ignored state for previews: while the state store still shows
/// the baseline of a confirmed write, report the confirmed value; once the
/// echo (or any newer server state) advances the store, the store wins and
/// the stale override is dropped.
pub(super) async fn effective_is_user_ignored(
    client: &Client,
    target: &matrix_sdk::ruma::UserId,
) -> bool {
    let synced = client.is_user_ignored(target).await;
    let Some(key) = ignored_user_override_key(client, target) else {
        return synced;
    };
    let mut overrides = IGNORED_USER_OVERRIDES.write().await;
    if overrides.get(&key).is_some_and(ignored_override_expired) {
        overrides.remove(&key);
    }
    let (effective, stale) = resolve_ignored_user(synced, overrides.get(&key).copied());
    if stale {
        overrides.remove(&key);
    }
    effective
}

pub(super) async fn set_ignored_user_override(key: String, baseline: bool, desired: bool) {
    let mut overrides = IGNORED_USER_OVERRIDES.write().await;
    if baseline == desired {
        overrides.remove(&key);
    } else {
        overrides.insert(
            key,
            IgnoredUserOverride {
                baseline,
                desired,
                event_seen: None,
            },
        );
    }
}

pub(super) fn merge_ignored_user_overrides(
    account_prefix: &str,
    content: &mut IgnoredUserListEventContent,
    overrides: &mut HashMap<String, IgnoredUserOverride>,
) {
    overrides.retain(|key, local| {
        let Some(target) = key.strip_prefix(account_prefix) else {
            return true;
        };
        let Ok(user_id) = matrix_sdk::ruma::OwnedUserId::try_from(target) else {
            return false;
        };
        if ignored_override_expired(local) {
            return false;
        }
        let synced = content.ignored_users.contains_key(&user_id);
        let (effective, stale) = resolve_ignored_user(synced, Some(*local));
        if effective {
            content.ignored_users.insert(user_id, IgnoredUser::new());
        } else {
            content.ignored_users.remove(&user_id);
        }
        !stale
    })
}

pub(super) async fn merge_current_account_ignored_user_overrides(
    client: &Client,
    content: &mut IgnoredUserListEventContent,
) {
    let Some(account_prefix) = client.user_id().map(|user_id| format!("{user_id}:")) else {
        return;
    };
    let mut overrides = IGNORED_USER_OVERRIDES.write().await;
    merge_ignored_user_overrides(&account_prefix, content, &mut overrides);
}

/// Reconcile ignored-user overrides against an authoritative account-data
/// event. The event proves the server list advanced past every local write:
///
/// - A target that IS in the received content was decided by the server
///   (echo or a cross-device change); its override is stale either way.
/// - A target that is NOT in the content, with `desired=false` (an
///   un-ignore), was confirmed by the server; its override is stale.
/// - A target that is NOT in the content, with `desired=true` (an ignore),
///   may still be awaiting its echo (the snapshot predates our write, e.g.
///   a concurrent write to a different target synced first). It is kept,
///   but its `event_seen` timestamp is set so the TTL expires it in the
///   ABA case where a cross-device un-ignore coalesced the list back to
///   the pre-write baseline. Overrides for other accounts are untouched.
///
/// Without the TTL an override whose target is no room's latest sender
/// would never be read, never expire, and would keep hiding previews after
/// another device un-ignores the user.
pub(super) fn reconcile_ignored_user_overrides_inner(
    account_prefix: &str,
    content: &IgnoredUserListEventContent,
    overrides: &mut HashMap<String, IgnoredUserOverride>,
) {
    overrides.retain(|key, local| {
        let Some(target) = key.strip_prefix(account_prefix) else {
            // Belongs to another account; leave it untouched.
            return true;
        };
        let Ok(user_id) = matrix_sdk::ruma::UserId::parse(target) else {
            return false;
        };
        if content.ignored_users.contains_key(&user_id) || !local.desired {
            return false;
        }
        if ignored_override_expired(local) {
            return false;
        }
        // Start the TTL clock on the first event that does not confirm the
        // target. Do NOT refresh it on every event: global account data is
        // delivered on each sync response even when unchanged, so refreshing
        // would keep the override alive forever in the ABA case (a
        // cross-device un-ignore that coalesces the list back to baseline).
        if local.event_seen.is_none() {
            local.event_seen = Some(std::time::Instant::now());
        }
        true
    });
}

pub(super) async fn reconcile_ignored_user_overrides(
    client: &Client,
    content: &IgnoredUserListEventContent,
) {
    let Some(account_prefix) = client.user_id().map(|user_id| format!("{user_id}:")) else {
        return;
    };
    let mut overrides = IGNORED_USER_OVERRIDES.write().await;
    reconcile_ignored_user_overrides_inner(&account_prefix, content, &mut overrides);
}
