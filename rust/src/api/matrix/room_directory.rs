//! Public room discovery and resolution of shared Matrix addresses.
use super::*;
use matrix_sdk::ruma::{
    api::client::directory::get_public_rooms_filtered, matrix_uri::MatrixId, MatrixToUri,
    MatrixUri, OwnedRoomOrAliasId, OwnedServerName, RoomId, RoomOrAliasId, ServerName,
};

async fn account(user: &str) -> Result<ClientLease, String> {
    let client = get_client().await.ok_or("请先登录")?;
    ensure_account_matches(&client, user)?;
    Ok(client)
}

pub(super) async fn search(
    user: String,
    query: String,
    since: Option<String>,
) -> Result<DirectoryRoomPage, String> {
    let client = account(&user).await?;
    let mut request = get_public_rooms_filtered::v3::Request::new();
    request.limit = Some(30u32.into());
    request.since = since;
    if !query.is_empty() {
        request.filter.generic_search_term = Some(query);
    }
    run_bounded(async move {
        let response = client
            .public_rooms_filtered(request)
            .await
            .map_err(|e| format!("无法读取公开房间目录：{e}"))?;
        let rooms = response
            .chunk
            .into_iter()
            .map(|r| DirectoryRoom {
                state: client
                    .get_room(&r.room_id)
                    .map(|room| room_preview::room_state_label(room.state()))
                    .unwrap_or("left")
                    .into(),
                id: r.room_id.to_string(),
                name: r.name,
                alias: r.canonical_alias.map(|a| a.to_string()),
                avatar_url: r.avatar_url.map(|a| a.to_string()),
                topic: r.topic,
                is_space: r.room_type.is_some_and(|t| t.as_str() == "m.space"),
                join_rule: Some(r.join_rule.to_string()),
                via: Vec::new(),
            })
            .collect();
        Ok(DirectoryRoomPage {
            rooms,
            next: response.next_batch,
        })
    })
    .await
}

fn link_target(
    id: &MatrixId,
    via: &[OwnedServerName],
) -> Result<(OwnedRoomOrAliasId, Vec<OwnedServerName>), String> {
    let room = match id {
        MatrixId::Room(id) => id.clone().into(),
        MatrixId::RoomAlias(alias) => alias.clone().into(),
        MatrixId::Event(room, _) => room.clone(),
        _ => return Err("请输入房间链接".into()),
    };
    Ok((room, via.to_vec()))
}

fn target(input: &str) -> Result<(OwnedRoomOrAliasId, Vec<OwnedServerName>), String> {
    if let Ok(uri) = MatrixToUri::parse(input) {
        return link_target(uri.id(), uri.via());
    }
    if let Ok(uri) = MatrixUri::parse(input) {
        return link_target(uri.id(), uri.via());
    }
    RoomOrAliasId::parse(input)
        .map(|room| (room, vec![]))
        .map_err(|_| "请输入有效的房间 ID、别名或 Matrix 链接".into())
}

pub(super) async fn preview(user: String, address: String) -> Result<DirectoryRoom, String> {
    let (target, mut via) = target(address.trim())?;
    let client = account(&user).await?;
    run_bounded(async move {
        let id = match <&RoomId>::try_from(&*target) {
            Ok(id) => id.to_owned(),
            Err(alias) => {
                let resolved = client
                    .resolve_room_alias(alias)
                    .await
                    .map_err(|e| format!("无法解析房间别名：{e}"))?;
                for server in resolved.servers {
                    if !via.contains(&server) {
                        via.push(server);
                    }
                }
                resolved.room_id
            }
        };
        if via.is_empty() {
            via.extend(id.server_name().map(ToOwned::to_owned));
        }
        let known = client.get_room(&id);
        let summary = client
            .get_room_preview(&OwnedRoomOrAliasId::from(id.clone()), via.clone())
            .await;
        // Invite-only rooms may withhold their summary. An exact ID or resolved
        // alias still identifies the target of an explicit membership request.
        let s = summary.ok();
        let state = known
            .as_ref()
            .map(|r| r.state())
            .or_else(|| s.as_ref().and_then(|r| r.state));
        let mut room = DirectoryRoom {
            id: id.to_string(),
            name: None,
            alias: target.as_str().starts_with('#').then(|| target.to_string()),
            topic: None,
            avatar_url: None,
            is_space: known.as_ref().is_some_and(|r| r.is_space()),
            state: state
                .map(room_preview::room_state_label)
                .unwrap_or("left")
                .into(),
            join_rule: None,
            via: via.into_iter().map(|v| v.to_string()).collect(),
        };
        if let Some(s) = s {
            room.name = s.name;
            room.alias = s.canonical_alias.map(|a| a.to_string()).or(room.alias);
            room.topic = s.topic;
            room.avatar_url = s.avatar_url.map(|a| a.to_string());
            room.is_space = s.room_type.is_some_and(|t| t.as_str() == "m.space");
            room.join_rule = s.join_rule.map(|r| r.kind().to_string());
        }
        Ok(room)
    })
    .await
}

pub(super) async fn enter(
    user: String,
    room_id: String,
    via: Vec<String>,
    knock: bool,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let room = RoomId::parse(room_id).map_err(|e| e.to_string())?;
    let servers = via
        .into_iter()
        .map(ServerName::parse)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    let client = account(&user).await?;
    run_bounded(async move {
        if knock {
            client.knock(room.into(), None, servers).await
        } else {
            client
                .join_room_by_id_or_alias(&OwnedRoomOrAliasId::from(room), &servers)
                .await
        }
        .map_err(|e| format!("房间操作失败：{e}"))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}
