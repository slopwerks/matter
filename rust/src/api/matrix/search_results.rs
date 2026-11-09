//! Search results implementation.

use super::*;

pub(super) fn insert_latest_search_result(
    results: &mut HashMap<(String, String), (MessageSearchResult, u64, String)>,
    result: MessageSearchResult,
    source_timestamp: u64,
    source_event_id: String,
) {
    let key = (result.room_id.clone(), result.event_id.clone());
    match results.entry(key) {
        std::collections::hash_map::Entry::Vacant(entry) => {
            entry.insert((result, source_timestamp, source_event_id));
        }
        std::collections::hash_map::Entry::Occupied(mut entry) => {
            let current = entry.get();
            let is_newer = source_timestamp > current.1
                || (source_timestamp == current.1
                    && (result.is_edited && !current.0.is_edited
                        || (result.is_edited == current.0.is_edited
                            && source_event_id > current.2)));
            if is_newer {
                entry.insert((result, source_timestamp, source_event_id));
            }
        }
    }
}

pub(super) async fn search_result_from_event(
    client: &Client,
    room: &Room,
    event: matrix_sdk::deserialized_responses::TimelineEvent,
    terms: &[String],
    ignored_user_ids: Option<&HashSet<String>>,
    is_dm: bool,
    sender_names: &search_hydration::SenderNames,
) -> Option<(MessageSearchResult, u64, String)> {
    if event.kind.is_utd() {
        return None;
    }
    let event = event.raw().deserialize().ok()?;
    let matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
        matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(message),
    ) = event
    else {
        return None;
    };
    let original = message.as_original()?;
    let source_timestamp = u64::from(original.origin_server_ts.0);
    let source_event_id = original.event_id.to_string();
    let sender_id = original.sender.to_string();
    let sender_is_ignored = match ignored_user_ids {
        Some(ignored_user_ids) => ignored_user_ids.contains(&sender_id),
        None => effective_is_user_ignored(client, &original.sender).await,
    };
    if sender_is_ignored {
        return None;
    }

    let body = room_message_preview(&original.content)?;
    if !message_matches_search_terms(&body, terms) {
        return None;
    }

    let mut target_event_id = original.event_id.clone();
    let mut timestamp = original.origin_server_ts;
    let mut is_edited = false;
    if let Some(matrix_sdk::ruma::events::room::message::Relation::Replacement(replacement)) =
        &original.content.relates_to
    {
        is_edited = true;
        target_event_id = replacement.event_id.clone();
        if let Ok(target) = room.load_or_fetch_event(&target_event_id, None).await {
            if let Ok(target) = target.raw().deserialize() {
                timestamp = target.origin_server_ts();
            }
        }
    }

    let sender_name = if client
        .user_id()
        .is_some_and(|user_id| user_id.as_str() == sender_id)
    {
        "我".to_string()
    } else {
        sender_names.get(room, &original.sender).await
    };

    Some((
        MessageSearchResult {
            room_id: room.room_id().to_string(),
            room_name: room_display_name(room),
            room_avatar_url: room.avatar_url().map(|url| url.to_string()),
            event_id: target_event_id.to_string(),
            sender_id,
            sender_name,
            body,
            timestamp: u64::from(timestamp.0).to_string(),
            is_dm,
            is_edited,
        },
        source_timestamp,
        source_event_id,
    ))
}

pub(super) async fn cancel_message_search(room_id: Option<String>) {
    if let Some(client) = get_client().await {
        let _ = begin_message_search(&client, room_id.as_deref()).await;
    }
}

pub(super) fn paginate_message_search_results(
    results: Vec<MessageSearchResult>,
    offset: usize,
    limit: usize,
) -> (Vec<MessageSearchResult>, bool) {
    let page_end = offset.saturating_add(limit);
    let has_more = results.len() > page_end;
    let page = results.into_iter().skip(offset).take(limit).collect();
    (page, has_more)
}
