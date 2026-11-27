//! Stickers implementation.

use super::*;

#[allow(clippy::too_many_arguments)]
pub(super) async fn send_sticker(
    account_user_id: String,
    room_id: String,
    image_url: String,
    body: String,
    mime_type: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
    reply_to_event_id: Option<String>,
    reply_to_user_id: Option<String>,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;

    ensure_account_matches(&client, &account_user_id)?;
    let room = client
        .get_room(
            &matrix_sdk::ruma::RoomId::parse(room_id.clone())
                .map_err(|e| api_err("rooms", format!("无效的房间 ID: {e}")))?,
        )
        .ok_or_else(|| api_err("rooms", format!("房间不存在: {room_id}")))?;

    let content_uri = matrix_sdk::ruma::OwnedMxcUri::from(image_url.trim());

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

    let content = sticker_reply_content(
        content,
        reply_to_event_id.as_deref(),
        reply_to_user_id.as_deref(),
    )?;

    // Keep the SDK send path: send_raw encrypts the event content in encrypted rooms.
    room.send_raw("m.sticker", content)
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

fn sticker_reply_content(
    content: matrix_sdk::ruma::events::sticker::StickerEventContent,
    reply_to_event_id: Option<&str>,
    reply_to_user_id: Option<&str>,
) -> Result<serde_json::Value, String> {
    let content = serde_json::to_value(content).map_err(|error| error.to_string())?;
    image_caption::with_reply(content, reply_to_event_id, reply_to_user_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::events::{room::ImageInfo, sticker::StickerEventContent};
    use serde_json::json;

    fn sticker() -> StickerEventContent {
        let mut info = ImageInfo::new();
        info.mimetype = Some("image/webp".into());
        info.width = matrix_sdk::ruma::UInt::new(128);
        info.height = matrix_sdk::ruma::UInt::new(64);
        StickerEventContent::new(
            "Wave".into(),
            info,
            matrix_sdk::ruma::OwnedMxcUri::from("mxc://example.org/sticker"),
        )
    }

    #[test]
    fn sticker_reply_has_standard_relation_and_mention_only() {
        let original = serde_json::to_value(sticker()).unwrap();
        let mut reply = sticker_reply_content(
            sticker(),
            Some("$original:example.org"),
            Some("@alice:example.org"),
        )
        .unwrap();
        assert_eq!(
            reply["m.relates_to"],
            json!({
                "m.in_reply_to": {"event_id": "$original:example.org"}
            })
        );
        assert_eq!(
            reply["m.mentions"],
            json!({"user_ids": ["@alice:example.org"]})
        );
        reply.as_object_mut().unwrap().remove("m.relates_to");
        reply.as_object_mut().unwrap().remove("m.mentions");
        assert_eq!(reply, original);
        assert!(reply.get("msgtype").is_none());
    }

    #[test]
    fn sticker_without_reply_is_unchanged() {
        assert_eq!(
            sticker_reply_content(sticker(), None, None).unwrap(),
            serde_json::to_value(sticker()).unwrap()
        );
        assert_eq!(
            sticker_reply_content(sticker(), None, Some("@alice:example.org")).unwrap(),
            serde_json::to_value(sticker()).unwrap()
        );
    }

    #[test]
    fn sticker_reply_accepts_missing_recipient_and_rejects_invalid_ids() {
        let reply = sticker_reply_content(sticker(), Some("$original:example.org"), None).unwrap();
        assert_eq!(
            reply["m.relates_to"]["m.in_reply_to"]["event_id"],
            "$original:example.org"
        );
        assert!(reply.get("m.mentions").is_none());
        assert!(sticker_reply_content(sticker(), Some("invalid"), None).is_err());
        assert!(
            sticker_reply_content(sticker(), Some("$original:example.org"), Some("invalid"))
                .is_err()
        );
    }
}
