//! Session restore implementation.

use super::*;

pub(super) async fn get_session() -> Option<StoredSession> {
    let client = get_client().await?;
    let auth = client.matrix_auth();
    if !auth.logged_in() {
        return None;
    }
    let session = auth.session()?;
    Some(StoredSession {
        homeserver_url: client.homeserver().to_string(),
        access_token: session.tokens.access_token,
        refresh_token: session.tokens.refresh_token,
        user_id: session.meta.user_id.to_string(),
        device_id: session.meta.device_id.to_string(),
    })
}

pub(super) async fn get_session_tokens(account_user_id: String) -> Option<SessionTokenUpdate> {
    let clients = CLIENTS.read().await;
    let client = &clients.get(&account_user_id)?.client;
    let session = client.matrix_auth().session()?;
    Some(SessionTokenUpdate {
        user_id: session.meta.user_id.to_string(),
        access_token: session.tokens.access_token,
        refresh_token: session.tokens.refresh_token,
    })
}

pub(super) async fn restore_session(
    session: StoredSession,
    data_dir: String,
    search_index_key: String,
    reset_search_index: bool,
    use_in_memory_search_index: bool,
) -> Result<(), String> {
    if !use_in_memory_search_index && search_index_key.is_empty() {
        return Err(api_err(
            "auth",
            "Encrypted search index key is empty".to_string(),
        ));
    }
    init_log_store(&data_dir);
    app_log(
        "info",
        "auth",
        format!(
            "restore_session: user={}, homeserver={}",
            session.user_id, session.homeserver_url
        ),
    );
    let url = url::Url::parse(&session.homeserver_url).map_err(|e| {
        let msg = format!("Invalid URL: {e}");
        app_log("error", "auth", msg.clone());
        msg
    })?;
    let sdk_dir = build_sdk_data_dir(&data_dir, Some(&session.user_id));

    // Hold the lifecycle lock only while inspecting/updating global state and
    // preparing the on-disk index directory. The expensive client build and
    // session restore happen outside the lock so other API calls can progress.
    let search_index_dir = {
        let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
        if CLIENTS.read().await.contains_key(&session.user_id) {
            return Ok(());
        }
        stop_sync_task(Some(&session.user_id), false).await;
        if use_in_memory_search_index {
            sdk_dir.join("search_index")
        } else {
            prepare_encrypted_search_index(&sdk_dir, reset_search_index).await?
        }
    };

    app_log(
        "info",
        "auth",
        format!("restore_session: SDK dir = {}", sdk_dir.display()),
    );

    let search_index_store = if use_in_memory_search_index {
        matrix_sdk::search_index::SearchIndexStoreKind::InMemory
    } else {
        matrix_sdk::search_index::SearchIndexStoreKind::EncryptedDirectory(
            search_index_dir.clone(),
            search_index_key,
        )
    };

    let client = matrix_client_builder()?
        .handle_refresh_tokens()
        .homeserver_url(url)
        .with_encryption_settings(encryption_settings())
        .request_config(bounded_request_config())
        .search_index_store(search_index_store)
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
        .map_err(|e| {
            let msg = format!("Client build failed: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;
    install_session_token_callback(&client)?;

    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id).map_err(|e| {
        let msg = format!("无效的用户 ID: {e}");
        app_log("error", "auth", msg.clone());
        msg
    })?;
    let device_id = matrix_sdk::ruma::OwnedDeviceId::from(session.device_id);

    let matrix_session = MatrixSession {
        meta: SessionMeta { user_id, device_id },
        tokens: SessionTokens {
            access_token: session.access_token,
            refresh_token: session.refresh_token,
        },
    };

    client
        .matrix_auth()
        .restore_session(matrix_session, RoomLoadSettings::default())
        .await
        .map_err(|e| {
            let msg = format!("Restore failed: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;
    wait_for_e2ee_initialization(&client, "session restore").await;
    let instance_id = NEXT_CLIENT_INSTANCE_ID.fetch_add(1, Ordering::Relaxed);
    let identity = ClientIdentity {
        user_id: session.user_id.clone(),
        instance_id,
    };
    install_verification_event_handler(&client, identity.clone());
    install_live_update_event_handlers(&client, identity.clone());
    desktop_notifications::install(&client, identity.clone()).await;
    let room_key_task = install_room_key_event_handler(&client, identity);

    // Reacquire the lock to install the client. Another restore/login may have
    // beaten us, in which case we drop our client and let the winner stand.
    {
        let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
        if CLIENTS.read().await.contains_key(&session.user_id) {
            drop(client);
            return Ok(());
        }
        // Add to multi-account store, dropping any runtime state bound to a
        // previous client for this account (e.g. after an engine rebuild).
        set_subscription_user(None).await;
        stop_sync_task(None, false).await;
        clear_account_runtime_state(&session.user_id).await;
        {
            let mut clients = CLIENTS.write().await;
            clients.insert(
                session.user_id.clone(),
                ClientEntry {
                    client,
                    data_dir: data_dir.clone(),
                    search_index_dir,
                    instance_id,
                    room_key_task,
                },
            );
        }

        // Set as active while closing the installation window for a sync builder
        // that started against the previously active account.
        {
            let mut active = ACTIVE_USER.write().await;
            *active = Some(session.user_id.clone());
        }
        stop_sync_task(None, false).await;
        reset_connection_status();
        set_subscription_user(Some(session.user_id.clone())).await;
        *SESSION_RELOGIN.write().await = None;
    }

    app_log(
        "info",
        "auth",
        format!("Session restored for {}", session.user_id),
    );
    Ok(())
}

pub(super) async fn get_access_token() -> Option<String> {
    let client = get_client().await?;
    let session = client.matrix_auth().session()?;
    Some(session.tokens.access_token)
}

pub(super) async fn get_refresh_token() -> Option<String> {
    let client = get_client().await?;
    let session = client.matrix_auth().session()?;
    session.tokens.refresh_token
}
