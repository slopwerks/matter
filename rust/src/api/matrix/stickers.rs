//! Stickers implementation.

use super::*;

pub(super) async fn send_sticker(
    room_id: String,
    image_url: String,
    body: String,
    mime_type: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;

    let room = client
        .get_room(
            &matrix_sdk::ruma::RoomId::parse(room_id.clone())
                .map_err(|e| api_err("rooms", format!("无效的房间 ID: {e}")))?,
        )
        .ok_or_else(|| api_err("rooms", format!("房间不存在: {room_id}")))?;

    let content_uri = matrix_sdk::ruma::OwnedMxcUri::try_from(image_url.trim())
        .map_err(|e| api_err("rooms", format!("Invalid sticker MXC URI: {e}")))?;

    let mut info = matrix_sdk::ruma::events::room::ImageInfo::new();
    if let Some(mime_type) = mime_type.filter(|value| !value.trim().is_empty()) {
        info.mimetype = Some(mime_type);
    }
    if let Some(width) = width.filter(|value| *value > 0) {
        info.width = matrix_sdk::ruma::UInt::new(width as u64);
    }
    if let Some(height) = height.filter(|value| *value > 0) {
        info.height = matrix_sdk::ruma::UInt::new(height as u64);
    }

    let label = body.trim();
    let content = matrix_sdk::ruma::events::sticker::StickerEventContent::new(
        if label.is_empty() {
            "贴纸".to_string()
        } else {
            label.to_string()
        },
        info,
        content_uri,
    );

    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send sticker message failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Sticker message sent to {}", room_id),
    );
    info!("Sticker message sent to {}", room_id);
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}
