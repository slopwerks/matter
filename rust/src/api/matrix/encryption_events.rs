//! Encryption events implementation.

use super::*;

pub(super) fn encryption_settings() -> EncryptionSettings {
    EncryptionSettings {
        backup_download_strategy: BackupDownloadStrategy::AfterDecryptionFailure,
        ..Default::default()
    }
}

pub(super) async fn wait_for_e2ee_initialization(client: &Client, context: &str) {
    client
        .encryption()
        .wait_for_e2ee_initialization_tasks()
        .await;
    app_log(
        "info",
        "encryption",
        format!("E2EE initialization completed after {context}"),
    );
}

pub(super) fn install_room_key_event_handler(
    client: &Client,
    identity: ClientIdentity,
) -> JoinHandle<()> {
    let client = client.clone();
    tokio::spawn(async move {
        let Some(mut stream) = client.encryption().room_keys_received_stream().await else {
            app_log(
                "warn",
                "encryption",
                "Room-key stream unavailable; encrypted history may need a restart to refresh"
                    .to_string(),
            );
            return;
        };

        use futures_util::StreamExt;
        while let Some(update) = stream.next().await {
            match update {
                Ok(keys) => {
                    if keys.is_empty() {
                        continue;
                    }
                    let rooms = keys
                        .iter()
                        .map(|key| key.room_id.to_string())
                        .collect::<BTreeSet<_>>();
                    app_log(
                        "info",
                        "encryption",
                        format!(
                            "Received {} room keys for {} rooms; refreshing affected timelines",
                            keys.len(),
                            rooms.len()
                        ),
                    );
                    for room_id in rooms {
                        notify_sync_event_for_client(&identity, SyncEvent::MessageSent { room_id })
                            .await;
                    }
                }
                Err(error) => {
                    app_log(
                        "warn",
                        "encryption",
                        format!(
                            "Room-key stream lagged ({error}); refreshing visible encrypted timelines"
                        ),
                    );
                    notify_sync_event_for_client(&identity, SyncEvent::SyncCompleted).await;
                }
            }
        }
    })
}
