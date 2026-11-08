//! Sdk state events adaptation.
use super::*;

pub(in crate::api::matrix) fn event_chat_message(
    event_id: String,
    sender_id: String,
    sender_name: String,
    timestamp: String,
    content: String,
    mime_type: &'static str,
) -> ChatMessage {
    ChatMessage {
        id: event_id,
        sender_id,
        sender_name,
        content,
        formatted_body: None,
        caption: None,
        caption_formatted_body: None,
        shared_caption: None,
        image_metadata: None,
        mentioned_user_ids: Vec::new(),
        mentions_room: false,
        timestamp,
        is_me: false,
        msg_type: MessageType::Event,
        image_url: None,
        media_source_json: None,
        image_width: None,
        image_height: None,
        filename: None,
        file_size: None,
        mime_type: Some(mime_type.to_string()),
        duration_ms: None,
        geo_uri: None,
        poll: None,
        in_reply_to: None,
        is_edited: false,
        edit_history: Vec::new(),
        reactions: Vec::new(),
        readers: Vec::new(),
        total_members: 0,
    }
}

pub(in crate::api::matrix) fn membership_info(
    change: &RoomMembershipChange,
) -> Option<(String, &'static str)> {
    let name = change
        .display_name()
        .unwrap_or_else(|| change.user_id().localpart().to_owned());
    let change_type = change.change()?;
    let (label, mime) = match change_type {
        MembershipChange::Joined => (format!("{name} 加入了房间"), "m.room.member:join"),
        MembershipChange::InvitationAccepted => {
            (format!("{name} 接受了邀请并加入房间"), "m.room.member:join")
        }
        MembershipChange::Left => (format!("{name} 离开了房间"), "m.room.member:leave"),
        MembershipChange::Kicked => (format!("{name} 被移出房间"), "m.room.member:kick"),
        MembershipChange::Banned => (format!("{name} 被封禁"), "m.room.member:ban"),
        MembershipChange::KickedAndBanned => (format!("{name} 被移出并封禁"), "m.room.member:ban"),
        MembershipChange::Unbanned => (format!("{name} 被解除封禁"), "m.room.member:unban"),
        MembershipChange::Invited => (
            format!("{name} 收到了加入房间的邀请"),
            "m.room.member:invite",
        ),
        MembershipChange::InvitationRejected => {
            (format!("{name} 拒绝了加入邀请"), "m.room.member:leave")
        }
        MembershipChange::InvitationRevoked => {
            (format!("{name} 的邀请已被撤回"), "m.room.member:leave")
        }
        MembershipChange::Knocked => (format!("{name} 请求加入房间"), "m.room.member:knock"),
        MembershipChange::KnockAccepted => {
            (format!("{name} 的入群请求已通过"), "m.room.member:join")
        }
        MembershipChange::KnockRetracted => {
            (format!("{name} 撤回了入群请求"), "m.room.member:knock")
        }
        MembershipChange::KnockDenied => {
            (format!("{name} 的入群请求被拒绝"), "m.room.member:knock")
        }
        _ => return None,
    };
    Some((label, mime))
}

pub(in crate::api::matrix) fn profile_change_info(
    change: &MemberProfileChange,
    sender_name: &str,
) -> Option<(String, &'static str)> {
    let name = sender_name;
    let avatar_change = change.avatar_url_change();
    let name_change = change.displayname_change();

    match (avatar_change, name_change) {
        (Some(avatar), Some(name_c)) => {
            let avatar_desc = if avatar.new.is_some() {
                if avatar.old.is_some() {
                    "更换了头像"
                } else {
                    "设置了头像"
                }
            } else {
                "移除了头像"
            };

            let name_desc = if let Some(new_name) = &name_c.new {
                format!("并将昵称更改为: {new_name}")
            } else {
                "并清除了昵称".to_string()
            };

            Some((
                format!("{name} {avatar_desc}{name_desc}"),
                "m.room.member:avatar",
            ))
        }
        (Some(avatar), None) => {
            let avatar_desc = if avatar.new.is_some() {
                if avatar.old.is_some() {
                    "更换了头像"
                } else {
                    "设置了头像"
                }
            } else {
                "移除了头像"
            };
            Some((format!("{name} {avatar_desc}"), "m.room.member:avatar"))
        }
        (None, Some(name_c)) => {
            let name_desc = if let Some(new_name) = &name_c.new {
                if let Some(old_name) = &name_c.old {
                    format!("{old_name} 将昵称更改为: {new_name}")
                } else {
                    format!("{name} 将昵称更改为: {new_name}")
                }
            } else {
                format!("{name} 清除了昵称")
            };
            Some((name_desc, "m.room.member:displayname"))
        }
        (None, None) => None,
    }
}

