//! Encryption recovery implementation.

use super::*;

pub(super) async fn get_encryption_recovery_info(
    account_user_id: Option<String>,
) -> Result<EncryptionRecoveryInfo, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("encryption", "No active client".to_string()))?;
    if let Some(user_id) = account_user_id.as_deref() {
        ensure_account_matches(&client, user_id)?;
    }
    Ok(encryption_recovery_info(&client))
}

pub(super) fn encryption_recovery_info(client: &Client) -> EncryptionRecoveryInfo {
    let state = match client.encryption().recovery().state() {
        RecoveryState::Unknown => "unknown",
        RecoveryState::Enabled => "enabled",
        RecoveryState::Disabled => "disabled",
        RecoveryState::Incomplete => "incomplete",
    };
    let device_verified = match client.encryption().verification_state().get() {
        OwnVerificationState::Unknown => None,
        OwnVerificationState::Verified => Some(true),
        OwnVerificationState::Unverified => Some(false),
    };
    EncryptionRecoveryInfo {
        state: state.into(),
        device_verified,
    }
}

pub(super) async fn recover_encryption(
    recovery_key_or_passphrase: String,
    account_user_id: Option<String>,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let value = recovery_key_or_passphrase.trim();
    if value.is_empty() {
        return Err(api_err(
            "encryption",
            "Recovery key or passphrase is empty".to_string(),
        ));
    }
    let client = get_client()
        .await
        .ok_or_else(|| api_err("encryption", "No active client".to_string()))?;
    if let Some(user_id) = account_user_id.as_deref() {
        ensure_account_matches(&client, user_id)?;
    }
    client
        .encryption()
        .recovery()
        .recover(value)
        .await
        .map_err(|e| {
            api_err(
                "encryption",
                format!("Failed to recover encryption data: {e}"),
            )
        })?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

pub(super) async fn enable_encryption_recovery(
    passphrase: Option<String>,
    account_user_id: Option<String>,
) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("encryption", "No active client".to_string()))?;
    if let Some(user_id) = account_user_id.as_deref() {
        ensure_account_matches(&client, user_id)?;
    }
    let recovery = client.encryption().recovery();
    if recovery.state() != RecoveryState::Disabled {
        return Err(api_err(
            "encryption",
            "恢复配置已存在或状态尚未确认，请先恢复已有密钥".to_string(),
        ));
    }
    let passphrase = passphrase
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let result = if let Some(passphrase) = passphrase.as_deref() {
        recovery
            .enable()
            .wait_for_backups_to_upload()
            .with_passphrase(passphrase)
            .await
    } else {
        recovery.enable().wait_for_backups_to_upload().await
    };
    result.map_err(|e| {
        api_err(
            "encryption",
            format!("Failed to enable encryption recovery: {e}"),
        )
    })
}
