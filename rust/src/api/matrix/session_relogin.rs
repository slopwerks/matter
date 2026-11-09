//! Session relogin implementation.

use super::*;

pub(super) async fn list_accounts() -> Vec<AccountInfo> {
    let clients = CLIENTS.read().await;
    clients
        .iter()
        .map(|(user_id, entry)| AccountInfo {
            user_id: user_id.clone(),
            device_id: entry
                .client
                .device_id()
                .map(|d| d.to_string())
                .unwrap_or_default(),
            homeserver_url: entry.client.homeserver().to_string(),
        })
        .collect()
}

pub(super) async fn switch_account(user_id: String) -> bool {
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
    let clients = CLIENTS.read().await;
    if clients.contains_key(&user_id) {
        drop(clients);
        set_subscription_user(None).await;
        stop_sync_task(None, false).await;
        let previous_user = {
            let mut active = ACTIVE_USER.write().await;
            let previous = active.clone();
            *active = Some(user_id.clone());
            previous
        };
        if previous_user.as_deref() != Some(&user_id) {
            *SESSION_RELOGIN.write().await = None;
            reset_connection_status();
        }
        set_subscription_user(Some(user_id.clone())).await;
        clear_verification_session().await;
        // Drop only the previously active account's timelines: a global
        // clear would also tear down the timelines of the account being
        // switched to (the one the user is currently in), forcing an
        // avoidable rebuild. With no previously active account, fall back
        // to the target's own cache to keep the old defensive clear.
        clear_timeline_cache_for(previous_user.as_deref().unwrap_or(&user_id)).await;
        app_log("info", "auth", format!("Switched to account: {}", user_id));
        info!("Switched to account: {}", user_id);
        true
    } else {
        app_log(
            "warn",
            "auth",
            format!("switch_account: account {} not found", user_id),
        );
        false
    }
}

pub(super) async fn prepare_session_relogin(account_user_id: String) -> Result<bool, String> {
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
    if ACTIVE_USER.read().await.as_deref() != Some(&account_user_id) {
        return Err(api_err("auth", "当前账号已切换，请重试。".to_string()));
    }
    if !matches!(get_connection_status(), ConnectionStatus::SessionExpired) {
        return Err(api_err("auth", "当前登录尚未失效。".to_string()));
    }
    if !CLIENTS.read().await.contains_key(&account_user_id) {
        return Err(api_err("auth", "No client created.".to_string()));
    }
    set_subscription_user(None).await;
    stop_sync_task(None, false).await;
    clear_verification_session().await;
    clear_timeline_cache_for(&account_user_id).await;
    clear_account_runtime_state(&account_user_id).await;
    let entry = CLIENTS.write().await.remove(&account_user_id).unwrap();
    let resume = *SESSION_EXPIRY.read().unwrap_or_else(|e| e.into_inner())
        == Some(SessionExpiry::SoftLogout);
    *SESSION_RELOGIN.write().await = if resume {
        entry
            .client
            .matrix_auth()
            .session()
            .map(|session| SessionRelogin {
                meta: session.meta,
                data_dir: entry.data_dir.clone(),
                homeserver_url: entry.client.homeserver().to_string(),
                instance_id: entry.instance_id,
            })
    } else {
        None
    };
    let can_resume = SESSION_RELOGIN.read().await.is_some();
    *ACTIVE_USER.write().await = None;
    reset_connection_status();
    let (client, _) = entry.into_client_and_data_dir().await;
    drop(client);
    Ok(can_resume)
}

