//! Spaces implementation.

use super::*;

pub(super) async fn create_space(
    account_user_id: String,
    name: String,
    topic: Option<String>,
) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    // Mirror update_room_details / create_group_room: an empty name would
    // create a nameless space (the Dart callers already intercept, this is
    // defense in depth).
    let name = name.trim().to_owned();
    if name.is_empty() {
        return Err(api_err("rooms", "空间名称不能为空。".to_string()));
    }
    // Mirror update_space_details: trim the topic too (the Dart callers
    // already pass trimmed values; this is defense in depth).
    let topic = topic.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty());

    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.name = Some(name);
    request.topic = topic;
    let mut creation_content =
        matrix_sdk::ruma::api::client::room::create_room::v3::CreationContent::default();
    creation_content.room_type = Some(matrix_sdk::ruma::room::RoomType::Space);
    request.creation_content = Some(
        matrix_sdk::ruma::serde::Raw::new(&creation_content)
            .map_err(|e| api_err("rooms", format!("空间创建内容编码失败: {e}")))?,
    );

    // Bounded like the other P0 writes: the create request holds the client
    // lease.
    run_bounded(async move {
        let response = client
            .create_room(request)
            .await
            .map_err(|e| api_err("rooms", format!("创建空间失败: {e}")))?;

        app_log(
            "info",
            "rooms",
            format!("Created space: {}", response.room_id()),
        );
        info!("Created space: {}", response.room_id());
        Ok(response.room_id().to_string())
    })
    .await
}

pub(super) async fn get_spaces() -> Result<Vec<Space>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;

    // Bounded like the other P0 reads: the scan (room_to_chat_room per
    // room, including the notification-settings reads) holds the client
    // lease for its whole duration.
    run_bounded(async move {
        let mut spaces = Vec::new();
        for room in client.rooms() {
            if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
                continue;
            }
            let chat_room = room_to_chat_room(&room, None, false).await;
            spaces.push(Space {
                id: chat_room.id,
                name: chat_room.name,
                avatar_url: chat_room.avatar_url,
            });
        }

        spaces.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        Ok(spaces)
    })
    .await
}

pub(super) async fn get_space_details(space_id: String) -> Result<SpaceDetails, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;

    if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
        return Err(api_err(
            "spaces",
            format!("该空间不是已加入状态: {space_id}"),
        ));
    }

    let chat_room = room_to_chat_room(&room, None, false).await;
    let topic = room
        .topic()
        .map(|topic| topic.trim().to_string())
        .filter(|topic| !topic.is_empty());

    Ok(SpaceDetails {
        id: chat_room.id,
        name: chat_room.name,
        avatar_url: chat_room.avatar_url,
        topic,
    })
}

/// Extract the child room ID from an `m.space.child` state event. Events
/// without any `via` server cannot be joined reliably, so per the spec they
/// do not count as space children — this is the single predicate both
/// `get_space_children` and `get_ungrouped_rooms` use to decide that.
pub(super) fn space_child_room_id(
    child_event: matrix_sdk::deserialized_responses::SyncOrStrippedState<
        matrix_sdk::ruma::events::space::child::SpaceChildEventContent,
    >,
) -> Option<matrix_sdk::ruma::OwnedRoomId> {
    match child_event {
        matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
            matrix_sdk::ruma::events::SyncStateEvent::Original(event),
        ) if !event.content.via.is_empty() => Some(event.state_key),
        matrix_sdk::deserialized_responses::SyncOrStrippedState::Stripped(event)
            if event
                .content
                .via
                .as_ref()
                .is_some_and(|via| !via.is_empty()) =>
        {
            Some(event.state_key)
        }
        _ => None,
    }
}

