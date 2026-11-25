use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use matrix_sdk::ruma::serde::Raw;
use matrix_sdk::{Client, RoomState};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use tokio::sync::Mutex;

use super::{
    ensure_account_matches, get_client, get_room_by_id, notify_sync_event_for_generation,
    run_bounded_mutation, sticker_packs, Ordering, StickerPackKey, SyncEvent, SYNC_GENERATION,
};

pub(super) const STABLE: &str = "m.image_pack.rooms";
pub(super) const LEGACY: &str = "im.ponies.emote_rooms";
type Rooms = HashMap<String, HashSet<String>>;
type Changes = HashMap<(String, String), bool>;
type Pending = Arc<Mutex<HashMap<String, Changes>>>;
static PENDING: Lazy<Mutex<HashMap<String, Pending>>> = Lazy::new(Mutex::default);

async fn pending_for(user: &str) -> Pending {
    PENDING
        .lock()
        .await
        .entry(user.to_owned())
        .or_default()
        .clone()
}

pub(super) async fn clear_account(user: &str) {
    PENDING.lock().await.remove(user);
}

fn room_keys(content: &Value) -> Result<Rooms, String> {
    let mut result = Rooms::new();
    let object = content.as_object().ok_or("贴纸收藏格式无效")?;
    if let Some(rooms) = object.get("rooms") {
        for (room, packs) in rooms.as_object().ok_or("收藏房间列表格式无效")? {
            result.insert(
                room.clone(),
                packs
                    .as_object()
                    .ok_or("房间收藏列表格式无效")?
                    .keys()
                    .cloned()
                    .collect(),
            );
        }
    }
    Ok(result)
}

fn contains(rooms: &Rooms, room: &str, key: &str) -> bool {
    rooms.get(room).is_some_and(|packs| packs.contains(key))
}

pub(super) async fn effective(client: &Client) -> Result<Rooms, String> {
    let pending = pending_for(client.user_id().ok_or("未登录")?.as_str()).await;
    let pending = pending.lock().await;
    let mut result = Rooms::new();
    for kind in [STABLE, LEGACY] {
        let raw = client
            .account()
            .account_data_raw(kind.into())
            .await
            .map_err(|error| error.to_string())?;
        let mut rooms = match raw {
            Some(raw) => room_keys(
                &raw.deserialize_as_unchecked()
                    .map_err(|error| error.to_string())?,
            )?,
            None => Rooms::new(),
        };
        if let Some(changes) = pending.get(kind) {
            for ((room, key), collected) in changes {
                if *collected {
                    rooms.entry(room.clone()).or_default().insert(key.clone());
                } else if let Some(keys) = rooms.get_mut(room) {
                    keys.remove(key);
                }
            }
        }
        for (room, keys) in rooms {
            if !keys.is_empty() {
                result.entry(room).or_default().extend(keys);
            }
        }
    }
    Ok(result)
}

pub(super) async fn confirm_echo(user: &str, kind: &str, content: Value) {
    let Ok(rooms) = room_keys(&content) else {
        return;
    };
    let pending = pending_for(user).await;
    let mut pending = pending.lock().await;
    if let Some(changes) = pending.get_mut(kind) {
        changes.retain(|(room, key), desired| contains(&rooms, room, key) != *desired);
    }
}

fn edit(content: &mut Value, packs: &Rooms, collected: bool) -> Result<bool, String> {
    let previous = room_keys(content)?;
    let mut changed = false;
    for (room, keys) in packs {
        for key in keys {
            if contains(&previous, room, key) == collected {
                continue;
            }
            if collected {
                content["rooms"][room][key] = json!({});
            } else {
                let rooms = content["rooms"].as_object_mut().unwrap();
                let entries = rooms.get_mut(room).unwrap().as_object_mut().unwrap();
                entries.remove(key);
                if entries.is_empty() {
                    rooms.remove(room);
                }
            }
            changed = true;
        }
    }
    Ok(changed)
}

async fn update_kind(
    client: &Client,
    pending: &Pending,
    kind: &str,
    packs: &Rooms,
    collected: bool,
) -> Result<(), String> {
    let account = client.account();
    let raw = account
        .fetch_account_data(kind.into())
        .await
        .map_err(|error| error.to_string())?;
    let mut content = match raw {
        Some(raw) => raw
            .deserialize_as_unchecked()
            .map_err(|error| error.to_string())?,
        None => json!({}),
    };
    let changed = edit(&mut content, packs, collected)?;
    let mut pending = pending.lock().await;
    let local = account
        .account_data_raw(kind.into())
        .await
        .map_err(|error| error.to_string())?;
    let local = match local {
        Some(raw) => room_keys(
            &raw.deserialize_as_unchecked()
                .map_err(|error| error.to_string())?,
        )?,
        None => Rooms::new(),
    };
    if changed {
        let raw = Raw::from_json_string(content.to_string()).map_err(|error| error.to_string())?;
        account
            .set_account_data_raw(kind.into(), raw)
            .await
            .map_err(|error| error.to_string())?;
    }
    let changes = pending.entry(kind.to_owned()).or_default();
    for (room, keys) in packs {
        for key in keys {
            let identity = (room.clone(), key.clone());
            if changed
                || changes.contains_key(&identity)
                || contains(&local, room, key) != collected
            {
                changes.insert(identity, collected);
            }
        }
    }
    Ok(())
}