pub(super) async fn resume_session_with_password(
    account_user_id: String,
    password: String,
    search_index_key: String,
    reset_search_index: bool,
    use_in_memory_search_index: bool,
) -> Result<AuthResult, String> {
    use matrix_sdk::ruma::api::client::session::login::v3::{LoginInfo, Password, Request};
    use matrix_sdk::ruma::api::client::uiaa::{MatrixUserIdentifier, UserIdentifier};

    let _relogin = SESSION_RELOGIN_LOCK.lock().await;
    let lifecycle = SYNC_LIFECYCLE.read().await;
    let context = SESSION_RELOGIN
        .read()
        .await
        .clone()
        .filter(|context| context.meta.user_id.as_str() == account_user_id)
        .ok_or_else(|| api_err("auth", "没有可恢复的设备会话，请重新登录。".to_string()))?;
    if ACTIVE_USER.read().await.is_some() {
        return Err(api_err("auth", "当前账号已切换，请重试。".to_string()));
    }
    let sdk_dir = build_sdk_data_dir(&context.data_dir, Some(&account_user_id));
    if !sdk_dir.exists() {
        return Err(api_err(
            "auth",
            "原设备加密数据已丢失，需要重新登录并验证设备。".to_string(),
        ));
    }
    if !use_in_memory_search_index && search_index_key.is_empty() {
        return Err(api_err(
            "auth",
            "Encrypted search index key is empty".to_string(),
        ));
    }
    let search_index_dir = if use_in_memory_search_index {
        sdk_dir.join("search_index")
    } else {
        prepare_encrypted_search_index(&sdk_dir, reset_search_index).await?
    };
    let index_store = if use_in_memory_search_index {
        matrix_sdk::search_index::SearchIndexStoreKind::InMemory
    } else {
        matrix_sdk::search_index::SearchIndexStoreKind::EncryptedDirectory(
            search_index_dir.clone(),
            search_index_key,
        )
    };
    let client = matrix_client_builder()?
        .handle_refresh_tokens()
        .homeserver_url(&context.homeserver_url)
        .with_encryption_settings(encryption_settings())
        .request_config(bounded_request_config())
        .search_index_store(index_store)
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
        .map_err(|e| api_err("auth", format!("恢复原设备数据库失败: {e}")))?;
    install_session_token_callback(&client)?;

    // Validate the response before activating the SDK's crypto store. Reusing
    // only a device ID with a newly initialized key store would lose trust.
    let mut request = Request::new(LoginInfo::Password(Password::new(
        UserIdentifier::Matrix(MatrixUserIdentifier::new(account_user_id.clone())),
        password,
    )));
    request.device_id = Some(context.meta.device_id.clone());
    request.refresh_token = true;
    let response = match client
        .send(request)
        .with_request_config(RequestConfig::short_retry())
        .await
    {
        Ok(response) => response,
        Err(error) => {
            return Ok(AuthResult {
                success: false,
                user_id: None,
                device_id: None,
                access_token: None,
                refresh_token: None,
                error: Some(friendly_auth_error(
                    &error.to_string(),
                    "重新认证失败，请稍后重试",
                )),
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
    };
    if response.user_id != context.meta.user_id || response.device_id != context.meta.device_id {
        return Err(api_err(
            "auth",
            "重新认证返回的账号或设备与原会话不一致。".to_string(),
        ));
    }
    client
        .matrix_auth()
        .restore_session((&response).into(), RoomLoadSettings::default())
        .await
        .map_err(|e| api_err("auth", format!("恢复原设备会话失败: {e}")))?;
    wait_for_e2ee_initialization(&client, "session reauthentication").await;
    let instance_id = NEXT_CLIENT_INSTANCE_ID.fetch_add(1, Ordering::Relaxed);
    let identity = ClientIdentity {
        user_id: account_user_id.clone(),
        instance_id,
    };
    install_verification_event_handler(&client, identity.clone());
    install_live_update_event_handlers(&client, identity.clone());
    desktop_notifications::install(&client, identity.clone()).await;
    let room_key_task = install_room_key_event_handler(&client, identity);
    drop(lifecycle);
    {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        let mut relogin = SESSION_RELOGIN.write().await;
        if ACTIVE_USER.read().await.is_some()
            || relogin
                .as_ref()
                .is_none_or(|pending| pending.instance_id != context.instance_id)
            || CLIENTS.read().await.contains_key(&account_user_id)
        {
            room_key_task.abort();
            return Err(api_err("auth", "账号状态已改变，请重试。".to_string()));
        }
        stop_sync_task(None, false).await;
        clear_account_runtime_state(&account_user_id).await;
        CLIENTS.write().await.insert(
            account_user_id.clone(),
            ClientEntry {
                client,
                data_dir: context.data_dir,
                search_index_dir,
                instance_id,
                room_key_task,
            },
        );
        *ACTIVE_USER.write().await = Some(account_user_id.clone());
        *relogin = None;
        reset_connection_status();
        set_subscription_user(Some(account_user_id)).await;
    }
    app_log(
        "info",
        "auth",
        "Original device session reauthenticated".to_string(),
    );
    Ok(AuthResult {
        success: true,
        user_id: Some(response.user_id.to_string()),
        device_id: Some(response.device_id.to_string()),
        access_token: Some(response.access_token),
        refresh_token: response.refresh_token,
        error: None,
        needs_uiaa: false,
        session: None,
        flows: None,
    })
}