pub(super) async fn get_space_children(
    space_id: String,
    ignored_user_ids: Option<Vec<String>>,
    authoritative: bool,
) -> Result<Vec<ChatRoom>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    let ignored_user_ids =
        ignored_user_ids.map(|ids| ids.into_iter().collect::<std::collections::HashSet<_>>());

    // Bounded like the other P0 reads: the per-child room_to_chat_room
    // (notification settings, members_no_sync) holds the client lease for
    // the whole scan.
    run_bounded(async move {
        let space_room = client
            .get_room(
                &matrix_sdk::ruma::RoomId::parse(space_id.clone())
                    .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?,
            )
            .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;

        let child_events = space_room
            .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
            .await
            .map_err(|e| api_err("spaces", format!("加载空间子房间失败: {e}")))?;

        let mut child_rooms = Vec::new();
        for raw_child in child_events {
            let Ok(child_event) = raw_child.deserialize() else {
                continue;
            };
            let Some(child_room_id) = space_child_room_id(child_event) else {
                continue;
            };

            let Some(child_room) = client.get_room(&child_room_id) else {
                continue;
            };
            if child_room.state() != matrix_sdk::RoomState::Joined {
                continue;
            }

            let mut chat_room =
                room_to_chat_room(&child_room, ignored_user_ids.as_ref(), authoritative).await;
            if !child_room.is_space() {
                // Mirror the main chat list's DM classification (m.direct OR
                // the member-count heuristic): a DM created by the other
                // party has no m.direct entry here and would otherwise show
                // as a group inside the space.
                chat_room.room_type = if matches!(child_room.is_direct().await, Ok(true))
                    || is_dm_by_members(&child_room).await
                {
                    "dm".to_string()
                } else {
                    "group".to_string()
                };
            }
            child_rooms.push(chat_room);
        }

        child_rooms.sort_by(|a, b| {
            let a_time = a.last_message_time.parse::<u64>().unwrap_or_default();
            let b_time = b.last_message_time.parse::<u64>().unwrap_or_default();
            b_time
                .cmp(&a_time)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(child_rooms)
    })
    .await
}

pub(super) async fn update_space_details(
    account_user_id: String,
    space_id: String,
    name: String,
    topic: Option<String>,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;

    if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
        return Err(api_err(
            "spaces",
            format!("该空间不是已加入状态: {space_id}"),
        ));
    }

    let trimmed_name = name.trim().to_string();
    if trimmed_name.is_empty() {
        return Err(api_err("spaces", "空间名称不能为空。".to_string()));
    }

    // Bounded like the other P0 writes: two sequential state writes hold the
    // client lease.
    run_bounded(async move {
        room.set_name(trimmed_name)
            .await
            .map_err(|e| api_err("spaces", format!("更新空间名称失败: {e}")))?;
        notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);

        let normalized_topic = topic.unwrap_or_default().trim().to_string();
        // Write unconditionally: comparing against room.topic() would use
        // the SDK snapshot, which may still predate a just-completed write
        // and silently drop a quick A -> B -> A change (same decision as
        // `update_room_details`). The write is an idempotent state event.
        room.set_room_topic(&normalized_topic).await.map_err(|e| {
            // The name write above already landed: say so instead of
            // reporting a plain whole-action failure.
            api_err("spaces", format!("空间名称已更新，但主题更新失败: {e}"))
        })?;
        notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);

        app_log(
            "info",
            "rooms",
            format!("Updated space details: {}", space_id),
        );
        info!("Updated space details: {}", space_id);
        Ok(())
    })
    .await?;
    Ok(())
}

