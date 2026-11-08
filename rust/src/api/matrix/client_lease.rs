//! Client lease implementation.

use super::*;

/// Return the currently active client, or the pending one if no account is
/// active yet. The lease keeps account removal/replacement from dropping its
/// SQLite store while any API call still holds the Client or a derived Room.
pub(in crate::api) async fn get_client() -> Option<ClientLease> {
    let lifecycle = SYNC_LIFECYCLE.read().await;
    let active = ACTIVE_USER.read().await;
    let client = if let Some(user_id) = active.as_ref() {
        let clients = CLIENTS.read().await;
        clients.get(user_id).map(|e| e.client.clone())
    } else {
        PENDING.read().await.as_ref().map(|p| p.client.clone())
    }?;
    Some(ClientLease {
        client,
        lifecycle: Arc::new(lifecycle),
    })
}

/// Authentication must use the pending client even while another account is active.
pub(super) async fn get_pending_client() -> Option<ClientLease> {
    let lifecycle = SYNC_LIFECYCLE.read().await;
    let client = PENDING.read().await.as_ref()?.client.clone();
    Some(ClientLease {
        client,
        lifecycle: Arc::new(lifecycle),
    })
}
