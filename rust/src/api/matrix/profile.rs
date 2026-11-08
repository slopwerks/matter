//! Profile implementation.

use super::*;

pub(super) async fn get_profile() -> Result<UserProfile, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "No client created.".to_string()))?;
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("auth", "Not logged in.".to_string()))?;

    let account = client.account();
    let display_name = account
        .get_display_name()
        .await
        .map_err(|e| {
            report_session_error(&e);
            api_err("auth", format!("Failed to fetch display name: {e}"))
        })?
        .unwrap_or_default();
    let avatar_url = account
        .get_avatar_url()
        .await
        .map_err(|e| {
            report_session_error(&e);
            api_err("auth", format!("Failed to fetch avatar: {e}"))
        })?
        .map(|u| u.to_string());

    Ok(UserProfile {
        user_id: user_id.to_string(),
        display_name,
        avatar_url,
    })
}

pub(super) async fn set_display_name(name: String) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "No client created.".to_string()))?;
    let account = client.account();
    let trimmed = name.trim();
    account
        .set_display_name(if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        })
        .await
        .map_err(|e| api_err("auth", format!("Failed to set display name: {e}")))?;
    Ok(())
}

pub(super) async fn set_avatar_url(mxc: String) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "No client created.".to_string()))?;
    let account = client.account();
    let trimmed = mxc.trim();
    if trimmed.is_empty() {
        account
            .set_avatar_url(None)
            .await
            .map_err(|e| api_err("auth", format!("Failed to remove avatar: {e}")))?;
    } else {
        use std::convert::TryFrom;
        let mxc_uri = matrix_sdk::ruma::OwnedMxcUri::try_from(trimmed)
            .map_err(|e| api_err("auth", format!("Invalid mxc URI: {e}")))?;
        account
            .set_avatar_url(Some(&mxc_uri))
            .await
            .map_err(|e| api_err("auth", format!("Failed to set avatar: {e}")))?;
    }
    Ok(())
}

pub(super) async fn upload_avatar(content_type: String, data: Vec<u8>) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "No client created.".to_string()))?;
    let account = client.account();
    let mime: mime::Mime = content_type.parse().map_err(|e| {
        api_err(
            "auth",
            format!("Invalid content type '{content_type}': {e}"),
        )
    })?;
    let mxc = account
        .upload_avatar(&mime, data)
        .await
        .map_err(|e| api_err("auth", format!("Failed to upload avatar: {e}")))?;
    Ok(mxc.to_string())
}
