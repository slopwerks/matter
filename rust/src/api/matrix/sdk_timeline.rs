use std::{collections::HashMap, sync::Arc};

use matrix_sdk::{
    ruma::{
        api::client::receipt::create_receipt::v3::ReceiptType,
        events::{
            room::message::MessageType as RumaMessageType, AnySyncStateEvent, AnySyncTimelineEvent,
        },
    },
    Client, Room,
};
use matrix_sdk_ui::timeline::{
    EventTimelineItem, MembershipChange, MsgLikeKind, Profile, ReactionStatus, Timeline,
    TimelineBuilder, TimelineDetails, TimelineItem, TimelineItemContent,
    TimelineReadReceiptTracking,
};
use once_cell::sync::Lazy;
use tokio::sync::Mutex;

use super::{
    image_info_dimensions, media_caption_parts, mentions_parts, sticker_info_dimensions,
    text_message_parts, uint_to_i32, unable_to_decrypt_message, ChatMessage, MessageReader,
    MessageType, Reaction,
};

static TIMELINES: Lazy<Mutex<HashMap<String, Arc<Timeline>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn timeline_key(client: &Client, room: &Room) -> Result<String, String> {
    let user_id = client.user_id().ok_or("No active user")?;
    Ok(format!("{}\n{}", user_id, room.room_id()))
}

pub(super) async fn clear_all() {
    TIMELINES.lock().await.clear();
}

async fn get_or_create_timeline(client: &Client, room: &Room) -> Result<Arc<Timeline>, String> {
    let key = timeline_key(client, room)?;
    if let Some(timeline) = TIMELINES.lock().await.get(&key).cloned() {
        return Ok(timeline);
    }

    let timeline = Arc::new(
        TimelineBuilder::new(room)
            .track_read_marker_and_receipts(TimelineReadReceiptTracking::AllEvents)
            .build()
            .await
            .map_err(|error| format!("Failed to build room timeline: {error}"))?,
    );
    let mut timelines = TIMELINES.lock().await;
    Ok(timelines
        .entry(key)
        .or_insert_with(|| timeline.clone())
        .clone())
}

async fn snapshot(timeline: &Timeline) -> Vec<Arc<TimelineItem>> {
    let (items, updates) = timeline.subscribe().await;
    drop(updates);
    items.into_iter().collect()
}

fn remote_event_count(items: &[Arc<TimelineItem>]) -> usize {
    items
        .iter()
        .filter_map(|item| item.as_event())
        .filter(|event| event.event_id().is_some())
        .count()
}

async fn ensure_initial_window(timeline: &Timeline, target: usize) -> Result<(), String> {
    for _ in 0..4 {
        let items = snapshot(timeline).await;
        let count = remote_event_count(&items);
        if count >= target {
            return Ok(());
        }
        let requested = target.saturating_sub(count).clamp(20, u16::MAX as usize) as u16;
        let hit_start = timeline
            .paginate_backwards(requested)
            .await
            .map_err(|error| format!("Failed to paginate room timeline: {error}"))?;
        let updated_count = remote_event_count(&snapshot(timeline).await);
        if hit_start || updated_count <= count {
            return Ok(());
        }
    }
    Ok(())
}

pub(super) async fn get_messages(client: &Client, room: &Room) -> Result<Vec<ChatMessage>, String> {
    const LIVE_WINDOW: usize = 100;

    let timeline = get_or_create_timeline(client, room).await?;
    ensure_initial_window(&timeline, LIVE_WINDOW).await?;

    // The Timeline guards against moving either marker backwards.
    let _ = timeline.mark_as_read(ReceiptType::Read).await;
    let _ = timeline.mark_as_read(ReceiptType::FullyRead).await;

    let mut messages = convert_snapshot(room, &snapshot(&timeline).await).await;
    if messages.len() > LIVE_WINDOW {
        messages.drain(..messages.len() - LIVE_WINDOW);
    }
    Ok(messages)
}

