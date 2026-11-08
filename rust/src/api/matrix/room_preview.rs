//! Room preview implementation.

use super::*;

pub(super) async fn room_name_event_id(room: &Room) -> Option<String> {
    let raw = room
        .get_state_event_static::<RoomNameEventContent>()
        .await
        .ok()
        .flatten()?;
    raw.deserialize().ok()?.event_id().map(ToString::to_string)
}

pub(super) async fn room_avatar_event_id(room: &Room) -> Option<String> {
    let raw = room
        .get_state_event_static::<RoomAvatarEventContent>()
        .await
        .ok()
        .flatten()?;
    raw.deserialize().ok()?.event_id().map(ToString::to_string)
}

pub(super) async fn room_topic_event_id(room: &Room) -> Option<String> {
    let raw = room
        .get_state_event_static::<RoomTopicEventContent>()
        .await
        .ok()
        .flatten()?;
    raw.deserialize().ok()?.event_id().map(ToString::to_string)
}

pub(super) async fn room_to_chat_room(
    room: &matrix_sdk::Room,
    ignored_user_ids: Option<&std::collections::HashSet<String>>,
    authoritative: bool,
) -> ChatRoom {
    let room_id = room.room_id().to_string();
    let mut name = room.name().filter(|n| !n.is_empty()).unwrap_or_default();
    if name.is_empty() {
        name = room
            .cached_display_name()
            .map(|dn| dn.to_string())
            .unwrap_or_default();
    }
    name = name.trim().to_string();
    if name.is_empty() {
        name = room_id.clone();
    }

    let avatar_url = room.avatar_url().map(|u| u.to_string());
    let (name_event_id, avatar_event_id) =
        tokio::join!(room_name_event_id(room), room_avatar_event_id(room));
    // `notification_count` is 0 for muted rooms (which would hide the
    // indicator entirely) AND for non-muted rooms whose unread messages do
    // not trigger notifications (default group push rules only count
    // mentions) or whose notification state was settled by another device's
    // receipt — which is not the same as THIS device having read them. So
    // whenever the server count is 0, fall back to the client-side unread
    // count (tracked from this device's own read marker, independent of
    // push rules): the badge then reflects this device's actual unread
    // state. The only inaccuracy is a brief, conservative "unread" while
    // our own read receipt's echo lags the server count by up to a sync
    // cycle — opening the room clears it.
    let notification_settings = notification_settings_for(
        &room.client(),
        &room
            .client()
            .user_id()
            .map(|id| id.to_string())
            .unwrap_or_default(),
        None,
    )
    .await;
    let is_muted = notification_settings
        .get_user_defined_room_notification_mode(room.room_id())
        .await
        == Some(matrix_sdk::notification_settings::RoomNotificationMode::Mute);
    let server_unread = room.unread_notification_counts().notification_count as i32;
    let unread_count = if server_unread > 0 {
        // Known limitation: the server-side count has no per-sender
        // dimension, so messages from ignored users still contribute to
        // the unread badge (the fallback below shares this for the same
        // reason).
        server_unread
    } else {
        // Known limitations of this client-side count
        // (`read_receipts.num_unread`): it has no per-sender breakdown, so
        // messages from ignored users still contribute to the unread
        // marker; and without any read receipt the SDK recounts the events
        // in the local cache window, so a room the user never opened shows
        // an approximate count bounded by that window (truncated when the
        // window is small), and a room with no cached events shows none.
        // The SDK does not expose the unread event senders to filter them
        // out here; the timeline itself and the preview text do hide
        // ignored senders.
        room.num_unread_messages() as i32
    };
    let is_marked_unread = effective_marked_unread(&room.client(), room).await;
    let (mut last_message, mut last_message_sender_id, last_message_time, last_event_id) =
        get_last_message_info(room);
    if let Some(sender_id) = last_message_sender_id.as_deref() {
        // The Dart ignore list comes in three freshness levels:
        // - authoritative (a confirmed write-through or a just-completed
        //   fetch): the list wins outright. The SDK store's sync echo can
        //   lag in either direction — after a confirmed un-ignore it may
        //   still report the sender as ignored, and merging would keep
        //   previews hidden indefinitely while offline.
        // - a merely persisted cache: union with the store, so the stale
        //   snapshot can neither re-expose a sender the store already hides
        //   (cross-device change, echo ahead of write-through) nor be
        //   overridden by it forever.
        // - no list at all (unknown): the store plus pending-write
        //   overrides are the only source.
        // Overrides are deliberately consulted ONLY in the unknown case:
        // they bridge the store lag for local writes (already covered by
        // the list otherwise), and a coalesced sync (false → true → false
        // reports only the final false) can leave an override stuck at its
        // baseline forever (ABA).
        let hidden = match ignored_user_ids {
            Some(list) if authoritative => list.contains(sender_id),
            Some(list) => {
                let store_ignored = match matrix_sdk::ruma::UserId::parse(sender_id) {
                    Ok(user_id) => room.client().is_user_ignored(&user_id).await,
                    Err(_) => false,
                };
                list.contains(sender_id) || store_ignored
            }
            None => match matrix_sdk::ruma::UserId::parse(sender_id) {
                Ok(user_id) => effective_is_user_ignored(&room.client(), &user_id).await,
                Err(_) => false,
            },
        };
        if hidden {
            last_message = "(消息已隐藏)".to_string();
            last_message_sender_id = None;
        }
    }
    let last_message_sender = if let Some(sender_id) = last_message_sender_id {
        let is_me = room
            .client()
            .user_id()
            .is_some_and(|user_id| user_id.as_str() == sender_id);
        if is_me {
            Some("我".to_string())
        } else {
            let fallback = sender_id
                .split(':')
                .next()
                .unwrap_or(&sender_id)
                .trim_start_matches('@')
                .to_string();
            match matrix_sdk::ruma::UserId::parse(&sender_id) {
                Ok(user_id) => room
                    .get_member_no_sync(&user_id)
                    .await
                    .ok()
                    .flatten()
                    .map(|member| member.name().to_string())
                    .or(Some(fallback)),
                Err(_) => Some(fallback),
            }
        }
    } else {
        None
    };
    let room_type = if room.is_space() {
        "space".to_string()
    } else {
        "group".to_string()
    };
    let is_encrypted = room
        .latest_encryption_state()
        .await
        .map(|state| state.is_encrypted())
        .unwrap_or(true);

    ChatRoom {
        id: room_id,
        name,
        avatar_url,
        name_event_id,
        avatar_event_id,
        last_message,
        last_message_sender,
        last_message_time,
        last_event_id,
        unread_count,
        is_marked_unread,
        room_type,
        is_encrypted,
        is_muted,
        room_state: room_state_label(room.state()).to_string(),
    }
}

