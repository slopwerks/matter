use std::collections::{BTreeMap, BTreeSet, HashSet};

use super::{api_err, room_display_name, sticker_collection, uint_to_i32, Sticker, StickerPack};
use matrix_sdk::{
    deserialized_responses::SyncOrStrippedState,
    ruma::events::{
        macros::EventContent,
        room::image_pack::{ImagePackImage, ImagePackMeta, PackUsage, RoomImagePackEventContent},
        SyncStateEvent,
    },
    Client, Room,
};
use serde::{Deserialize, Serialize};

// Ruma 0.35 removed the MSC2545 types. Keep the room format readable until
// existing rooms migrate their state to m.room.image_pack.
#[derive(Clone, Debug, Deserialize, Serialize, EventContent)]
#[ruma_event(type = "im.ponies.room_emotes", kind = State, state_key_type = String)]
struct LegacyRoomImagePackEventContent {
    images: BTreeMap<String, LegacyPackImage>,
    pack: Option<ImagePackMeta>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct LegacyPackImage {
    #[serde(flatten)]
    image: ImagePackImage,
    #[serde(default)]
    usage: BTreeSet<PackUsage>,
}

fn usage_allows_sticker(usage: &BTreeSet<PackUsage>) -> bool {
    usage.is_empty() || usage.contains(&PackUsage::Sticker)
}

fn pack_image_to_sticker(shortcode: String, image: ImagePackImage) -> Sticker {
    let body = image
        .body
        .as_deref()
        .map(str::trim)
        .filter(|body| !body.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| shortcode.clone());
    let image_url = image.url.to_string();
    let thumbnail_url = None;
    let mime_type = image.info.as_ref().and_then(|info| info.mimetype.clone());
    let width = image.info.as_ref().and_then(|info| uint_to_i32(info.width));
    let height = image
        .info
        .as_ref()
        .and_then(|info| uint_to_i32(info.height));

    Sticker {
        id: shortcode.clone(),
        shortcode,
        body,
        image_url,
        thumbnail_url,
        mime_type,
        width,
        height,
    }
}

fn room_image_pack_to_sticker_pack(
    room: &Room,
    state_key: String,
    pack: ImagePackMeta,
    mut stickers: Vec<Sticker>,
) -> Option<StickerPack> {
    if stickers.is_empty() {
        return None;
    }
    stickers.sort_by_key(|a| a.body.to_lowercase());

    let title = pack
        .display_name
        .as_deref()
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| {
            let trimmed = state_key.trim();
            if trimmed.is_empty() {
                room_display_name(room)
            } else {
                trimmed.to_string()
            }
        });
    let avatar_url = pack
        .avatar_url
        .as_ref()
        .map(ToString::to_string)
        .or_else(|| room.avatar_url().map(|url| url.to_string()));
    Some(StickerPack {
        id: serde_json::json!([room.room_id(), state_key]).to_string(),
        room_id: room.room_id().to_string(),
        state_key,
        collected: false,
        title,
        avatar_url,
        source: "room".to_string(),
        stickers,
    })
}

pub(super) async fn load_room_sticker_packs(
    room: &Room,
    enabled_state_keys: Option<&HashSet<String>>,
) -> Result<Vec<StickerPack>, String> {
    let load_error = |error| {
        api_err(
            "rooms",
            format!(
                "Failed to load sticker packs for room {}: {error}",
                room.room_id()
            ),
        )
    };
    let stable_events = room
        .get_state_events_static::<RoomImagePackEventContent>()
        .await
        .map_err(load_error)?;
    let legacy_events = room
        .get_state_events_static::<LegacyRoomImagePackEventContent>()
        .await
        .map_err(load_error)?;

    let mut packs = Vec::new();
    let mut seen_state_keys = HashSet::new();
    // Prefer the stable event when a room publishes both formats for one key.
    for raw in stable_events {
        let Ok(SyncOrStrippedState::Sync(SyncStateEvent::Original(event))) = raw.deserialize()
        else {
            continue;
        };
        if enabled_state_keys.is_some_and(|keys| !keys.contains(&event.state_key)) {
            continue;
        }
        seen_state_keys.insert(event.state_key.clone());
        let content = event.content;
        let stickers = if usage_allows_sticker(&content.pack.usage) {
            content
                .images
                .into_iter()
                .map(|(key, image)| pack_image_to_sticker(key, image))
                .collect()
        } else {
            Vec::new()
        };
        if let Some(pack) =
            room_image_pack_to_sticker_pack(room, event.state_key.clone(), content.pack, stickers)
        {
            packs.push(pack);
        }
    }
    for raw in legacy_events {
        let Ok(SyncOrStrippedState::Sync(SyncStateEvent::Original(event))) = raw.deserialize()
        else {
            continue;
        };
        if seen_state_keys.contains(&event.state_key)
            || enabled_state_keys.is_some_and(|keys| !keys.contains(&event.state_key))
        {
            continue;
        }
        let content = event.content;
        let pack = content.pack.unwrap_or_default();
        let pack_allows_sticker = usage_allows_sticker(&pack.usage);
        let stickers = content
            .images
            .into_iter()
            .filter_map(|(key, image)| {
                let allows_sticker = if image.usage.is_empty() {
                    pack_allows_sticker
                } else {
                    usage_allows_sticker(&image.usage)
                };
                allows_sticker.then(|| pack_image_to_sticker(key, image.image))
            })
            .collect();
        if let Some(pack) = room_image_pack_to_sticker_pack(room, event.state_key, pack, stickers) {
            packs.push(pack);
        }
    }
    Ok(packs)
}