pub(super) async fn get_messages_before(
    client: &Client,
    room: &Room,
    from_event_id: &str,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let timeline = get_or_create_timeline(client, room).await?;
    let limit = limit.min(u16::MAX as u32) as usize;
    if limit == 0 {
        return Ok(Vec::new());
    }

    let current = convert_snapshot(room, &snapshot(&timeline).await).await;
    let available = messages_before(&current, from_event_id).len();
    if available < limit {
        timeline
            .paginate_backwards((limit - available).max(20) as u16)
            .await
            .map_err(|error| format!("Failed to paginate room timeline: {error}"))?;
    }

    let messages = convert_snapshot(room, &snapshot(&timeline).await).await;
    let before = messages_before(&messages, from_event_id);
    Ok(before[before.len().saturating_sub(limit)..].to_vec())
}

fn messages_before<'a>(messages: &'a [ChatMessage], event_id: &str) -> &'a [ChatMessage] {
    messages
        .iter()
        .position(|message| message.id == event_id)
        .map(|position| &messages[..position])
        .unwrap_or_default()
}

async fn convert_snapshot(room: &Room, items: &[Arc<TimelineItem>]) -> Vec<ChatMessage> {
    let my_user_id = room.client().user_id().map(ToString::to_string);
    let event_items: Vec<&EventTimelineItem> =
        items.iter().filter_map(|item| item.as_event()).collect();
    let event_positions: HashMap<String, usize> = event_items
        .iter()
        .enumerate()
        .filter_map(|(position, event)| {
            event
                .event_id()
                .map(|event_id| (event_id.to_string(), position))
        })
        .collect();
    let mut receipt_positions = HashMap::new();
    for (position, event) in event_items.iter().enumerate() {
        for user_id in event.read_receipts().keys() {
            if my_user_id.as_deref() != Some(user_id.as_str()) {
                receipt_positions.insert(user_id.to_string(), position);
            }
        }
    }

    let members = room
        .members(matrix_sdk::RoomMemberships::JOIN)
        .await
        .unwrap_or_default();
    let mut profiles: HashMap<String, (String, Option<String>)> = members
        .iter()
        .map(|member| {
            (
                member.user_id().to_string(),
                (
                    member.name().to_string(),
                    member.avatar_url().map(ToString::to_string),
                ),
            )
        })
        .collect();
    for event in &event_items {
        if let TimelineDetails::Ready(Profile {
            display_name,
            avatar_url,
            ..
        }) = event.sender_profile()
        {
            profiles
                .entry(event.sender().to_string())
                .or_insert_with(|| {
                    (
                        display_name
                            .clone()
                            .unwrap_or_else(|| event.sender().localpart().to_owned()),
                        avatar_url.as_ref().map(ToString::to_string),
                    )
                });
        }
    }
    let base_total_members = room.active_members_count().min(i32::MAX as u64) as i32;

    let mut messages: Vec<ChatMessage> = event_items
        .iter()
        .filter_map(|event| timeline_item_to_message(event, my_user_id.as_deref()))
        .collect();
    for message in &mut messages {
        message.total_members = base_total_members;
        if !message.is_me {
            continue;
        }
        let Some(message_position) = event_positions.get(&message.id) else {
            continue;
        };
        let readers_at_message = reader_ids_for_position(&receipt_positions, *message_position);
        let readers: Vec<MessageReader> = readers_at_message
            .into_iter()
            .map(|user_id| {
                let (display_name, avatar_url) =
                    profiles.get(&user_id).cloned().unwrap_or_else(|| {
                        (
                            user_id
                                .split(':')
                                .next()
                                .unwrap_or(&user_id)
                                .trim_start_matches('@')
                                .to_owned(),
                            None,
                        )
                    });
                MessageReader {
                    user_id,
                    display_name,
                    avatar_url,
                }
            })
            .collect();
        message.total_members = message.total_members.max(readers.len() as i32 + 1);
        message.readers = readers;
    }
    messages
}