pub(super) fn room_state_label(state: matrix_sdk::RoomState) -> &'static str {
    match state {
        matrix_sdk::RoomState::Joined => "joined",
        matrix_sdk::RoomState::Invited => "invited",
        matrix_sdk::RoomState::Knocked => "knocked",
        matrix_sdk::RoomState::Left => "left",
        matrix_sdk::RoomState::Banned => "banned",
    }
}

pub(super) fn room_display_name(room: &matrix_sdk::Room) -> String {
    let room_id = room.room_id().to_string();
    let mut name = room.name().filter(|n| !n.is_empty()).unwrap_or_default();
    if name.is_empty() {
        name = room
            .cached_display_name()
            .map(|dn| dn.to_string())
            .unwrap_or_default();
    }
    name = name.trim().to_string();
    if name.is_empty() {
        room_id
    } else {
        name
    }
}

pub(super) fn uint_to_i32(value: Option<matrix_sdk::ruma::UInt>) -> Option<i32> {
    value.map(|value| i32::try_from(u64::from(value)).unwrap_or(i32::MAX))
}

pub(super) fn image_info_dimensions(
    info: Option<&matrix_sdk::ruma::events::room::ImageInfo>,
) -> (Option<i32>, Option<i32>) {
    info.map(|info| (uint_to_i32(info.width), uint_to_i32(info.height)))
        .unwrap_or((None, None))
}

pub(super) fn sticker_info_dimensions(
    info: &matrix_sdk::ruma::events::room::ImageInfo,
) -> (Option<i32>, Option<i32>) {
    (uint_to_i32(info.width), uint_to_i32(info.height))
}