pub(super) async fn add_room_to_space(
    account_user_id: String,
    space_id: String,
    room_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let child_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的房间 ID: {e}")))?;

    let space_room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;
    let child_room = client
        .get_room(&child_room_id)
        .ok_or_else(|| api_err("spaces", format!("房间不存在: {room_id}")))?;

    let via = vec![client
        .user_id()
        .ok_or_else(|| api_err("spaces", "No active user.".to_string()))?
        .server_name()
        .to_owned()];
    let current_user_id = client
        .user_id()
        .ok_or_else(|| api_err("spaces", "No active user.".to_string()))?
        .to_owned();

    // Bounded like the other P0 writes: two sequential state writes hold the
    // client lease.
    run_bounded(async move {
        let can_set_parent = match child_room.power_levels().await {
            Ok(power_levels) => {
                power_levels.user_can_send_state(&current_user_id, StateEventType::SpaceParent)
            }
            Err(error) => {
                app_log(
                    "warn",
                    "rooms",
                    format!(
                        "Unable to check child-room power levels; skipping parent link: {error}"
                    ),
                );
                false
            }
        };
        space_room
            .send_state_event_for_key(
                &child_room_id,
                matrix_sdk::ruma::events::space::child::SpaceChildEventContent::new(via.clone()),
            )
            .await
            .map_err(|e| api_err("spaces", format!("将房间加入空间失败: {e}")))?;
        notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);

        if can_set_parent {
            child_room
                .send_state_event_for_key(
                    &space_room_id,
                    matrix_sdk::ruma::events::space::parent::SpaceParentEventContent::new(via),
                )
                .await
                .map_err(|e| {
                    // The child relation already landed: say so instead of
                    // reporting a plain whole-action failure (same
                    // partial-success discipline as update_space_details; a
                    // retry converges — the child write is done).
                    api_err("spaces", format!("已加入空间，但设置空间父级失败: {e}"))
                })?;
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        }

        app_log(
            "info",
            "rooms",
            format!("Added room {} to space {}", room_id, space_id),
        );
        info!("Added room {} to space {}", room_id, space_id);
        Ok(())
    })
    .await?;
    Ok(())
}

pub(super) async fn remove_room_from_space(
    account_user_id: String,
    space_id: String,
    room_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let child_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的房间 ID: {e}")))?;

    let space_room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;
    let child_room = client
        .get_room(&child_room_id)
        .ok_or_else(|| api_err("spaces", format!("房间不存在: {room_id}")))?;
    let current_user_id = client
        .user_id()
        .ok_or_else(|| api_err("spaces", "No active user.".to_string()))?
        .to_owned();

    // Bounded like the other P0 writes: the state reads and writes hold
    // the client lease.
    run_bounded(async move {
        let child_events = space_room
            .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
            .await
            .map_err(|e| api_err("spaces", format!("加载空间子房间失败: {e}")))?;
        let space_child_event_id = child_events.into_iter().find_map(|raw_child| {
            let Ok(child_event) = raw_child.deserialize() else {
                return None;
            };
            match child_event {
                matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
                    matrix_sdk::ruma::events::SyncStateEvent::Original(event),
                ) if event.state_key == child_room_id => Some(event.event_id),
                _ => None,
            }
        });

        let parent_events = child_room
            .get_state_events_static::<matrix_sdk::ruma::events::space::parent::SpaceParentEventContent>()
            .await
            .map_err(|e| api_err("spaces", format!("加载空间父级失败: {e}")))?;
        let space_parent_event_id = parent_events.into_iter().find_map(|raw_parent| {
            let Ok(parent_event) = raw_parent.deserialize() else {
                return None;
            };
            match parent_event {
                matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
                    matrix_sdk::ruma::events::SyncStateEvent::Original(event),
                ) if event.state_key == space_room_id => Some(event.event_id),
                _ => None,
            }
        });

        let can_remove_parent = match child_room.power_levels().await {
            Ok(power_levels) => {
                power_levels.user_can_send_state(&current_user_id, StateEventType::SpaceParent)
            }
            Err(error) => {
                app_log(
                    "warn",
                    "rooms",
                    format!(
                        "Unable to check child-room power levels; skipping parent cleanup: {error}"
                    ),
                );
                false
            }
        };

        let relationship_found = space_child_event_id.is_some() || space_parent_event_id.is_some();
        let mut child_removed = false;
        if space_child_event_id.is_some() {
            space_room
                .send_state_event_raw(
                    "m.space.child",
                    child_room_id.as_str(),
                    serde_json::json!({}),
                )
                .await
                .map_err(|e| api_err("spaces", format!("将房间移出空间失败: {e}")))?;
            child_removed = true;
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        }

        if space_parent_event_id.is_some() && can_remove_parent {
            child_room
                .send_state_event_raw(
                    "m.space.parent",
                    space_room_id.as_str(),
                    serde_json::json!({}),
                )
                .await
                .map_err(|e| {
                    // The child side may already be gone: say so instead of
                    // reporting a plain whole-action failure (same
                    // partial-success discipline as update_space_details;
                    // a retry converges — the child link is already empty).
                    if child_removed {
                        api_err("spaces", format!("已从空间移除，但父级关系清理失败: {e}"))
                    } else {
                        api_err("spaces", format!("移除空间父级关系失败: {e}"))
                    }
                })?;
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        } else if space_parent_event_id.is_some() {
            app_log(
                "warn",
                "rooms",
                "Skipping parent cleanup without child-room permission.".to_string(),
            );
        }

        if !relationship_found {
            // Neither direction of the relationship is known locally: the
            // child/parent events may not have synced here yet (created on
            // another device, or one-directional). Fail closed like the
            // knock actions — the UI must not claim "已从空间移除" while
            // the server relationship survives.
            return Err(api_err("spaces", "未能找到空间关系，请刷新后重试".to_string()));
        }

        app_log(
            "info",
            "rooms",
            format!("Removed room {} from space {}", room_id, space_id),
        );
        info!("Removed room {} from space {}", room_id, space_id);
        Ok(())
    })
    .await?;
    Ok(())
}

