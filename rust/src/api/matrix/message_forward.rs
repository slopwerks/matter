//! Message forward implementation.

use super::*;

pub(super) async fn forward_message(
    source_room_id: String,
    target_room_id: String,
    event_id: String,
    text: FormattedMessageInput,
) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let source_room = get_room_by_id(&client, &source_room_id)?;
    let target_room = get_room_by_id(&client, &target_room_id)?;
    let event_id = matrix_sdk::ruma::EventId::parse(event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;
    let timeline_event = source_room
        .event(&event_id, None)
        .await
        .map_err(|e| api_err("rooms", format!("Load message failed: {e}")))?;

    if timeline_event.kind.is_utd() {
        return Err(api_err("rooms", "无法转发未解密的消息".to_string()));
    }

    let event = timeline_event
        .raw()
        .deserialize()
        .map_err(|e| api_err("rooms", format!("Read message failed: {e}")))?;

    let event_id = match event {
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(message),
        ) => {
            let Some(original) = message.as_original() else {
                return Err(api_err("rooms", "无法转发已撤回的消息".to_string()));
            };
            let mut content = original.content.clone();
            let media_caption = text.body.clone();
            if matches!(
                &content.msgtype,
                matrix_sdk::ruma::events::room::message::MessageType::Text(_)
            ) {
                content = build_text_content(text)?;
            } else {
                content.relates_to = None;
            }
            let mut shared_caption = if matches!(
                &content.msgtype,
                matrix_sdk::ruma::events::room::message::MessageType::Image(_)
            ) {
                timeline_event
                    .raw()
                    .deserialize_as::<serde_json::Value>()
                    .ok()
                    .and_then(|event| image_caption::shared_caption(&event))
            } else {
                None
            };
            let mut metadata = timeline_event
                .raw()
                .deserialize_as::<serde_json::Value>()
                .ok()
                .and_then(|event| image_caption::metadata(&event));
            if let matrix_sdk::ruma::events::room::message::MessageType::Image(image) =
                &mut content.msgtype
            {
                if image.caption().is_none() {
                    if shared_caption.is_none()
                        && !media_caption.trim().is_empty()
                        && media_caption != image.filename()
                    {
                        shared_caption = Some(media_caption.clone());
                    }
                    if shared_caption.is_none() {
                        if let Some(root) = metadata
                            .as_ref()
                            .and_then(|metadata| metadata.album_root.as_deref())
                        {
                            let root = matrix_sdk::ruma::EventId::parse(root)
                                .map_err(|error| api_err("media", error.to_string()))?;
                            shared_caption = image_caption::album_caption(&source_room, &root)
                                .await
                                .map_err(|error| api_err("media", error))?;
                        }
                    }
                    if let Some(caption) = &shared_caption {
                        image.filename = Some(image.body.clone());
                        image.body = caption.clone();
                        image.formatted = None;
                    }
                }
            }
            if let Some(metadata) = &mut metadata {
                metadata.album_root = None;
            }
            let content = image_caption::with_captions(content, None, None)?;
            let content = image_caption::with_metadata(content, metadata.as_ref())?;
            target_room
                .send_raw("m.room.message", content)
                .await
                .map_err(|e| api_err("rooms", format!("Forward failed: {e}")))?
                .response
                .event_id
                .to_string()
        }
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::Sticker(sticker),
        ) => {
            let Some(original) = sticker.as_original() else {
                return Err(api_err("rooms", "无法转发已撤回的贴纸".to_string()));
            };
            let mut content = original.content.clone();
            content.relates_to = None;
            target_room
                .send(content)
                .await
                .map_err(|e| api_err("rooms", format!("Forward failed: {e}")))?
                .response
                .event_id
                .to_string()
        }
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollStart(poll),
        ) => {
            let Some(original) = poll.as_original() else {
                return Err(api_err("rooms", "无法转发已撤回的投票".to_string()));
            };
            let content = poll_start_for_forward(&original.content)?;
            target_room
                .send(content)
                .await
                .map_err(|e| api_err("rooms", format!("Forward failed: {e}")))?
                .response
                .event_id
                .to_string()
        }
        _ => return Err(api_err("rooms", "该消息类型暂不支持转发".to_string())),
    };

    app_log(
        "info",
        "rooms",
        format!("Message forwarded to {}", target_room_id),
    );
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: target_room_id,
        },
    );
    Ok(event_id)
}
