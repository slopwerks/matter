use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;
use serde_json::Value;

use super::ImageMessageMetadata;

pub(super) const ALBUM_RELATION: &str = "moe.aks.matter.album";
const BLURHASH_KEY: &str = "xyz.amorgan.blurhash";
const SPOILER_KEY: &str = "page.codeberg.everypizza.msc4193.spoiler";

pub(super) const SHARED_CAPTION_KEY: &str = "moe.aks.matter.shared_caption";

/// Keep a standard caption on the final image while every image carries the
/// description used by Matter's gallery. Both fields remain inside the event
/// content, so encrypted rooms protect them along with the media metadata.
pub(super) fn with_captions(
    content: RoomMessageEventContent,
    caption: Option<&str>,
    shared_caption: Option<&str>,
) -> Result<Value, String> {
    let mut content = serde_json::to_value(content).map_err(|error| error.to_string())?;
    if let Some(caption) = nonempty_caption(caption) {
        content["filename"] = content["body"].clone();
        content["body"] = Value::String(caption.to_owned());
    }
    if let Some(caption) = nonempty_caption(shared_caption) {
        content[SHARED_CAPTION_KEY] = Value::String(caption.to_owned());
    }
    Ok(content)
}

pub(super) fn shared_caption(event: &Value) -> Option<String> {
    let content = event.get("content")?;
    nonempty_caption(content.get(SHARED_CAPTION_KEY)?.as_str()).map(str::to_owned)
}

pub(super) fn with_metadata(
    mut content: Value,
    metadata: Option<&ImageMessageMetadata>,
) -> Result<Value, String> {
    let Some(metadata) = metadata else {
        return Ok(content);
    };
    if let Some(root) = &metadata.album_root {
        let root = matrix_sdk::ruma::EventId::parse(root)
            .map_err(|error| format!("Invalid album root: {error}"))?;
        content["m.relates_to"]["rel_type"] = Value::String(ALBUM_RELATION.to_owned());
        content["m.relates_to"]["event_id"] = Value::String(root.to_string());
    }
    let reply_user = metadata
        .reply_to_user_id
        .as_ref()
        .map(matrix_sdk::ruma::UserId::parse)
        .transpose()
        .map_err(|error| format!("Invalid reply user ID: {error}"))?;
    if let Some(event_id) = &metadata.reply_to_event_id {
        let event_id = matrix_sdk::ruma::EventId::parse(event_id)
            .map_err(|error| format!("Invalid reply event ID: {error}"))?;
        content["m.relates_to"]["m.in_reply_to"] = serde_json::json!({
            "event_id": event_id.as_str(),
        });
        if let Some(user_id) = reply_user {
            content["m.mentions"] = serde_json::json!({ "user_ids": [user_id.as_str()] });
        }
    }
    if let Some(hash) = &metadata.blurhash {
        content["info"][BLURHASH_KEY] = Value::String(hash.clone());
    }
    if metadata.spoiler {
        content[SPOILER_KEY] = Value::Bool(true);
        if let Some(reason) = nonempty_caption(metadata.spoiler_reason.as_deref()) {
            content[format!("{SPOILER_KEY}.reason")] = Value::String(reason.to_owned());
        }
    }
    Ok(content)
}

