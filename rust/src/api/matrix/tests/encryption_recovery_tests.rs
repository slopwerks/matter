use super::*;

#[tokio::test]
async fn an_uninitialized_client_has_unknown_encryption_status() {
    let client = Client::builder()
        .homeserver_url("https://example.org")
        .build()
        .await
        .unwrap();
    let info = encryption_recovery_info(&client);
    assert_eq!(info.state, "unknown");
    assert_eq!(info.device_verified, None);
}
