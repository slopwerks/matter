//! Sdk message adaptation.
use super::*;

#[allow(clippy::too_many_arguments)]
pub(in crate::api::matrix) fn message_to_chat_message(
    event_id: &str,
    sender_id: &str,
    sender_name: &str,
    timestamp: &str,
    is_me: bool,
    in_reply_to: Option<String>,
    message: &matrix_sdk_ui::timeline::Message,
    item: &EventTimelineItem,
) -> Option<ChatMessage> {
    let mentions = message.mentions();
    let mut result = match message.msgtype() {
        RumaMessageType::Text(text) => {
            let (content, formatted_body, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                content,
                formatted_body,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Notice(text) => {
            let (content, formatted_body, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                content,
                formatted_body,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Emote(text) => {
            let (body, _, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                format!("* {sender_name} {body}"),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Image(image) => {
            let image_url = match &image.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (image_width, image_height) = image_info_dimensions(image.info.as_deref());
            let (caption, caption_formatted_body) =
                media_caption_parts(image.formatted_caption(), image.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                image.filename().to_string(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Image,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&image.source).ok();
            result.image_width = image_width;
            result.image_height = image_height;
            result.filename = Some(image.filename().to_string());
            result.file_size = image
                .info
                .as_deref()
                .and_then(|info| uint_to_i32(info.size));
            result.mime_type = image.info.as_deref().and_then(|info| info.mimetype.clone());
            let original_event = item
                .original_json()
                .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw.json().get()).ok());
            result.image_metadata = original_event
                .as_ref()
                .and_then(super::super::image_caption::metadata);
            if !message.is_edited() {
                result.shared_caption = original_event
                    .as_ref()
                    .and_then(super::super::image_caption::shared_caption);
                if result.caption.is_none()
                    && image.filename.is_some()
                    && result.shared_caption.as_deref() == Some(image.body.as_str())
                {
                    result.caption = result.shared_caption.clone();
                }
            }
            result
        }
        RumaMessageType::Video(video) => {
            let image_url = match &video.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (image_width, image_height) = video
                .info
                .as_ref()
                .map(|info| (uint_to_i32(info.width), uint_to_i32(info.height)))
                .unwrap_or((None, None));
            let (caption, caption_formatted_body) =
                media_caption_parts(video.formatted_caption(), video.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                video.filename().to_string(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Video,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&video.source).ok();
            result.image_width = image_width;
            result.image_height = image_height;
            result.duration_ms =
                media_duration_ms(video.info.as_deref().and_then(|info| info.duration));
            result
        }
        RumaMessageType::File(file) => {
            let filename = file.filename().to_string();
            let image_url = match &file.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (caption, caption_formatted_body) =
                media_caption_parts(file.formatted_caption(), file.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                filename.clone(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::File,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.filename = Some(filename);
            result.file_size = file.info.as_deref().and_then(|info| uint_to_i32(info.size));
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&file.source).ok();
            result
        }
        RumaMessageType::Audio(audio) => {
            let filename = audio.filename().to_string();
            let image_url = match &audio.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (caption, caption_formatted_body) =
                media_caption_parts(audio.formatted_caption(), audio.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                filename.clone(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::File,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.filename = Some(filename);
            result.file_size = audio
                .info
                .as_deref()
                .and_then(|info| uint_to_i32(info.size));
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&audio.source).ok();
            result.duration_ms =
                media_duration_ms(audio.info.as_deref().and_then(|info| info.duration));
            result
        }
        RumaMessageType::Location(location) => {
            let geo_uri = location.geo_uri.clone();
            let body = location.body.clone();
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                if body.trim().is_empty() {
                    geo_uri.clone()
                } else {
                    body
                },
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Location,
                in_reply_to,
            );
            result.geo_uri = Some(geo_uri);
            result
        }
        _ => return None,
    };
    result.is_edited = message.is_edited();
    if result.is_edited {
        if let Some(original) = original_message_body(item) {
            result.edit_history = vec![original, result.content.clone()];
        }
    }
    Some(result)
}

pub(in crate::api::matrix) fn media_duration_ms(
    duration: Option<std::time::Duration>,
) -> Option<i32> {
    duration
        .and_then(|duration| i32::try_from(duration.as_millis()).ok())
        .filter(|value| *value > 0)
}

#[allow(clippy::too_many_arguments)]
#[flutter_rust_bridge::frb(ignore)]
pub(in crate::api::matrix) fn base_message(
    event_id: &str,
    sender_id: &str,
    sender_name: &str,
    timestamp: &str,
    is_me: bool,
    content: String,
    formatted_body: Option<String>,
    mentioned_user_ids: Vec<String>,
    mentions_room: bool,
    msg_type: MessageType,
    in_reply_to: Option<String>,
) -> ChatMessage {
    ChatMessage {
        id: event_id.to_owned(),
        sender_id: sender_id.to_owned(),
        sender_name: sender_name.to_owned(),
        content,
        formatted_body,
        caption: None,
        caption_formatted_body: None,
        shared_caption: None,
        image_metadata: None,
        mentioned_user_ids,
        mentions_room,
        timestamp: timestamp.to_owned(),
        is_me,
        msg_type,
        image_url: None,
        media_source_json: None,
        image_width: None,
        image_height: None,
        filename: None,
        file_size: None,
        mime_type: None,
        duration_ms: None,
        geo_uri: None,
        poll: None,
        in_reply_to,
        is_edited: false,
        edit_history: Vec::new(),
        reactions: Vec::new(),
        readers: Vec::new(),
        total_members: 0,
    }
}

pub(in crate::api::matrix) fn original_message_body(item: &EventTimelineItem) -> Option<String> {
    let event: AnySyncTimelineEvent = item.original_json()?.deserialize().ok()?;
    let AnySyncTimelineEvent::MessageLike(
        matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(message),
    ) = event
    else {
        return None;
    };
    Some(message.as_original()?.content.msgtype.body().to_owned())
}

pub(in crate::api::matrix) fn timeline_reactions(item: &EventTimelineItem) -> Vec<Reaction> {
    item.content()
        .reactions()
        .into_iter()
        .flat_map(|reactions| reactions.iter())
        .map(|(key, by_sender)| Reaction {
            key: key.clone(),
            senders: by_sender.keys().map(ToString::to_string).collect(),
            // SDK 0.19 keeps reaction event IDs private; toggling is handled
            // by Timeline::toggle_reaction, including unsent local echoes.
            my_event_id: None,
        })
        .collect()
}
