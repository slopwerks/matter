//! Sdk convert adaptation.
use super::*;

pub(in crate::api::matrix) fn timeline_item_to_message(
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
                        shared_caption: None,
                        image_metadata: None,
                        mentioned_user_ids: Vec::new(),
                        mentions_room: false,
                        timestamp,
                        is_me,
                        msg_type: MessageType::Sticker,
                        image_url,
                        media_source_json: serde_json::to_string(source).ok(),
                        image_width,
                        image_height,
                        filename: None,
                        file_size: uint_to_i32(content.info.size),
                        mime_type: content.info.mimetype.clone(),
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
                MsgLikeKind::UnableToDecrypt(_) => {
                    unable_to_decrypt_message(event_id, sender_id, sender_name, timestamp, is_me)
                }
                MsgLikeKind::Poll(state) => poll_message(
                    event_id,
                    sender_id,
                    sender_name,
                    timestamp,
                    is_me,
                    in_reply_to,
                    state,
                    my_user_id,
                )?,
                _ => return None,
            }
        }
        TimelineItemContent::MembershipChange(change) => {
            let (content, mime) = membership_info(change)?;
            event_chat_message(event_id, sender_id, sender_name, timestamp, content, mime)
        }
        TimelineItemContent::ProfileChange(change) => {
            let (content, mime) = profile_change_info(change, &sender_name)?;
            event_chat_message(event_id, sender_id, sender_name, timestamp, content, mime)
        }
        TimelineItemContent::OtherState(other) => {
            let (content, mime) = other_state_info(other, &sender_name, item)?;
            event_chat_message(event_id, sender_id, sender_name, timestamp, content, mime)
        }
        TimelineItemContent::CallInvite => event_chat_message(
            event_id,
            sender_id,
            sender_name.clone(),
            timestamp,
            format!("{sender_name} 发起了通话邀请"),
            "m.call.invite",
        ),
        TimelineItemContent::RtcNotification { .. } => event_chat_message(
            event_id,
            sender_id,
            sender_name.clone(),
            timestamp,
            format!("{sender_name} 通话状态已变更"),
            "m.call.notification",
        ),
        _ => return None,
    };
    message.reactions = timeline_reactions(item);
    Some(message)
}