pub(super) async fn get_sticker_packs(
    client: &Client,
    room: &Room,
) -> Result<Vec<StickerPack>, String> {
    let imported_room_packs = sticker_collection::effective(client).await?;
    let mut packs = load_room_sticker_packs(room, None).await?;
    for pack in &mut packs {
        pack.collected = imported_room_packs
            .get(&pack.room_id)
            .is_some_and(|keys| keys.contains(&pack.state_key));
    }
    for (room_id, keys) in imported_room_packs {
        if room.room_id().as_str() == room_id {
            continue;
        }
        let parsed = matrix_sdk::ruma::RoomId::parse(room_id).map_err(|error| error.to_string())?;
        if let Some(source) = client
            .get_room(&parsed)
            .filter(|room| room.state() == matrix_sdk::RoomState::Joined)
        {
            for mut pack in load_room_sticker_packs(&source, Some(&keys)).await? {
                pack.collected = true;
                packs.push(pack);
            }
        }
    }
    packs.sort_by_cached_key(|pack| (pack.title.to_lowercase(), pack.id.clone()));
    Ok(packs)
}

pub(super) async fn find_sticker_pack(
    client: &Client,
    image_url: &str,
    preferred_room_id: &str,
) -> Result<Vec<StickerPack>, String> {
    let collected = sticker_collection::effective(client).await?;
    let mut matches = Vec::new();
    for room in client.joined_rooms() {
        for mut pack in load_room_sticker_packs(&room, None).await? {
            if pack
                .stickers
                .iter()
                .any(|sticker| sticker.image_url == image_url)
            {
                pack.collected = collected
                    .get(&pack.room_id)
                    .is_some_and(|keys| keys.contains(&pack.state_key));
                matches.push(pack);
            }
        }
    }
    matches.sort_by_cached_key(|pack| (pack.room_id != preferred_room_id, pack.id.clone()));
    Ok(matches)
}

#[cfg(test)]
mod tests {

    use matrix_sdk::{
        ruma::{room_id, serde::Raw},
        test_utils::mocks::MatrixMockServer,
    };
    use matrix_sdk_test::JoinedRoomBuilder;
    use serde_json::{json, Value};

    fn pack_event(
        event_type: &str,
        state_key: &str,
        content: Value,
    ) -> Raw<matrix_sdk::ruma::events::AnySyncStateEvent> {
        Raw::from_json_string(
            json!({
                "type": event_type, "state_key": state_key, "content": content,
                "event_id": format!("${event_type}-{}:localhost", state_key.replace(':', "_")),
                "sender": "@alice:localhost", "origin_server_ts": 1,
            })
            .to_string(),
        )
        .unwrap()
    }