pub(super) async fn set_collected(
    user: String,
    packs: Vec<StickerPackKey>,
    collected: bool,
) -> Result<(), String> {
    let client = get_client().await.ok_or("未登录")?;
    ensure_account_matches(&client, &user)?;
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let mut requested = Rooms::new();
    for pack in packs {
        requested
            .entry(pack.room_id)
            .or_default()
            .insert(pack.state_key);
    }
    if requested.is_empty() {
        return Ok(());
    }
    run_bounded_mutation(
        format!("sticker-packs:{user}"),
        client.lifecycle_protection(),
        async move {
            if collected {
                for (room_id, keys) in &requested {
                    let room = get_room_by_id(&client, room_id)?;
                    if room.state() != RoomState::Joined
                        || sticker_packs::load_room_sticker_packs(&room, Some(keys))
                            .await?
                            .len()
                            != keys.len()
                    {
                        return Err(format!("贴纸包已失效或已离开房间 {room_id}"));
                    }
                }
            }
            let pending = pending_for(&user).await;
            let kinds = if collected {
                &[STABLE][..]
            } else {
                &[STABLE, LEGACY][..]
            };
            for (index, kind) in kinds.iter().enumerate() {
                update_kind(&client, &pending, kind, &requested, collected)
                    .await
                    .map_err(|error| {
                        if index > 0 {
                            format!("新版收藏已更新，旧版收藏更新失败，可重试：{error}")
                        } else {
                            format!("更新收藏失败 ({kind})：{error}")
                        }
                    })?;
                notify_sync_event_for_generation(generation, SyncEvent::StickerPacksChanged);
            }
            Ok(())
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::test_utils::mocks::MatrixMockServer;
    use wiremock::{
        matchers::{body_json, method, path_regex},
        Mock, ResponseTemplate,
    };

    #[tokio::test]
    async fn batch_removal_preserves_extensions_and_can_retry_the_failed_format() {
        let server = MatrixMockServer::new().await;
        let client = server.client_builder().build().await;
        let room = "!src:e";
        let keys = Rooms::from([(
            room.to_owned(),
            HashSet::from(["".to_owned(), "a:b".to_owned()]),
        )]);
        let pending = Pending::default();
        let before =
            json!({"extension": 1, "rooms": {room: {"": {}, "a:b": {}, "default": {"vendor": 2}}}});
        let after = json!({"extension": 1, "rooms": {room: {"default": {"vendor": 2}}}});
        for kind in [STABLE, LEGACY] {
            let path = format!("/account_data/{kind}$");
            Mock::given(method("GET"))
                .and(path_regex(&path))
                .respond_with(ResponseTemplate::new(200).set_body_json(&before))
                .mount(server.server())
                .await;
            let put = Mock::given(method("PUT"))
                .and(path_regex(&path))
                .and(body_json(&after));
            if kind == LEGACY {
                let failed = put
                    .respond_with(
                        ResponseTemplate::new(403)
                            .set_body_json(json!({"errcode":"M_FORBIDDEN","error":"denied"})),
                    )
                    .expect(1)
                    .mount_as_scoped(server.server())
                    .await;
                assert!(update_kind(&client, &pending, kind, &keys, false)
                    .await
                    .is_err());
                assert!(!pending.lock().await.contains_key(LEGACY));
                assert!(pending.lock().await.contains_key(STABLE));
                drop(failed);
            }
            Mock::given(method("PUT"))
                .and(path_regex(&path))
                .and(body_json(&after))
                .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
                .expect(1)
                .mount(server.server())
                .await;
            update_kind(&client, &pending, kind, &keys, false)
                .await
                .unwrap();
        }
    }

    #[tokio::test]
    async fn late_add_echo_does_not_undo_a_removal_or_cross_accounts() {
        let user = "@pending:localhost";
        let key = ("!room:e".to_owned(), "".to_owned());
        let pending = pending_for(user).await;
        pending
            .lock()
            .await
            .insert(STABLE.into(), Changes::from([(key.clone(), false)]));
        confirm_echo(user, STABLE, json!({"rooms":{"!room:e":{"":{}}}})).await;
        confirm_echo("@other:localhost", STABLE, json!({"rooms":{}})).await;
        confirm_echo(user, LEGACY, json!({"rooms":{}})).await;
        assert_eq!(pending.lock().await[STABLE][&key], false);
        confirm_echo(user, STABLE, json!({"rooms":{}})).await;
        assert!(pending.lock().await[STABLE].is_empty());
        clear_account(user).await;
    }
}
