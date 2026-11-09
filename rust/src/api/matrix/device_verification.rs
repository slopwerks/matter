//! Device verification implementation.

use super::*;

// ── Device verification & encryption recovery ─────────────────────
pub(super) fn active_session_meta(client: &Client) -> Result<(String, String), String> {
    let session = client
        .matrix_auth()
        .session()
        .ok_or_else(|| api_err("verification", "No active Matrix session".to_string()))?;
    Ok((
        session.meta.user_id.to_string(),
        session.meta.device_id.to_string(),
    ))
}

pub(super) async fn current_verification_session(
) -> Result<(ClientLease, VerificationSession), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("verification", "No active client".to_string()))?;
    let session = VERIFICATION_SESSION
        .read()
        .await
        .clone()
        .ok_or_else(|| api_err("verification", "No active verification".to_string()))?;
    Ok((client, session))
}

pub(super) async fn clear_verification_session() {
    *VERIFICATION_SESSION.write().await = None;
}

pub(super) async fn clear_verification_session_if(flow_id: &str) {
    let mut active = VERIFICATION_SESSION.write().await;
    if active
        .as_ref()
        .is_some_and(|session| session.flow_id == flow_id)
    {
        *active = None;
    }
}

pub(super) async fn list_own_devices() -> Result<Vec<VerificationDevice>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("verification", "No active client".to_string()))?;
    let (user_id, current_device_id) = active_session_meta(&client)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;

    // Refresh the identity first so the device list isn't limited to stale local data.
    client
        .encryption()
        .request_user_identity(&user_id)
        .await
        .map_err(|e| {
            api_err(
                "verification",
                format!("Failed to refresh encryption identity: {e}"),
            )
        })?;
    let devices = client
        .encryption()
        .get_user_devices(&user_id)
        .await
        .map_err(|e| api_err("verification", format!("Failed to load devices: {e}")))?;

    let mut result = devices
        .devices()
        .map(|device| VerificationDevice {
            device_id: device.device_id().to_string(),
            display_name: device.display_name().unwrap_or("未命名设备").to_string(),
            is_current: device.device_id().as_str() == current_device_id,
            is_verified: device.is_verified(),
        })
        .collect::<Vec<_>>();
    result.sort_by_key(|device| (!device.is_current, device.display_name.to_lowercase()));
    Ok(result)
}

pub(super) async fn list_account_devices() -> Result<Vec<AccountDevice>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("devices", "No active client".to_string()))?;
    let (_, current_device_id) = active_session_meta(&client)?;
    let response = client
        .devices()
        .await
        .map_err(|e| api_err("devices", format!("Failed to load device sessions: {e}")))?;

    let mut devices = response
        .devices
        .into_iter()
        .map(|device| AccountDevice {
            device_id: device.device_id.to_string(),
            display_name: device.display_name,
            last_seen_ip: device.last_seen_ip,
            last_seen_ts: device.last_seen_ts.map(|ts| i64::from(ts.get())),
            is_current: device.device_id.as_str() == current_device_id,
        })
        .collect::<Vec<_>>();
    sort_account_devices(&mut devices);
    Ok(devices)
}

pub(super) async fn rename_account_device(
    device_id: String,
    display_name: String,
) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("devices", "No active client".to_string()))?;
    let device_id = matrix_sdk::ruma::OwnedDeviceId::from(device_id);
    client
        .rename_device(&device_id, display_name.trim())
        .await
        .map_err(|e| api_err("devices", format!("Failed to rename device: {e}")))?;
    Ok(())
}

/// The current device first, then the most recently active sessions.
pub(super) fn sort_account_devices(devices: &mut [AccountDevice]) {
    devices.sort_by(|a, b| {
        b.is_current.cmp(&a.is_current).then(
            b.last_seen_ts
                .unwrap_or_default()
                .cmp(&a.last_seen_ts.unwrap_or_default()),
        )
    });
}

pub(super) async fn start_device_verification(device_id: String) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("verification", "No active client".to_string()))?;
    let (user_id, current_device_id) = active_session_meta(&client)?;
    if device_id == current_device_id {
        return Err(api_err(
            "verification",
            "Cannot verify the current device with itself".to_string(),
        ));
    }
    let user_id = matrix_sdk::ruma::UserId::parse(user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;
    let device_id = matrix_sdk::ruma::OwnedDeviceId::from(device_id);
    let device = client
        .encryption()
        .get_device(&user_id, &device_id)
        .await
        .map_err(|e| api_err("verification", format!("Failed to load device: {e}")))?
        .ok_or_else(|| api_err("verification", "Device is no longer available".to_string()))?;
    let request = device
        .request_verification_with_methods(vec![VerificationMethod::SasV1])
        .await
        .map_err(|e| {
            api_err(
                "verification",
                format!("Failed to request verification: {e}"),
            )
        })?;

    *VERIFICATION_SESSION.write().await = Some(VerificationSession {
        user_id: user_id.to_string(),
        device_id: device_id.to_string(),
        flow_id: request.flow_id().to_string(),
        incoming: false,
        accepted: true,
    });
    Ok(())
}