fn reader_ids_for_position(
    receipt_positions: &HashMap<String, usize>,
    message_position: usize,
) -> Vec<String> {
    let mut readers: Vec<String> = receipt_positions
        .iter()
        .filter(|(_, receipt_position)| **receipt_position >= message_position)
        .map(|(user_id, _)| user_id.clone())
        .collect();
    readers.sort();
    readers
}

fn timeline_item_to_message(
    item: &EventTimelineItem,
    my_user_id: Option<&str>,
) -> Option<ChatMessage> {
    let event_id = item.event_id()?.to_string();
    let sender_id = item.sender().to_string();
    let is_me = my_user_id == Some(sender_id.as_str());
    let sender_name = if is_me {
        "我".to_owned()
    } else if let TimelineDetails::Ready(profile) = item.sender_profile() {
        profile
            .display_name
            .clone()
            .unwrap_or_else(|| item.sender().localpart().to_owned())
    } else {
        item.sender().localpart().to_owned()
    };
    let timestamp = u64::from(item.timestamp().0).to_string();

    let mut message = match item.content() {
        TimelineItemContent::MsgLike(content) => {
            let in_reply_to = content
                .in_reply_to
                .as_ref()
                .map(|reply| reply.event_id.to_string());
            match &content.kind {
                MsgLikeKind::Message(message) => message_to_chat_message(
                    &event_id,
                    &sender_id,
                    &sender_name,
                    &timestamp,
                    is_me,
                    in_reply_to,
                    message,
                    item,
                )?,
                MsgLikeKind::Sticker(sticker) => {
                    let content = sticker.content();
                    let source = &content.source;
                    let image_url = match source {
                        matrix_sdk::ruma::events::sticker::StickerMediaSource::Plain(mxc) => {
                            Some(mxc.to_string())
                        }
                        _ => None,
                    };
                    let (image_width, image_height) = sticker_info_dimensions(&content.info);
                    ChatMessage {
                        id: event_id,
                        sender_id,
                        sender_name,
                        content: content.body.clone(),
                        formatted_body: None,
                        caption: None,
                        caption_formatted_body: None,
                        mentioned_user_ids: Vec::new(),
                        mentions_room: false,
                        timestamp,
                        is_me,
                        msg_type: MessageType::Sticker,
                        image_url,
                        media_source_json: serde_json::to_string(source).ok(),
                        image_width,
                        image_height,
                        in_reply_to,
                        is_edited: false,
                        edit_history: Vec::new(),
                        reactions: Vec::new(),
                        readers: Vec::new(),
                        total_members: 0,
                    }
                }
                MsgLikeKind::UnableToDecrypt(_) => {
                    unable_to_decrypt_message(event_id, sender_id, sender_name, timestamp, is_me)
                }
                _ => return None,
            }
        }
        TimelineItemContent::MembershipChange(change) => ChatMessage {
            id: event_id,
            sender_id,
            sender_name,
            content: membership_label(change)?,
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp,
            is_me: false,
            msg_type: MessageType::Event,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 0,
        },
        TimelineItemContent::OtherState(_) => ChatMessage {
            id: event_id,
            sender_id,
            sender_name,
            content: state_event_label(item)?,
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp,
            is_me: false,
            msg_type: MessageType::Event,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 0,
        },
        _ => return None,
    };
    message.reactions = timeline_reactions(item, my_user_id);
    Some(message)
}