    #[tokio::test]
    async fn reads_both_room_formats_and_preserves_legacy_image_usage() {
        let server = MatrixMockServer::new().await;
        let client = server.client_builder().build().await;
        let room_id = room_id!("!stickers:localhost");
        server.sync_room(&client, JoinedRoomBuilder::new(room_id)
            .add_state_event(pack_event("im.ponies.room_emotes", "legacy", json!({
                "pack": {"usage": ["emoticon"]},
                "images": {
                    "inherit": {"url": "mxc://localhost/inherit"},
                    "override": {"url": "mxc://localhost/override", "usage": ["sticker"]},
                }
            })))
            .add_state_event(pack_event("im.ponies.room_emotes", "shared", json!({
                "pack": null, "images": {"old": {"url": "mxc://localhost/old"}}
            })))
            .add_state_event(pack_event("m.room.image_pack", "shared", json!({
                "images": {"new": {"url": "mxc://localhost/new"}}
            })))
        ).await;
        let room = client.get_room(room_id).unwrap();
        let packs = super::get_sticker_packs(&client, &room).await.unwrap();
        assert_eq!(packs.len(), 2);
        let legacy = packs.iter().find(|pack| pack.title == "legacy").unwrap();
        assert_eq!(legacy.stickers.len(), 1);
        assert_eq!(legacy.stickers[0].shortcode, "override");
        let shared = packs.iter().find(|pack| pack.title == "shared").unwrap();
        assert_eq!(shared.stickers[0].shortcode, "new");
    }

    #[tokio::test]
    async fn merges_old_and_new_imports_without_showing_disabled_packs() {
        let server = MatrixMockServer::new().await;
        let client = server.client_builder().build().await;
        let target_id = room_id!("!target:localhost");
        let source_id = room_id!("!source:localhost");
        server
            .sync_room(&client, JoinedRoomBuilder::new(target_id))
            .await;
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(source_id)
                    .add_state_event(pack_event(
                        "im.ponies.room_emotes",
                        "old",
                        json!({
                            "images": {"old": {"url": "mxc://localhost/old"}}
                        }),
                    ))
                    .add_state_event(pack_event(
                        "m.room.image_pack",
                        "new",
                        json!({
                            "images": {"new": {"url": "mxc://localhost/new"}}
                        }),
                    ))
                    .add_state_event(pack_event(
                        "im.ponies.room_emotes",
                        "disabled",
                        json!({
                            "images": {"disabled": {"url": "mxc://localhost/disabled"}}
                        }),
                    )),
            )
            .await;
        server
            .mock_sync()
            .ok_and_run(&client, |sync| {
                for (event_type, state_key) in [
                    ("im.ponies.emote_rooms", "old"),
                    ("m.image_pack.rooms", "new"),
                ] {
                    sync.add_global_account_data(Raw::from_json_string(json!({
                        "type": event_type, "content": {"rooms": {source_id.as_str(): {state_key: {}}}}
                    }).to_string()).unwrap());
                }
            })
            .await;
        let room = client.get_room(target_id).unwrap();
        let packs = super::get_sticker_packs(&client, &room).await.unwrap();
        assert_eq!(
            packs
                .iter()
                .map(|pack| pack.title.as_str())
                .collect::<Vec<_>>(),
            ["new", "old"]
        );
    }

    #[tokio::test]
    async fn finds_the_pack_that_holds_a_sticker_url() {
        let server = MatrixMockServer::new().await;
        let client = server.client_builder().build().await;
        let room_id = room_id!("!stickers:localhost");
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(room_id).add_state_event(pack_event(
                    "m.room.image_pack",
                    "",
                    json!({"images": {"cat": {"url": "mxc://localhost/cat"}}}),
                )),
            )
            .await;
        let found = super::find_sticker_pack(&client, "mxc://localhost/cat", "!other:localhost")
            .await
            .unwrap();
        assert_eq!(found.len(), 1);
        let found = &found[0];
        assert_eq!(found.room_id, "!stickers:localhost");
        assert_eq!(found.state_key, "");
        assert_eq!(found.stickers.len(), 1);

        let other = room_id!("!other:localhost");
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(other).add_state_event(pack_event(
                    "m.room.image_pack",
                    "a:b",
                    json!({"images":{"cat":{"url":"mxc://localhost/cat"}}}),
                )),
            )
            .await;
        server.mock_sync().ok_and_run(&client, |sync| {
            sync.add_global_account_data(Raw::from_json_string(json!({"type":"m.image_pack.rooms", "content":{"rooms":{other.as_str():{"a:b":{}}}}}).to_string()).unwrap());
        }).await;
        let matches = super::find_sticker_pack(&client, "mxc://localhost/cat", other.as_str())
            .await
            .unwrap();
        assert_eq!(matches.len(), 2);
        assert_eq!(matches[0].state_key, "a:b");
        assert!(matches[0].collected);
        assert!(!matches[1].collected);

        let missing = super::find_sticker_pack(&client, "mxc://localhost/dog", "!other:localhost")
            .await
            .unwrap();
        assert!(missing.is_empty());
    }
}
