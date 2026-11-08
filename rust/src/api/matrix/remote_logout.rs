//! Remote logout implementation.

use super::*;

/// Drop only the removed/logged-out/left account's timelines: a global
/// clear would tear down the timelines of every other active account (the
/// one the user is currently in included), forcing an avoidable rebuild.
/// The cache is keyed per account and holds Arc<Timeline> instances bound
/// to that account's client.
pub(super) async fn clear_timeline_cache_for(user_id: &str) {
    sdk_timeline::clear_for_user(user_id).await;
}

/// Fire-and-forget retry of a pending remote logout for [user_id] using the
/// freshly logged-in client's HTTP transport (the new session is up either
/// way). A cross-homeserver re-login cannot invalidate the old token — the
/// retry is skipped unless the homeserver matches. Only a 2xx response
/// settles the pending entry: the stored access token may have expired by
/// the time the retry runs (refresh tokens are enabled), so a 401 means
/// "this token is rejected", not "the session is gone" — the entry stays
/// for a later login of the same account to retry again.
pub(super) async fn retry_pending_remote_logout(user_id: &str, client: &Client) {
    let (token, homeserver) = match PENDING_REMOTE_LOGOUTS.read().await.get(user_id) {
        Some(entry) => entry.clone(),
        None => return,
    };
    let current_hs = client.homeserver().to_string();
    if current_hs.trim_end_matches('/') != homeserver.trim_end_matches('/') {
        return;
    }
    let client = client.clone();
    let user_id = user_id.to_string();
    tokio::spawn(async move {
        // Url Display always ends with '/': trim it so the path join does
        // not produce a double slash (some servers 404 on those).
        let base = client.homeserver().to_string();
        let url = format!("{}/_matrix/client/v3/logout", base.trim_end_matches('/'));
        let request = client.http_client().post(url).bearer_auth(token).send();
        let outcome = match tokio::time::timeout(std::time::Duration::from_secs(15), request).await
        {
            Err(_) => {
                app_log(
                    "warn",
                    "auth",
                    format!("Retried remote logout timed out for {user_id}"),
                );
                return;
            }
            Ok(result) => match result {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if remote_logout_retry_settles(status) {
                        // 2xx: the retry itself revoked the old token — the
                        // ghost session is gone; settle the pending entry.
                        PENDING_REMOTE_LOGOUTS.write().await.remove(&user_id);
                        None
                    } else if status == 401 {
                        // With refresh tokens enabled the access token
                        // expires on its own, so by the time the retry runs
                        // the stored token is usually expired even though
                        // the server-side session is still valid. A 401
                        // therefore does NOT prove the session was revoked:
                        // dropping the entry here would strand a live ghost
                        // session with no further retry. Keep it so the
                        // next login of this account tries again.
                        app_log(
                            "warn",
                            "auth",
                            format!(
                                "Retried remote logout for {user_id} rejected (401); keeping the pending entry for a later retry."
                            ),
                        );
                        None
                    } else {
                        Some(response.error_for_status())
                    }
                }
                Err(error) => Some(Err(error)),
            },
        };
        if let Some(Err(error)) = outcome {
            app_log(
                "warn",
                "auth",
                format!("Retried remote logout failed for {user_id}: {error}"),
            );
        }
    });
}

/// Whether a retried remote logout response settles the pending entry
/// (removes it): only a 2xx proves the session was revoked server-side. A
/// 401 is ambiguous when refresh tokens are enabled (the stored access
/// token may simply have expired) and must keep the entry for a later
/// retry.
pub(super) fn remote_logout_retry_settles(status: u16) -> bool {
    (200..300).contains(&status)
}