#[allow(clippy::too_many_arguments)]
fn message_to_chat_message(
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
            let (image_width, image_height) = image_info_dimensions(image.info.as_ref());
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
            result
        }
        RumaMessageType::File(file) => {
            let (caption, caption_formatted_body) =
                media_caption_parts(file.formatted_caption(), file.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                format!("文件: {}", file.filename()),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
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

#[allow(clippy::too_many_arguments)]
fn base_message(
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
        mentioned_user_ids,
        mentions_room,
        timestamp: timestamp.to_owned(),
        is_me,
        msg_type,
        image_url: None,
        media_source_json: None,
        image_width: None,
        image_height: None,
        in_reply_to,
        is_edited: false,
        edit_history: Vec::new(),
        reactions: Vec::new(),
        readers: Vec::new(),
        total_members: 0,
    }
}

fn original_message_body(item: &EventTimelineItem) -> Option<String> {
    let event: AnySyncTimelineEvent = item.original_json()?.deserialize().ok()?;
    let AnySyncTimelineEvent::MessageLike(
        matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(message),
    ) = event
    else {
        return None;
    };
    Some(message.as_original()?.content.msgtype.body().to_owned())
}

fn timeline_reactions(item: &EventTimelineItem, my_user_id: Option<&str>) -> Vec<Reaction> {
    item.content()
        .reactions()
        .into_iter()
        .flat_map(|reactions| reactions.iter())
        .map(|(key, by_sender)| Reaction {
            key: key.clone(),
            senders: by_sender.keys().map(ToString::to_string).collect(),
            my_event_id: my_user_id
                .and_then(|user_id| by_sender.get(user_id))
                .and_then(|reaction| match &reaction.status {
                    ReactionStatus::RemoteToRemote(event_id) => Some(event_id.to_string()),
                    _ => None,
                }),
        })
        .collect()
}

fn membership_label(change: &matrix_sdk_ui::timeline::RoomMembershipChange) -> Option<String> {
    let name = change
        .display_name()
        .unwrap_or_else(|| change.user_id().localpart().to_owned());
    match change.change()? {
        MembershipChange::Joined | MembershipChange::InvitationAccepted => {
            Some(format!("{name} 加入了房间"))
        }
        MembershipChange::Left
        | MembershipChange::Kicked
        | MembershipChange::InvitationRejected
        | MembershipChange::InvitationRevoked => Some(format!("{name} 离开了房间")),
        MembershipChange::Banned | MembershipChange::KickedAndBanned => {
            Some(format!("{name} 被封禁"))
        }
        MembershipChange::Invited => Some(format!("{name} 收到了加入房间的邀请")),
        MembershipChange::Knocked => Some(format!("{name} 请求加入房间")),
        _ => None,
    }
}

fn state_event_label(item: &EventTimelineItem) -> Option<String> {
    let event: AnySyncTimelineEvent = item.original_json()?.deserialize().ok()?;
    let AnySyncTimelineEvent::State(state) = event else {
        return None;
    };
    match state {
        AnySyncStateEvent::RoomCreate(_) => Some("房间已创建".to_owned()),
        AnySyncStateEvent::RoomName(name) => name
            .as_original()
            .map(|event| format!("房间名称更改为: {}", event.content.name)),
        AnySyncStateEvent::RoomTopic(topic) => topic
            .as_original()
            .map(|event| format!("主题更改为: {}", event.content.topic)),
        AnySyncStateEvent::RoomAvatar(_) => Some("房间头像已更改".to_owned()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{messages_before, reader_ids_for_position};
    use crate::api::matrix::{ChatMessage, MessageType};
    use std::collections::HashMap;

    fn message(id: &str) -> ChatMessage {
        ChatMessage {
            id: id.to_owned(),
            sender_id: "@alice:example.org".to_owned(),
            sender_name: "Alice".to_owned(),
            content: id.to_owned(),
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp: "0".to_owned(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 2,
        }
    }

    #[test]
    fn slices_messages_before_the_requested_boundary() {
        let messages = vec![message("$a"), message("$b"), message("$c")];
        assert_eq!(
            messages_before(&messages, "$c")
                .iter()
                .map(|message| message.id.as_str())
                .collect::<Vec<_>>(),
            ["$a", "$b"]
        );
    }

    #[test]
    fn receipt_positions_apply_cumulatively_without_timestamps() {
        let receipts = HashMap::from([
            ("@bob:example.org".to_owned(), 4),
            ("@carol:example.org".to_owned(), 2),
        ]);

        assert_eq!(reader_ids_for_position(&receipts, 3), ["@bob:example.org"]);
        assert_eq!(
            reader_ids_for_position(&receipts, 2),
            ["@bob:example.org", "@carol:example.org"]
        );
    }
}
