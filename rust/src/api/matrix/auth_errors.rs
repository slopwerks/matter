//! Auth errors implementation.

use super::*;

// ── Internal helpers ─────────────────────────────────────────────────
/// Try to extract UIAA info from a register error via structured SDK APIs.
pub(super) fn try_extract_uiaa(err: &matrix_sdk::Error) -> Option<AuthResult> {
    if let Some(uiaa_info) = err.as_uiaa_response() {
        info!("UIAA extracted via err.as_uiaa_response()");
        return Some(uiaa_to_auth_result(uiaa_info));
    }

    if let matrix_sdk::Error::Http(http_err) = err {
        if let Some(uiaa_info) = http_err.as_uiaa_response() {
            info!("UIAA extracted via http_err.as_uiaa_response()");
            return Some(uiaa_to_auth_result(uiaa_info));
        }
    }

    None
}

pub(super) fn truncate_utf8(value: &str, max_bytes: usize) -> &str {
    let mut end = value.len().min(max_bytes);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}

pub(super) fn try_parse_uiaa_from_string(err_str: &str) -> Option<AuthResult> {
    let json_start = err_str
        .find("[401]")
        .and_then(|pos| err_str[pos + 5..].find('{').map(|p| pos + 5 + p))?;
    let json_str = &err_str[json_start..];

    let val: serde_json::Value = serde_json::from_str(json_str).ok()?;

    let has_reg_token = val
        .get("flows")
        .and_then(|f| f.as_array())
        .is_some_and(|flows| {
            flows.iter().any(|flow| {
                flow.get("stages")
                    .and_then(|s| s.as_array())
                    .is_some_and(|stages| {
                        stages
                            .iter()
                            .any(|s| s.as_str() == Some("m.login.registration_token"))
                    })
            })
        });

    if !has_reg_token {
        return None;
    }

    let session = val
        .get("session")
        .and_then(|s| s.as_str())
        .map(|s| s.to_string());

    if session.is_some() {
        info!("UIAA parsed from error string JSON, session found");
        Some(AuthResult {
            success: false,
            user_id: None,
            device_id: None,
            access_token: None,
            refresh_token: None,
            error: None,
            needs_uiaa: true,
            session,
            flows: Some("m.login.registration_token".to_string()),
        })
    } else {
        warn!(
            "UIAA JSON found but no session: {}",
            truncate_utf8(err_str, 500)
        );
        None
    }
}

pub(super) fn uiaa_to_auth_result(uiaa_info: &UiaaInfo) -> AuthResult {
    let session = uiaa_info.session.clone();
    let flows_json = serde_json::to_string(&uiaa_info.flows).ok();

    AuthResult {
        success: false,
        user_id: None,
        device_id: None,
        access_token: None,
        refresh_token: None,
        error: None,
        needs_uiaa: true,
        session,
        flows: flows_json,
    }
}

pub(super) fn get_room_by_id(client: &Client, room_id: &str) -> Result<Room, String> {
    let parsed_room_id = matrix_sdk::ruma::RoomId::parse(room_id)
        .map_err(|e| api_err("rooms", format!("Invalid room ID: {e}")))?;
    client
        .get_room(parsed_room_id.as_ref())
        .ok_or_else(|| api_err("rooms", format!("房间不存在: {room_id}")))
}

pub(super) fn friendly_auth_error(raw: &str, fallback: &str) -> String {
    let text = raw.to_lowercase();

    if text.contains("timed out") || text.contains("timeout") {
        return "连接超时，请检查网络或服务器地址".to_string();
    }

    if text.contains("network")
        || text.contains("socket")
        || text.contains("dns")
        || text.contains("connection refused")
        || text.contains("tls")
    {
        return "无法连接到服务器，请检查网络或 Homeserver 地址".to_string();
    }

    if text.contains("401")
        || text.contains("403")
        || text.contains("forbidden")
        || text.contains("unauthorized")
        || text.contains("invalid password")
        || text.contains("unknown token")
        || text.contains("access denied")
        || text.contains("m_forbidden")
    {
        return "认证失败，请检查账号、密码或 Token".to_string();
    }

    if text.contains("registration token")
        || text.contains("m.login.registration_token")
        || text.contains("missing token")
        || text.contains("invalid token")
    {
        return "注册需要有效的注册 Token".to_string();
    }

    if text.contains("already signed in") {
        return "该账号已登录，请返回设置切换账号".to_string();
    }

    if text.contains("user id") && text.contains("invalid") {
        return "用户 ID 格式无效".to_string();
    }

    if text.contains("no client created") {
        return "客户端初始化失败，请重试".to_string();
    }

    fallback.to_string()
}
