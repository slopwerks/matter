//! Account removal implementation.

use super::*;

pub(super) async fn logout() -> Result<AccountRemovalResult, String> {
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
    let active_user = {
        let active = ACTIVE_USER.read().await;
        active.clone()
    };

    let user_id =
        active_user.ok_or_else(|| api_err("auth", "No active account to logout".to_string()))?;
    clear_verification_session().await;
    set_subscription_user(None).await;
    stop_sync_task(None, false).await;
    clear_timeline_cache_for(&user_id).await;

    let entry = {
        let mut clients = CLIENTS.write().await;
        clients
            .remove(&user_id)
            .ok_or_else(|| api_err("auth", "Active account missing from store".to_string()))?
    };
    let next_user_id = {
        let clients = CLIENTS.read().await;
        clients.iter().next().map(|(id, _)| id.clone())
    };
    {
        let mut active = ACTIVE_USER.write().await;
        if let Some(next_id) = next_user_id.as_ref() {
            *active = Some(next_id.clone());
            app_log(
                "info",
                "auth",
                format!("Switched active account to: {}", next_id),
            );
            info!("Switched active account to: {}", next_id);
        } else {
            *active = None;
            app_log(
                "info",
                "auth",
                "No more accounts, active cleared".to_string(),
            );
            info!("No more accounts, active cleared");
        }
    }
    reset_connection_status();
    // Release the lifecycle lock before the network request and filesystem
    // cleanup so other API calls are not blocked while the server is unreachable
    // or while Windows releases file handles.
    drop(_sync_lifecycle);

    let (client, data_dir) = entry.into_client_and_data_dir().await;

    let mut remote_logout_pending = false;
    if client.matrix_auth().logged_in() {
        // Bound the remote logout: the server may be unreachable and the SDK
        // has no HTTP timeout. A timeout or failure still proceeds with local
        // cleanup below, so the account can be logged out locally and retried
        // on the server later. This runs outside the lifecycle write lock so
        // unrelated API calls are not frozen.
        match tokio::time::timeout(
            std::time::Duration::from_secs(15),
            client.matrix_auth().logout(),
        )
        .await
        {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                remote_logout_pending = true;
                // The token may still be valid on the server: remember it so
                // the next login of this account can retry the remote logout
                // (see finalize_pending) instead of leaving a ghost session.
                if let Some(session) = client.matrix_auth().session() {
                    PENDING_REMOTE_LOGOUTS.write().await.insert(
                        user_id.clone(),
                        (
                            session.tokens.access_token.to_string(),
                            client.homeserver().to_string(),
                        ),
                    );
                }
                app_log(
                    "warn",
                    "auth",
                    format!("Remote logout failed for {}: {e}", user_id),
                );
                warn!("Remote logout failed for {}: {e}", user_id);
            }
            Err(_) => {
                remote_logout_pending = true;
                if let Some(session) = client.matrix_auth().session() {
                    PENDING_REMOTE_LOGOUTS.write().await.insert(
                        user_id.clone(),
                        (
                            session.tokens.access_token.to_string(),
                            client.homeserver().to_string(),
                        ),
                    );
                }
                app_log(
                    "warn",
                    "auth",
                    format!(
                        "Remote logout timed out for {}, continuing locally",
                        user_id
                    ),
                );
                warn!(
                    "Remote logout timed out for {}, continuing locally",
                    user_id
                );
            }
        }
    }

    clear_account_runtime_state(&user_id).await;
    drop(client);
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let store_delete_result = delete_account_sdk_store(&data_dir, &user_id).await;

    // A start_sync already building when logout began can install itself
    // after the first stop while ACTIVE_USER still names this account. Stop
    // once more after changing ACTIVE_USER, before new routes may subscribe.
    stop_sync_task(None, false).await;
    set_subscription_user(next_user_id).await;

    Ok(AccountRemovalResult {
        cleanup_error: store_delete_result.err(),
        remote_logout_pending,
    })
}

pub(super) async fn remove_account(user_id: String) -> Result<AccountRemovalResult, String> {
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
    let removing_active = ACTIVE_USER.read().await.as_ref() == Some(&user_id);
    if removing_active {
        clear_verification_session().await;
        set_subscription_user(None).await;
    }
    // Drop the removed account's timelines regardless of whether it is
    // active: the cache is keyed per account and holds Arc<Timeline>
    // instances bound to the removed client (whose SQLite store is about
    // to be deleted) — re-logging into the account later must build fresh
    // timelines, not reuse dead ones. Scoped to THIS account: a global
    // clear would also tear down the timelines of the account the user is
    // currently in.
    clear_timeline_cache_for(&user_id).await;
    if removing_active {
        stop_sync_task(None, false).await;
    } else {
        stop_sync_task(Some(&user_id), false).await;
    }

    let entry = {
        let mut clients = CLIENTS.write().await;
        clients
            .remove(&user_id)
            .ok_or_else(|| api_err("auth", "Account not found".to_string()))?
    };
    let next_user_id = if removing_active {
        let clients = CLIENTS.read().await;
        clients.iter().next().map(|(id, _)| id.clone())
    } else {
        None
    };
    if removing_active {
        let mut active = ACTIVE_USER.write().await;
        *active = next_user_id.clone();
        reset_connection_status();
    }
    // Release the lifecycle lock before the network request and filesystem
    // cleanup so other API calls are not blocked.
    drop(_sync_lifecycle);

    let (client, data_dir) = entry.into_client_and_data_dir().await;

    let mut remote_logout_pending = false;
    if client.matrix_auth().logged_in() {
        // Bounded remote logout: see logout() — an unreachable server must
        // not freeze account removal. This runs outside the lifecycle write
        // lock so unrelated API calls are not frozen.
        match tokio::time::timeout(
            std::time::Duration::from_secs(15),
            client.matrix_auth().logout(),
        )
        .await
        {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                remote_logout_pending = true;
                // The token may still be valid on the server: remember it so
                // the next login of this account can retry the remote logout
                // (see finalize_pending) instead of leaving a ghost session.
                if let Some(session) = client.matrix_auth().session() {
                    PENDING_REMOTE_LOGOUTS.write().await.insert(
                        user_id.clone(),
                        (
                            session.tokens.access_token.to_string(),
                            client.homeserver().to_string(),
                        ),
                    );
                }
                app_log(
                    "warn",
                    "auth",
                    format!("Remote logout failed while removing {}: {e}", user_id),
                );
                warn!("Remote logout failed while removing {}: {e}", user_id);
            }
            Err(_) => {
                remote_logout_pending = true;
                if let Some(session) = client.matrix_auth().session() {
                    PENDING_REMOTE_LOGOUTS.write().await.insert(
                        user_id.clone(),
                        (
                            session.tokens.access_token.to_string(),
                            client.homeserver().to_string(),
                        ),
                    );
                }
                app_log(
                    "warn",
                    "auth",
                    format!(
                        "Remote logout timed out while removing {}, continuing locally",
                        user_id
                    ),
                );
                warn!(
                    "Remote logout timed out while removing {}, continuing locally",
                    user_id
                );
            }
        }
    }

    clear_account_runtime_state(&user_id).await;
    drop(client);
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let store_delete_result = delete_account_sdk_store(&data_dir, &user_id).await;

    if removing_active {
        // Close the same start_sync installation race as logout().
        stop_sync_task(None, false).await;
        set_subscription_user(next_user_id).await;
    }

    Ok(AccountRemovalResult {
        cleanup_error: store_delete_result.err(),
        remote_logout_pending,
    })
}