pub(super) fn metadata(event: &Value) -> Option<ImageMessageMetadata> {
    let content = event.get("content")?;
    let relation = content.get("m.relates_to");
    let album_root = relation
        .filter(|relation| relation.get("rel_type").and_then(Value::as_str) == Some(ALBUM_RELATION))
        .and_then(|relation| relation.get("event_id"))
        .and_then(Value::as_str)
        .and_then(|id| matrix_sdk::ruma::EventId::parse(id).ok())
        .map(|id| id.to_string());
    let reply_to_event_id = relation
        .and_then(|relation| relation.get("m.in_reply_to"))
        .and_then(|reply| reply.get("event_id"))
        .and_then(Value::as_str)
        .and_then(|id| matrix_sdk::ruma::EventId::parse(id).ok())
        .map(|id| id.to_string());
    // Matrix does not explicitly identify the reply recipient. Our outbound
    // images mention only that user; do not guess when incoming mentions differ.
    let reply_to_user_id = reply_to_event_id.as_ref().and_then(|_| {
        let users = content.get("m.mentions")?.get("user_ids")?.as_array()?;
        if users.len() != 1 {
            return None;
        }
        matrix_sdk::ruma::UserId::parse(users[0].as_str()?)
            .ok()
            .map(|id| id.to_string())
    });
    let blurhash = content
        .get("info")
        .and_then(|info| info.get(BLURHASH_KEY))
        .and_then(Value::as_str)
        .filter(|hash| !hash.is_empty() && hash.len() <= 166)
        .map(str::to_owned);
    let spoiler_value = content
        .get(SPOILER_KEY)
        .or_else(|| content.get("m.spoiler"));
    let spoiler =
        spoiler_value.is_some_and(|value| value.as_bool() == Some(true) || value.is_object());
    let spoiler_reason = if spoiler {
        spoiler_value
            .and_then(|value| value.get("reason"))
            .and_then(Value::as_str)
            .or_else(|| {
                content
                    .get(format!("{SPOILER_KEY}.reason"))
                    .and_then(Value::as_str)
            })
            .or_else(|| content.get("m.spoiler.reason").and_then(Value::as_str))
            .and_then(|reason| nonempty_caption(Some(reason)))
            .map(str::to_owned)
    } else {
        None
    };
    if album_root.is_none() && reply_to_event_id.is_none() && blurhash.is_none() && !spoiler {
        return None;
    }
    Some(ImageMessageMetadata {
        album_root,
        reply_to_event_id,
        reply_to_user_id,
        blurhash,
        spoiler,
        spoiler_reason,
    })
}

pub(super) async fn album_caption(
    room: &matrix_sdk::Room,
    root: &matrix_sdk::ruma::EventId,
) -> Result<Option<String>, String> {
    use matrix_sdk::room::{IncludeRelations, RelationsOptions};
    let root_event = room
        .load_or_fetch_event(root, None)
        .await
        .map_err(|error| error.to_string())?;
    let root_json = root_event
        .raw()
        .deserialize_as::<Value>()
        .map_err(|error| error.to_string())?;
    let sender = root_json.get("sender").and_then(Value::as_str);
    let mut options = RelationsOptions {
        include_relations: IncludeRelations::RelationsOfType(ALBUM_RELATION.into()),
        limit: matrix_sdk::ruma::UInt::new(100),
        ..Default::default()
    };
    loop {
        let page = room
            .relations(root.to_owned(), options.clone())
            .await
            .map_err(|error| error.to_string())?;
        for event in page.chunk {
            let value = event
                .raw()
                .deserialize_as::<Value>()
                .map_err(|error| error.to_string())?;
            if sender.is_some() && value.get("sender").and_then(Value::as_str) == sender {
                if let Some(caption) = standard_caption(&value) {
                    return Ok(Some(caption));
                }
            }
        }
        match page.next_batch_token {
            Some(token) if options.from.as_ref() != Some(&token) => options.from = Some(token),
            _ => break,
        }
    }
    Ok(standard_caption(&root_json))
}

fn standard_caption(event: &Value) -> Option<String> {
    let content = event.get("content")?;
    if content.get("msgtype").and_then(Value::as_str) != Some("m.image") {
        return None;
    }
    let filename = content.get("filename")?.as_str()?;
    let body = content.get("body")?.as_str()?;
    (body != filename)
        .then(|| nonempty_caption(Some(body)).map(str::to_owned))
        .flatten()
}

fn nonempty_caption(caption: Option<&str>) -> Option<&str> {
    caption.map(str::trim).filter(|caption| !caption.is_empty())
}
