//! Message actions implementation.

use super::*;

pub(super) async fn send_reply(
    account_user_id: String,
    room_id: String,
    message: FormattedMessageInput,
    reply_to_event_id: String,
    reply_to_user_id: Option<String>,
) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    // Parse the event ID we're replying to
    let event_id = matrix_sdk::ruma::EventId::parse(&reply_to_event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;

    let mut reply_content = build_text_content(message)?;
    if let Some(reply_to_user_id) = reply_to_user_id {
        let reply_to_user_id = matrix_sdk::ruma::UserId::parse(&reply_to_user_id)
            .map_err(|e| api_err("rooms", format!("Invalid reply user ID: {e}")))?;
        reply_content
            .mentions
            .get_or_insert_with(matrix_sdk::ruma::events::Mentions::new)
            .user_ids
            .insert(reply_to_user_id);
    }
    reply_content.relates_to = Some(matrix_sdk::ruma::events::room::message::Relation::Reply(
        matrix_sdk::ruma::events::relation::Reply::with_event_id(event_id),
    ));

    let response = room
        .send(reply_content)
        .await
        .map_err(|e| api_err("rooms", format!("Reply failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Reply sent to {} in room {}", reply_to_event_id, room_id),
    );
    info!("Reply sent to {} in room {}", reply_to_event_id, room_id);
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(response.response.event_id.to_string())
}

pub(super) async fn edit_message(
    account_user_id: String,
    room_id: String,
    event_id: String,
    message: FormattedMessageInput,
    previous_mentioned_user_ids: Vec<String>,
    previous_mentions_room: bool,
) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;

    use matrix_sdk::ruma::events::room::message::ReplacementMetadata;
    let previous_mentions = build_mentions(&previous_mentioned_user_ids, previous_mentions_room)?;
    let content = build_text_content(message)?.make_replacement(ReplacementMetadata::new(
        parsed_event_id,
        Some(previous_mentions),
    ));

    let response = room
        .send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Edit failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Edited event {} in room {}", event_id, room_id),
    );
    info!("Edited event {} in room {}", event_id, room_id);
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(response.response.event_id.to_string())
}

pub(super) async fn toggle_reaction(
    account_user_id: String,
    room_id: String,
    event_id: String,
    key: String,
) -> Result<ChatMessage, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;
    let message = sdk_timeline::toggle_reaction(&client, &room, parsed_event_id, &key).await?;
    notify_sync_event_for_generation(generation, SyncEvent::MessageSent { room_id });
    Ok(message)
}

pub(super) async fn redact_message(
    account_user_id: String,
    room_id: String,
    event_id: String,
    reason: Option<String>,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;

    room.redact(&parsed_event_id, reason.as_deref(), None)
        .await
        .map_err(|e| api_err("rooms", format!("Redact failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Redacted event {} in room {}", event_id, room_id),
    );
    info!("Redacted event {} in room {}", event_id, room_id);
    notify_sync_event_for_generation(generation, SyncEvent::MessageRedacted { room_id, event_id });
    Ok(())
}

pub(super) async fn send_typing_notice(
    account_user_id: String,
    room_id: String,
    typing: bool,
) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("typing", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    room.typing_notice(typing)
        .await
        .map_err(|e| api_err("typing", format!("Typing notice failed: {e}")))?;
    Ok(())
}
