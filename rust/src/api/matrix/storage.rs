//! Media references from SDK history already on disk. Never fetch or decrypt
//! events here: SDK decryption retries can enqueue network key requests.

use std::collections::{HashMap, HashSet};

use flutter_rust_bridge::frb;
use matrix_sdk::{
    deserialized_responses::TimelineEvent,
    ruma::events::{
        room::message::MessageType as RoomMessageType, AnySyncMessageLikeEvent,
        AnySyncTimelineEvent,
    },
    Client, Room,
};
use matrix_sdk_base::linked_chunk::{ChunkContent, LinkedChunkId};

use super::{api_err, ensure_account_matches, get_client, sdk_timeline, ChatMessage, MessageType};

/// Read local cached media references for the active account. Message bodies
/// and encryption material are never copied into a new persistent index.
#[frb]
pub async fn get_cached_media_messages(
    expected_user_id: String,
) -> Result<HashMap<String, Vec<ChatMessage>>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("storage", "No active account".to_owned()))?;
    cached_media_messages(&client, &expected_user_id).await
}

async fn cached_media_messages(
    client: &Client,
    expected_user_id: &str,
) -> Result<HashMap<String, Vec<ChatMessage>>, String> {
    ensure_account_matches(client, expected_user_id)?;
    let mut rooms = HashMap::new();
    for room in client.rooms() {
        let messages = room_media_messages(client, &room).await?;
        if !messages.is_empty() {
            rooms.insert(room.room_id().to_string(), messages);
        }
    }
    Ok(rooms)
}

async fn room_media_messages(client: &Client, room: &Room) -> Result<Vec<ChatMessage>, String> {
    let metadata = {
        let state = client
            .event_cache_store()
            .lock()
            .await
            .map_err(store_error)?;
        state
            .as_clean()
            .ok_or_else(cache_changed)?
            .load_all_chunks_metadata(LinkedChunkId::Room(room.room_id()))
            .await
            .map_err(store_error)?
    };
    let mut messages = HashMap::new();
    let mut redacted = HashSet::new();
    let mut replacements = HashMap::new();
    // Load one chunk at a time, releasing the store lock between chunks. Text
    // bodies are discarded immediately instead of materialising full history.
    for metadata in metadata {
        let chunk = {
            let state = client
                .event_cache_store()
                .lock()
                .await
                .map_err(store_error)?;
            let store = state.as_clean().ok_or_else(cache_changed)?;
            if let Some(next) = metadata.next {
                store
                    .load_previous_chunk(LinkedChunkId::Room(room.room_id()), next)
                    .await
                    .map_err(store_error)?
            } else {
                store
                    .load_last_chunk(LinkedChunkId::Room(room.room_id()))
                    .await
                    .map_err(store_error)?
                    .0
            }
        };
        let chunk = chunk.ok_or_else(cache_changed)?;
        if chunk.identifier != metadata.identifier {
            return Err(cache_changed());
        }
        if let ChunkContent::Items(events) = chunk.content {
            for event in events {
                let raw = event.raw();
                let content = raw.get_field::<serde_json::Value>("content").ok().flatten();
                if event.kind.event_type().as_deref() == Some("m.room.redaction") {
                    if let Some(id) =
                        raw.get_field::<String>("redacts")
                            .ok()
                            .flatten()
                            .or_else(|| {
                                content
                                    .as_ref()?
                                    .get("redacts")?
                                    .as_str()
                                    .map(str::to_owned)
                            })
                    {
                        redacted.insert(id);
                    }
                }
                if let Some(message) = media_message(&event) {
                    if let Some(relation) = content.as_ref().and_then(|v| v.get("m.relates_to")) {
                        if relation.get("rel_type").and_then(|v| v.as_str()) == Some("m.replace") {
                            if let Some(id) = relation.get("event_id").and_then(|v| v.as_str()) {
                                replacements.insert(message.id.clone(), id.to_owned());
                            }
                        }
                    }
                    messages.insert(message.id.clone(), message);
                }
            }
        }
    }
    Ok(messages
        .into_values()
        .filter(|message| {
            !redacted.contains(&message.id)
                && !replacements
                    .get(&message.id)
                    .is_some_and(|id| redacted.contains(id))
        })
        .collect())
}

fn cache_changed() -> String {
    api_err(
        "storage",
        "Local event cache changed; refresh to retry".to_owned(),
    )
}

fn store_error(error: impl std::fmt::Display) -> String {
    api_err(
        "storage",
        format!("Cannot read local media history: {error}"),
    )
}

fn media_message(event: &TimelineEvent) -> Option<ChatMessage> {
    if event.kind.is_utd() {
        return None;
    }
    let id = event.event_id()?.as_str();
    let raw = event.raw().deserialize().ok()?;
    let (kind, source, filename, mime) = match raw {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(message)) => {
            let original = message.as_original()?;
            match &original.content.msgtype {
                RoomMessageType::Image(value) => (
                    MessageType::Image,
                    serde_json::to_string(&value.source).ok()?,
                    Some(value.filename().to_owned()),
                    value.info.as_deref().and_then(|info| info.mimetype.clone()),
                ),
                RoomMessageType::Video(value) => (
                    MessageType::Video,
                    serde_json::to_string(&value.source).ok()?,
                    Some(value.filename().to_owned()),
                    value.info.as_deref().and_then(|info| info.mimetype.clone()),
                ),
                RoomMessageType::Audio(value) => (
                    MessageType::File,
                    serde_json::to_string(&value.source).ok()?,
                    Some(value.filename().to_owned()),
                    Some(
                        value
                            .info
                            .as_deref()
                            .and_then(|info| info.mimetype.clone())
                            .unwrap_or_else(|| "audio/unknown".to_owned()),
                    ),
                ),
                RoomMessageType::File(value) => (
                    MessageType::File,
                    serde_json::to_string(&value.source).ok()?,
                    Some(value.filename().to_owned()),
                    value.info.as_deref().and_then(|info| info.mimetype.clone()),
                ),
                _ => return None,
            }
        }
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::Sticker(message)) => {
            let original = message.as_original()?;
            (
                MessageType::Sticker,
                serde_json::to_string(&original.content.source).ok()?,
                None,
                original.content.info.mimetype.clone(),
            )
        }
        _ => return None,
    };
    let mut message = sdk_timeline::base_message(
        id,
        "",
        "",
        "0",
        false,
        String::new(),
        None,
        Vec::new(),
        false,
        kind,
        None,
    );
    let decoded: serde_json::Value = serde_json::from_str(&source).ok()?;
    message.image_url = decoded
        .as_str()
        .or_else(|| decoded.get("url").and_then(|value| value.as_str()))
        .map(str::to_owned);
    message.media_source_json = Some(source);
    message.filename = filename;
    message.mime_type = mime;
    Some(message)
}

#[cfg(test)]
#[path = "storage_tests.rs"]
mod tests;