pub(in crate::api::matrix) fn other_state_info(
    other: &OtherState,
    sender_name: &str,
    item: &EventTimelineItem,
) -> Option<(String, &'static str)> {
    match other.content() {
        AnyOtherStateEventContentChange::RoomAvatar(c) => {
            let text = match c {
                StateEventContentChange::Original { content, .. } => {
                    if content.url.is_some() {
                        format!("{sender_name} 更改了房间头像")
                    } else {
                        format!("{sender_name} 移除了房间头像")
                    }
                }
                _ => "房间头像已更改".to_owned(),
            };
            Some((text, "m.room.avatar"))
        }
        AnyOtherStateEventContentChange::RoomName(c) => {
            let text = match c {
                StateEventContentChange::Original { content, .. } => {
                    if content.name.trim().is_empty() {
                        format!("{sender_name} 清除了房间名称")
                    } else {
                        format!("{sender_name} 将房间名称更改为: {}", content.name)
                    }
                }
                _ => "房间名称已更改".to_owned(),
            };
            Some((text, "m.room.name"))
        }
        AnyOtherStateEventContentChange::RoomTopic(c) => {
            let text = match c {
                StateEventContentChange::Original { content, .. } => {
                    if content.topic.trim().is_empty() {
                        format!("{sender_name} 清除了房间主题")
                    } else {
                        format!("{sender_name} 将房间主题更改为: {}", content.topic)
                    }
                }
                _ => "房间主题已更改".to_owned(),
            };
            Some((text, "m.room.topic"))
        }
        AnyOtherStateEventContentChange::RoomEncryption(_) => {
            Some(("已启用端到端加密".to_owned(), "m.room.encryption"))
        }
        AnyOtherStateEventContentChange::RoomCreate(_) => {
            Some(("房间已创建".to_owned(), "m.room.create"))
        }
        AnyOtherStateEventContentChange::RoomJoinRules(c) => {
            let text = match c {
                StateEventContentChange::Original { content, .. } => match content.join_rule {
                    matrix_sdk::ruma::events::room::join_rules::JoinRule::Public => {
                        format!("{sender_name} 将加入规则更改为: 公开")
                    }
                    matrix_sdk::ruma::events::room::join_rules::JoinRule::Invite => {
                        format!("{sender_name} 将加入规则更改为: 仅邀请")
                    }
                    matrix_sdk::ruma::events::room::join_rules::JoinRule::Knock => {
                        format!("{sender_name} 将加入规则更改为: 允许申请加入")
                    }
                    _ => format!("{sender_name} 更改了加入规则"),
                },
                _ => "加入规则已更改".to_owned(),
            };
            Some((text, "m.room.join_rules"))
        }
        AnyOtherStateEventContentChange::RoomPowerLevels(_) => Some((
            format!("{sender_name} 更改了房间权限"),
            "m.room.power_levels",
        )),
        AnyOtherStateEventContentChange::RoomPinnedEvents(_) => Some((
            format!("{sender_name} 更改了置顶消息"),
            "m.room.pinned_events",
        )),
        AnyOtherStateEventContentChange::RoomHistoryVisibility(c) => {
            let text = match c {
                StateEventContentChange::Original { content, .. } => {
                    match content.history_visibility {
                        matrix_sdk::ruma::events::room::history_visibility::HistoryVisibility::WorldReadable => {
                            format!("{sender_name} 将历史记录设置为所有人可见")
                        }
                        matrix_sdk::ruma::events::room::history_visibility::HistoryVisibility::Shared => {
                            format!("{sender_name} 将历史记录设置为对所有成员可见")
                        }
                        matrix_sdk::ruma::events::room::history_visibility::HistoryVisibility::Invited => {
                            format!("{sender_name} 将历史记录设置为受邀后可见")
                        }
                        matrix_sdk::ruma::events::room::history_visibility::HistoryVisibility::Joined => {
                            format!("{sender_name} 将历史记录设置为加入后可见")
                        }
                        _ => format!("{sender_name} 更改了历史记录可见性"),
                    }
                }
                _ => "历史记录可见性已更改".to_owned(),
            };
            Some((text, "m.room.history_visibility"))
        }
        AnyOtherStateEventContentChange::RoomTombstone(_) => {
            Some(("该房间已停用并升级至新房间".to_owned(), "m.room.tombstone"))
        }
        AnyOtherStateEventContentChange::RoomCanonicalAlias(c) => {
            let text = match c {
                StateEventContentChange::Original { content, .. } => {
                    if let Some(alias) = &content.alias {
                        format!("{sender_name} 将房间主要别名更改为: {alias}")
                    } else {
                        format!("{sender_name} 更改了房间别名")
                    }
                }
                _ => "房间别名已更改".to_owned(),
            };
            Some((text, "m.room.canonical_alias"))
        }
        AnyOtherStateEventContentChange::RoomServerAcl(_) => Some((
            "房间服务器访问控制列表已更改".to_owned(),
            "m.room.server_acl",
        )),
        AnyOtherStateEventContentChange::RoomThirdPartyInvite(c) => {
            let text = match c {
                StateEventContentChange::Original { content, .. } => {
                    format!("{sender_name} 邀请了 {}", content.display_name)
                }
                _ => format!("{sender_name} 发送了第三方邀请"),
            };
            Some((text, "m.room.third_party_invite"))
        }
        _ => state_event_label(item).map(|label| (label, "m.room.state")),
    }
}

pub(in crate::api::matrix) fn state_event_label(item: &EventTimelineItem) -> Option<String> {
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
