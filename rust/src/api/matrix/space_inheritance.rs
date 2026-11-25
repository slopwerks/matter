use super::{ensure_account_matches, get_client, get_room_by_id, run_bounded};
use matrix_sdk::{
    deserialized_responses::{RawSyncOrStrippedState, SyncOrStrippedState},
    ruma::events::{
        space::{child::SpaceChildEventContent, parent::SpaceParentEventContent},
        SyncStateEvent,
    },
    Client, Room, RoomState,
};
use serde_json::Value;
use std::collections::HashSet;

struct Parent {
    space: Room,
    canonical: bool,
    content: Value,
}

async fn verified_parents(client: &Client, child: &Room) -> Result<Vec<Parent>, String> {
    let mut parents = Vec::new();
    if child.state() != RoomState::Joined {
        return Ok(parents);
    }
    for raw in child
        .get_state_events_static::<SpaceParentEventContent>()
        .await
        .map_err(|err| err.to_string())?
    {
        let RawSyncOrStrippedState::Sync(raw) = raw else {
            continue;
        };
        let Ok(SyncStateEvent::Original(event)) = raw.deserialize() else {
            continue;
        };
        if event.content.via.is_empty() {
            continue;
        }
        let Some(space) = client
            .get_room(&event.state_key)
            .filter(|space| space.is_space() && space.state() == RoomState::Joined)
        else {
            continue;
        };
        let reverse = space
            .get_state_event_static_for_key::<SpaceChildEventContent, _>(child.room_id())
            .await
            .map_err(|err| err.to_string())?;
        if matches!(reverse.and_then(|raw| raw.deserialize().ok()), Some(SyncOrStrippedState::Sync(SyncStateEvent::Original(event))) if !event.content.via.is_empty() && event.state_key == child.room_id())
        {
            if let Ok(Some(content)) = raw.get_field("content") {
                parents.push(Parent {
                    space,
                    canonical: event.content.canonical,
                    content,
                });
            }
        }
    }
    Ok(parents)
}

pub(super) async fn ancestors(client: &Client, child: &Room) -> Result<Vec<Room>, String> {
    let mut chain = Vec::new();
    let mut seen = HashSet::from([child.room_id().to_owned()]);
    for _ in 0..16 {
        let parents = verified_parents(client, chain.last().unwrap_or(child)).await?;
        let selected = parents
            .iter()
            .filter(|parent| parent.canonical)
            .min_by_key(|parent| parent.space.room_id())
            .or_else(|| {
                if parents.len() == 1 {
                    parents.first()
                } else {
                    None
                }
            });
        let Some(parent) = selected else { break };
        if !seen.insert(parent.space.room_id().to_owned()) {
            break;
        }
        chain.push(parent.space.clone());
    }
    Ok(chain)
}

pub(super) async fn set_canonical_space(
    account: String,
    space_id: String,
    room_id: String,
) -> Result<(), String> {
    let client = get_client().await.ok_or("当前账号未登录")?;
    ensure_account_matches(&client, &account)?;
    let child = get_room_by_id(&client, &room_id)?;
    run_bounded(async move {
        let mut parents = verified_parents(&client, &child).await?;
        let target = parents
            .iter()
            .position(|parent| parent.space.room_id().as_str() == space_id)
            .ok_or("请先确认已加入空间，且房间与空间的双向关系已同步")?;
        parents.swap(0, target);
        for mut parent in parents {
            let selected = parent.space.room_id().as_str() == space_id;
            if parent.canonical == selected {
                continue;
            }
            parent.content["canonical"] = selected.into();
            child
                .send_state_event_raw(
                    "m.space.parent",
                    parent.space.room_id().as_str(),
                    parent.content,
                )
                .await
                .map_err(|err| {
                    if selected {
                        format!("设置主空间失败：{err}")
                    } else {
                        format!("主空间已指定，但清除旧主空间失败，请重试：{err}")
                    }
                })?;
        }
        Ok(())
    })
    .await
}