pub(super) async fn accept_device_verification() -> Result<(), String> {
    let (client, session) = current_verification_session().await?;
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;
    let request = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await
        .ok_or_else(|| {
            api_err(
                "verification",
                "Verification request is no longer available".to_string(),
            )
        })?;
    request
        .accept_with_methods(vec![VerificationMethod::SasV1])
        .await
        .map_err(|e| {
            api_err(
                "verification",
                format!("Failed to accept verification: {e}"),
            )
        })?;
    if let Some(active) = VERIFICATION_SESSION.write().await.as_mut() {
        active.accepted = true;
    }
    Ok(())
}

pub(super) async fn get_device_verification_status(
) -> Result<Option<DeviceVerificationStatus>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("verification", "No active client".to_string()))?;
    let Some(session) = VERIFICATION_SESSION.read().await.clone() else {
        return Ok(None);
    };
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;

    let request = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await;

    if session.accepted {
        if let Some(request) = request.as_ref() {
            if request.is_ready() && request.we_started() {
                request.start_sas().await.map_err(|e| {
                    api_err(
                        "verification",
                        format!("Failed to start emoji verification: {e}"),
                    )
                })?;
            }
        }
    }

    let verification = client
        .encryption()
        .get_verification(&user_id, &session.flow_id)
        .await;

    if let Some(Verification::SasV1(sas)) = verification {
        if session.accepted
            && !sas.can_be_presented()
            && !sas.is_done()
            && sas.cancel_info().is_none()
        {
            sas.accept().await.map_err(|e| {
                api_err(
                    "verification",
                    format!("Failed to accept emoji verification: {e}"),
                )
            })?;
        }
        if sas.is_done() {
            return Ok(Some(DeviceVerificationStatus {
                phase: "done".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: vec![],
                message: "Verification completed".into(),
            }));
        }
        if let Some(cancel) = sas.cancel_info() {
            clear_verification_session_if(&session.flow_id).await;
            return Ok(Some(DeviceVerificationStatus {
                phase: "cancelled".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: vec![],
                message: cancel.reason().to_string(),
            }));
        }
        if let Some(emojis) = sas.emoji() {
            return Ok(Some(DeviceVerificationStatus {
                phase: "comparing".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: emojis
                    .into_iter()
                    .map(|emoji| VerificationEmoji {
                        symbol: emoji.symbol.to_string(),
                        description: emoji.description.to_string(),
                    })
                    .collect(),
                message: "Compare the emoji on both devices".into(),
            }));
        }
    }

    let (phase, message) = match request.map(|request| request.state()) {
        Some(VerificationRequestState::Requested { .. }) if !session.accepted => {
            ("requested", "A device wants to verify this device")
        }
        Some(VerificationRequestState::Created { .. }) => {
            ("waiting", "Waiting for the other device")
        }
        Some(VerificationRequestState::Ready { .. }) => ("starting", "Starting emoji verification"),
        Some(VerificationRequestState::Transitioned { .. }) => {
            ("starting", "Preparing emoji comparison")
        }
        Some(VerificationRequestState::Done) => {
            return Ok(Some(DeviceVerificationStatus {
                phase: "done".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: vec![],
                message: "Verification completed".into(),
            }));
        }
        Some(VerificationRequestState::Cancelled(cancel)) => {
            clear_verification_session_if(&session.flow_id).await;
            return Ok(Some(DeviceVerificationStatus {
                phase: "cancelled".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: vec![],
                message: cancel.reason().to_string(),
            }));
        }
        None => {
            // The SDK no longer knows this flow. Keeping the local session here
            // creates a permanent ghost verification that cannot be cancelled.
            clear_verification_session_if(&session.flow_id).await;
            return Ok(None);
        }
        _ => ("waiting", "Waiting for verification events"),
    };

    Ok(Some(DeviceVerificationStatus {
        phase: phase.into(),
        device_id: session.device_id,
        flow_id: session.flow_id,
        incoming: session.incoming,
        emojis: vec![],
        message: message.into(),
    }))
}

pub(super) async fn confirm_device_verification() -> Result<(), String> {
    let (client, session) = current_verification_session().await?;
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;
    let sas = client
        .encryption()
        .get_verification(&user_id, &session.flow_id)
        .await
        .and_then(Verification::sas)
        .ok_or_else(|| {
            api_err(
                "verification",
                "Emoji verification is not ready".to_string(),
            )
        })?;
    sas.confirm().await.map_err(|e| {
        api_err(
            "verification",
            format!("Failed to confirm verification: {e}"),
        )
    })?;

    // Confirmation is sent before the other device's MAC/done event arrives.
    // Wait briefly so callers can refresh the verified-device state immediately.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(8);
    while !sas.is_done() && sas.cancel_info().is_none() {
        if tokio::time::Instant::now() >= deadline {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    Ok(())
}

pub(super) async fn cancel_device_verification(mismatch: bool) -> Result<(), String> {
    let (client, session) = current_verification_session().await?;
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;
    if let Some(sas) = client
        .encryption()
        .get_verification(&user_id, &session.flow_id)
        .await
        .and_then(Verification::sas)
    {
        if mismatch {
            sas.mismatch().await
        } else {
            sas.cancel().await
        }
        .map_err(|e| {
            api_err(
                "verification",
                format!("Failed to cancel verification: {e}"),
            )
        })?;
    } else if let Some(request) = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await
    {
        request.cancel().await.map_err(|e| {
            api_err(
                "verification",
                format!("Failed to cancel verification: {e}"),
            )
        })?;
    }
    clear_verification_session_if(&session.flow_id).await;
    Ok(())
}