pub(super) fn get_last_message_info(
    room: &matrix_sdk::Room,
) -> (String, Option<String>, String, String) {
    let mut last_msg = "(暂无消息)".to_string();
    let mut last_time = String::new();
    let mut last_event_id = String::new();

    let latest_value = room.latest_event();
    if let matrix_sdk::latest_events::LatestEventValue::Remote(latest) = latest_value {
        let raw = latest.raw();
        if let Ok(any_ev) = raw.deserialize() {
            // Always record the latest event's timestamp for sorting, so that
            // rooms whose newest event isn't a text message (e.g. a reaction or
            // a state change) don't sink to the bottom of the list. The event
            // ID is the room's revision token: timestamps are millisecond
            // resolution and can collide between events.
            last_time = u64::from(any_ev.origin_server_ts().0).to_string();
            last_event_id = any_ev.event_id().to_string();

            if latest.kind.is_utd() {
                return (
                    "无法解密此消息".to_string(),
                    Some(any_ev.sender().to_string()),
                    last_time,
                    last_event_id,
                );
            }

            let sender_id = any_ev.sender().to_string();
            let preview = match any_ev {
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(msg),
                ) => msg
                    .as_original()
                    .and_then(|event| room_message_preview(&event.content)),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollStart(poll),
                ) => poll
                    .as_original()
                    .and_then(|event| unstable_poll_preview(&event.content)),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollResponse(
                        response,
                    ),
                ) => response
                    .as_original()
                    .map(|_| "[投票] 有人投票".to_string()),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollEnd(end),
                ) => end.as_original().map(|_| "[投票] 投票已结束".to_string()),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::Sticker(sticker),
                ) => sticker
                    .as_original()
                    .map(|o| format!("[贴纸] {}", o.content.body)),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::Reaction(_),
                ) => Some("❤️ 表情回应".to_string()),
                _ => None,
            };

            if let Some(mut text) = preview {
                if text.len() > 50 {
                    // Safe truncation that respects UTF-8 char boundaries
                    let mut end = 50;
                    while end > 0 && !text.is_char_boundary(end) {
                        end -= 1;
                    }
                    text.truncate(end);
                    text.push_str("...");
                }
                last_msg = text;
                return (last_msg, Some(sender_id), last_time, last_event_id);
            }
        }
    }

    (last_msg, None, last_time, last_event_id)
}

pub(super) fn room_message_preview(
    content: &matrix_sdk::ruma::events::room::message::RoomMessageEventContent,
) -> Option<String> {
    // An edit carries the new text in new_content, while its fallback body is
    // conventionally prefixed with "* ".
    if let Some(matrix_sdk::ruma::events::room::message::Relation::Replacement(replacement)) =
        &content.relates_to
    {
        if let Some(edited) = extract_edit_content(&replacement.new_content) {
            return Some(edited.body);
        }
    }

    match &content.msgtype {
        matrix_sdk::ruma::events::room::message::MessageType::Text(text) => {
            let is_reply = matches!(
                &content.relates_to,
                Some(matrix_sdk::ruma::events::room::message::Relation::Reply(_))
            );
            Some(if is_reply {
                strip_reply_fallback(&text.body)
            } else {
                text.body.clone()
            })
        }
        matrix_sdk::ruma::events::room::message::MessageType::Image(image) => {
            Some(format!("[图片] {}", image.body))
        }
        matrix_sdk::ruma::events::room::message::MessageType::Video(video) => {
            Some(format!("[视频] {}", video.filename()))
        }
        matrix_sdk::ruma::events::room::message::MessageType::File(file) => {
            Some(format!("[文件] {}", file.filename()))
        }
        matrix_sdk::ruma::events::room::message::MessageType::Audio(audio) => {
            Some(format!("[音频] {}", audio.filename()))
        }
        matrix_sdk::ruma::events::room::message::MessageType::Location(location) => {
            let label = if location.body.trim().is_empty() {
                &location.geo_uri
            } else {
                &location.body
            };
            Some(format!("[位置] {label}"))
        }
        matrix_sdk::ruma::events::room::message::MessageType::Emote(emote) => {
            Some(emote.body.clone())
        }
        _ => None,
    }
}

pub(super) fn unstable_poll_preview(
    content: &matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent,
) -> Option<String> {
    let question = content.poll_start().question.text.trim();
    (!question.is_empty()).then(|| format!("[投票] {question}"))
}
