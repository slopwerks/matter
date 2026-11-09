//! Auth login implementation.

use super::*;

pub(super) async fn login_with_password(
    username: String,
    password: String,
) -> Result<AuthResult, String> {
    app_log(
        "info",
        "auth",
        format!("login_with_password: user={}", username),
    );
    let client = get_pending_client().await.ok_or_else(|| {
        api_err(
            "auth",
            "No client created. Call create_client first.".to_string(),
        )
    })?;

    let started = std::time::Instant::now();
    let login_result = client
        .matrix_auth()
        .login_username(&username, &password)
        .request_refresh_token()
        .initial_device_display_name(&get_initial_device_name())
        .await;
    match login_result {
        Ok(response) => {
            let request_elapsed_ms = started.elapsed().as_millis();
            app_log(
                "info",
                "auth",
                format!(
                    "Password login response accepted for {} after {} ms; \
                     device={}, starting local finalization",
                    response.user_id, request_elapsed_ms, response.device_id,
                ),
            );
            // Auto-finalize: migrate pending client to per-user store
            drop(client);
            let finalization_started = std::time::Instant::now();
            let finalized = finalize_pending().await.map_err(|e| {
                api_err(
                    "auth",
                    format!(
                        "Password login local finalization failed after {} ms: {e}",
                        finalization_started.elapsed().as_millis(),
                    ),
                )
            })?;
            app_log(
                "info",
                "auth",
                format!(
                    "Account finalized after password login: {} \
                     (request={} ms, finalization={} ms)",
                    finalized,
                    request_elapsed_ms,
                    finalization_started.elapsed().as_millis(),
                ),
            );
            info!("Account finalized after password login: {}", finalized);
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
        Err(e) => {
            let raw_error = format!("{e}");
            let friendly_error = friendly_auth_error(&raw_error, "登录失败，请稍后重试");
            app_log(
                "error",
                "auth",
                format!(
                    "Password login request or local SDK activation failed after {} ms: {}",
                    started.elapsed().as_millis(),
                    friendly_error,
                ),
            );
            Ok(AuthResult {
                success: false,
                user_id: None,
                device_id: None,
                access_token: None,
                refresh_token: None,
                error: Some(friendly_error),
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
    }
}

pub(super) async fn login_with_token(
    access_token: String,
    user_id: String,
    device_id: String,
    refresh_token: Option<String>,
) -> Result<AuthResult, String> {
    let client = get_pending_client().await.ok_or_else(|| {
        api_err(
            "auth",
            "No client created. Call create_client first.".to_string(),
        )
    })?;

    let parsed_user_id = matrix_sdk::ruma::UserId::parse(&user_id).map_err(|e| {
        api_err(
            "auth",
            friendly_auth_error(&format!("无效的用户 ID: {e}"), "用户 ID 格式无效"),
        )
    })?;
    // Imported credentials belong to an existing server session. Reject a
    // duplicate before restore/finalization, whose cleanup logs out newly
    // created password sessions and must never revoke an imported token.
    if CLIENTS.read().await.contains_key(&user_id) {
        return Err(api_err(
            "auth",
            "该账号已登录，请返回设置切换账号".to_string(),
        ));
    }
    let parsed_device_id = matrix_sdk::ruma::OwnedDeviceId::from(device_id);

    let session = MatrixSession {
        meta: SessionMeta {
            user_id: parsed_user_id,
            device_id: parsed_device_id,
        },
        tokens: SessionTokens {
            access_token,
            refresh_token,
        },
    };

    client
        .matrix_auth()
        .restore_session(session, RoomLoadSettings::default())
        .await
        .map_err(|e| {
            api_err(
                "auth",
                friendly_auth_error(
                    &format!("Restore session failed: {e}"),
                    "Token 登录失败，请检查输入信息",
                ),
            )
        })?;

    drop(client);
    let finalized_user = finalize_pending().await.map_err(|e| {
        let raw = format!("Finalization failed after token login: {e}");
        app_log("error", "auth", raw.clone());
        friendly_auth_error(&raw, "Token 登录失败，请稍后重试")
    })?;
    app_log(
        "info",
        "auth",
        format!("Account finalized after token login: {}", finalized_user),
    );
    info!("Account finalized after token login: {}", finalized_user);

    let final_client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "Token 登录成功，但无法获取最终会话".to_string()))?;

    Ok(AuthResult {
        success: true,
        user_id: final_client.user_id().map(|u| u.to_string()),
        device_id: final_client.device_id().map(|d| d.to_string()),
        access_token: None,
        refresh_token: final_client
            .matrix_auth()
            .session()
            .and_then(|session| session.tokens.refresh_token),
        error: None,
        needs_uiaa: false,
        session: None,
        flows: None,
    })
}

pub(super) async fn is_logged_in() -> bool {
    if let Some(client) = get_client().await {
        client.matrix_auth().logged_in()
    } else {
        false
    }
}

pub(super) async fn get_current_user_id() -> Option<String> {
    if let Some(client) = get_client().await {
        client.user_id().map(|u| u.to_string())
    } else {
        None
    }
}

pub(super) async fn get_active_user_id() -> Option<String> {
    let active = ACTIVE_USER.read().await;
    active.clone()
}
