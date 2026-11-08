//! Auth registration implementation.

use super::*;

pub(super) async fn create_client(
    homeserver_url: String,
    data_dir: String,
    search_index_key: String,
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
        format!("create_client: homeserver={}", homeserver_url),
    );
    let url = url::Url::parse(&homeserver_url).map_err(|e| {
        let msg = format!("Invalid URL: {e}");
        app_log("error", "auth", msg.clone());
        msg
    })?;
    let sdk_dir = build_sdk_data_dir(&data_dir, None);

    // Staging, build and install must be atomic against `cancel_pending_login`:
    // the lock is held across the whole function so a cancel cannot delete the
    // pending store while this client is being built on it.
    let _pending_lifecycle = PENDING_LIFECYCLE.lock().await;

    // Remove any stale pending directory under the lifecycle write lock (the
    // build itself deliberately runs without it so it cannot block unrelated
    // API calls).
    {
        let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
        if sdk_dir.exists() {
            info!("Removing stale pending dir: {}", sdk_dir.display());
            if let Err(e) = remove_dir_all_if_exists(&sdk_dir).await {
                warn!("Failed to clean pending dir: {e}");
            }
        }
        let mut pending = PENDING.write().await;
        *pending = None;
    }

    let client = matrix_client_builder()?
        .handle_refresh_tokens()
        .homeserver_url(url)
        .with_encryption_settings(encryption_settings())
        .request_config(bounded_request_config())
        .search_index_store(matrix_sdk::search_index::SearchIndexStoreKind::InMemory)
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
        .map_err(|e| {
            let msg = format!("Failed to create client: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;
    install_session_token_callback(&client)?;

    app_log(
        "info",
        "auth",
        format!("Client created for {}", homeserver_url),
    );

    {
        let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
        // If another login attempt finished while we were building the client,
        // drop this one and let the winner stand. `PENDING_LIFECYCLE` already
        // rules out a concurrent `cancel_pending_login`, so the directory this
        // client was built on has not been deleted underneath us.
        if PENDING.read().await.is_some() {
            drop(client);
            return Err(api_err(
                "auth",
                "Another login attempt completed while this one was initializing".to_string(),
            ));
        }
        let mut pending = PENDING.write().await;
        *pending = Some(PendingEntry {
            client,
            data_dir,
            homeserver_url,
            search_index_key,
        });
    }
    Ok(())
}

pub(super) async fn cancel_pending_login() -> Result<(), String> {
    // Same lock as `create_client`: cancelling may not observe a half-staged
    // pending login, and may not delete a store a concurrent create is
    // building on.
    let _pending_lifecycle = PENDING_LIFECYCLE.lock().await;
    let _lifecycle = SYNC_LIFECYCLE.write().await;
    let Some(pending) = PENDING.write().await.take() else {
        return Ok(());
    };
    let sdk_dir = build_sdk_data_dir(&pending.data_dir, None);
    // Drop the client but hold `PENDING_LIFECYCLE` for the delete below: an
    // interleaved `create_client` must not re-stage the same `_pending` path
    // while we are unlinking it.
    drop(pending);
    drop(_lifecycle);
    // SQLite can release its pooled file handles just after the client drops.
    for attempt in 0..3 {
        match remove_dir_all_if_exists(&sdk_dir).await {
            Ok(_) => return Ok(()),
            Err(error) if attempt == 2 => {
                return Err(api_err(
                    "auth",
                    format!("Failed to clear pending login: {error}"),
                ));
            }
            Err(_) => tokio::time::sleep(std::time::Duration::from_millis(100)).await,
        }
    }
    Ok(())
}

pub(super) async fn register_get_uiaa_session(
    username: String,
    password: String,
) -> Result<AuthResult, String> {
    app_log(
        "info",
        "auth",
        format!("register_get_uiaa_session: user={}", username),
    );
    let client = get_pending_client().await.ok_or_else(|| {
        api_err(
            "auth",
            "No client created. Call create_client first.".to_string(),
        )
    })?;

    let mut request = RegistrationRequest::new();
    request.username = Some(username);
    request.password = Some(password);
    request.initial_device_display_name = Some(get_initial_device_name());
    request.refresh_token = true;
    request.auth = Some(AuthData::Dummy(Dummy::new()));

    match client.matrix_auth().register(request).await {
        Ok(response) => {
            drop(client);
            finalize_pending()
                .await
                .map_err(|e| api_err("auth", format!("Finalization failed: {e}")))?;
            Ok(AuthResult {
                success: true,
                user_id: Some(response.user_id.to_string()),
                device_id: response.device_id.map(|d| d.to_string()),
                access_token: response.access_token,
                refresh_token: response.refresh_token,
                error: None,
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
        Err(err) => {
            let err_str = format!("{err}");
            info!(
                "register_get_uiaa_session error: {}",
                truncate_utf8(&err_str, 300)
            );

            if let Some(result) = try_extract_uiaa(&err) {
                return Ok(result);
            }

            if let Some(result) = try_parse_uiaa_from_string(&err_str) {
                return Ok(result);
            }

            warn!("No UIAA info extracted from get_uiaa_session");
            Ok(AuthResult {
                success: false,
                user_id: None,
                device_id: None,
                access_token: None,
                refresh_token: None,
                error: Some(friendly_auth_error(&err_str, "注册失败，请稍后重试")),
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
    }
}

pub(super) async fn register_complete_uiaa(
    username: String,
    password: String,
    registration_token: String,
    session: String,
) -> Result<AuthResult, String> {
    app_log(
        "info",
        "auth",
        format!("register_complete_uiaa: user={}", username),
    );
    let client = get_pending_client().await.ok_or_else(|| {
        api_err(
            "auth",
            "No client created. Call create_client first.".to_string(),
        )
    })?;

    let mut request = RegistrationRequest::new();
    request.username = Some(username);
    request.password = Some(password);
    request.initial_device_display_name = Some(get_initial_device_name());
    request.refresh_token = true;

    let mut reg_token = RegistrationToken::new(registration_token);
    reg_token.session = Some(session);
    request.auth = Some(AuthData::RegistrationToken(reg_token));

    match client.matrix_auth().register(request).await {
        Ok(response) => {
            // Auto-finalize: migrate pending client to per-user store
            drop(client);
            let finalized = finalize_pending()
                .await
                .map_err(|e| api_err("auth", format!("Finalization failed: {e}")))?;
            info!("Account finalized after registration: {}", finalized);
            Ok(AuthResult {
                success: true,
                user_id: Some(response.user_id.to_string()),
                device_id: response.device_id.map(|d| d.to_string()),
                access_token: response.access_token,
                refresh_token: response.refresh_token,
                error: None,
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
        Err(err) => {
            let err_str = format!("{err}");
            info!(
                "register_complete_uiaa error: {}",
                truncate_utf8(&err_str, 300)
            );

            if let Some(result) = try_extract_uiaa(&err) {
                return Ok(result);
            }

            if let Some(result) = try_parse_uiaa_from_string(&err_str) {
                return Ok(result);
            }

            Ok(AuthResult {
                success: false,
                user_id: None,
                device_id: None,
                access_token: None,
                refresh_token: None,
                error: Some(friendly_auth_error(&err_str, "注册失败，请稍后重试")),
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
    }
}

/// Device name reported to the homeserver when logging in: `Matter <platform>`.
/// Internal helper: kept out of the bridge so it does not widen the public API.
pub(super) fn get_initial_device_name() -> String {
    device_name_for_platform(std::env::consts::OS)
}

/// Split from the environment lookup so the mapping is covered by unit tests.
pub(super) fn device_name_for_platform(os: &str) -> String {
    let platform = match os {
        "android" => "Android",
        "ios" => "iOS",
        "linux" => "Linux",
        "macos" => "macOS",
        "windows" => "Windows",
        other => other,
    };
    format!("Matter {platform}")
}
