//! History api implementation.

use super::*;

pub(super) async fn get_messages_around(
    room_id: String,
    event_id: String,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    run_bounded(
        async move { sdk_timeline::get_messages_around(&room, &event_id, limit as usize).await },
    )
    .await
}

pub(super) async fn get_messages_before(
    room_id: String,
    from_event_id: String,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    // Bounded like the other P0 calls: pagination holds the client lease.
    run_bounded(async move {
        sdk_timeline::get_messages_before(&client, &room, &from_event_id, limit).await
    })
    .await
}

pub(super) async fn get_messages_after(
    room_id: String,
    from_event_id: String,
    limit: u32,
) -> Result<history::HistoryPage, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    run_bounded(async move { history::messages_after(&room, &from_event_id, limit).await }).await
}