pub(super) async fn leave_space(account_user_id: String, space_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;

    if !room.is_space() {
        return Err(api_err("spaces", format!("该房间不是空间: {space_id}")));
    }

    run_bounded(async move {
        room.leave()
            .await
            .map_err(|e| api_err("spaces", format!("退出空间失败: {e}")))?;
        Ok(())
    })
    .await?;

    app_log("info", "rooms", format!("Left space: {}", space_id));
    info!("Left space: {}", space_id);
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

pub(super) async fn get_ungrouped_rooms(
    ignored_user_ids: Option<Vec<String>>,
    authoritative: bool,
) -> Result<Vec<ChatRoom>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    let ignored_user_ids =
        ignored_user_ids.map(|ids| ids.into_iter().collect::<std::collections::HashSet<_>>());

    // Bounded like the other P0 reads: the double room scan (space children
    // state reads + per-room room_to_chat_room) holds the client lease for
    // its whole duration.
    run_bounded(async move {
        let mut grouped_room_ids = std::collections::HashSet::new();
        for room in client.rooms() {
            if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
                continue;
            }

            let child_events = room
                .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
                .await
                .map_err(|e| api_err("spaces", format!("加载空间子房间失败: {e}")))?;

            for raw_child in child_events {
                let Ok(child_event) = raw_child.deserialize() else {
                    continue;
                };
                // Same predicate as get_space_children: a child event without
                // any `via` server doesn't group the room, so the room stays
                // visible in this ungrouped list.
                if let Some(child_room_id) = space_child_room_id(child_event) {
                    grouped_room_ids.insert(child_room_id);
                }
            }
        }

        let mut rooms = Vec::new();
        for room in client.rooms() {
            if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
                continue;
            }

            // Exclude DMs with the SAME classification the main chat list
            // uses (m.direct OR the member-count heuristic): a DM created
            // by the other party has no m.direct entry here, and would
            // otherwise show up in both the chat list and this ungrouped
            // list.
            if matches!(room.is_direct().await, Ok(true)) || is_dm_by_members(&room).await {
                continue;
            }

            if grouped_room_ids.contains(room.room_id()) {
                continue;
            }

            let mut chat_room =
                room_to_chat_room(&room, ignored_user_ids.as_ref(), authoritative).await;
            chat_room.room_type = "group".to_string();
            rooms.push(chat_room);
        }

        rooms.sort_by(|a, b| {
            let a_time = a.last_message_time.parse::<u64>().unwrap_or_default();
            let b_time = b.last_message_time.parse::<u64>().unwrap_or_default();
            b_time
                .cmp(&a_time)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(rooms)
    })
    .await
}
