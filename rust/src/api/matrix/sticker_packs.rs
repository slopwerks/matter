use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use matrix_sdk::{
    deserialized_responses::SyncOrStrippedState,
    ruma::events::{
        image_pack::rooms::ImagePackRoomsEventContent,
        macros::EventContent,
        room::image_pack::{ImagePackImage, ImagePackMeta, PackUsage, RoomImagePackEventContent},
        SyncStateEvent,
    },
    Client, Room,
};
use serde::{Deserialize, Serialize};
use once_cell::sync::Lazy;

use super::StickerPackCandidate;
use super::{api_err, room_display_name, uint_to_i32, Sticker, StickerPack};

/// Pending sticker-pack writes per account.
///
/// set_account_data does not update the SDK state store, so the picker refresh
/// that follows an import would keep serving the pre-write mapping until the
/// account-data echo syncs (or forever, if connectivity drops first). Every
/// entry is forgotten as soon as the store confirms it.
#[derive(Default)]
pub(super) struct StickerPackOverrides {
    added: HashSet<(String, String)>,
    removed: HashSet<(String, String)>,
}

pub(super) static STICKER_PACK_OVERRIDES: Lazy<
    tokio::sync::RwLock<HashMap<String, StickerPackOverrides>>,
> = Lazy::new(|| tokio::sync::RwLock::new(HashMap::new()));

fn sticker_pack_override_key(client: &Client) -> Option<String> {
    client.user_id().map(|user_id| format!("{user_id}:packs"))
}

/// Folds pending local writes into the stored mapping, dropping the entries
/// the store has meanwhile confirmed.
pub(super) fn apply_sticker_pack_overrides(
    overrides: &mut StickerPackOverrides,
    imported: &mut HashMap<String, HashSet<String>>,
) {
    overrides.added.retain(|(room_id, state_key)| {
        if imported
            .get(room_id)
            .is_some_and(|keys| keys.contains(state_key))
        {
            return false;
        }
        imported
            .entry(room_id.clone())
            .or_default()
            .insert(state_key.clone());
        true
    });
    // Removals stay pending until the store drops the entry; hide it meanwhile.
    overrides.removed.retain(|(room_id, state_key)| {
        if !imported
            .get(room_id)
            .is_some_and(|keys| keys.contains(state_key))
        {
            return false;
        }
        if let Some(keys) = imported.get_mut(room_id) {
            keys.remove(state_key);
            if keys.is_empty() {
                imported.remove(room_id);
            }
        }
        true
    });
}

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
    let normalized_state_key = if state_key.trim().is_empty() {
        "default".to_string()
    } else {
        state_key
    };

    Some(StickerPack {
        id: format!("room:{}:{normalized_state_key}", room.room_id()),
        title,
        avatar_url,
        source: "room".to_string(),
        stickers,
    })
}

async fn load_room_sticker_packs(
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
            seen_state_keys.insert(event.state_key);
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
    let mut imported_room_packs: HashMap<String, HashSet<String>> = HashMap::new();
    // Both account-data formats have the same content shape. Read them from
    // the local store, just like the room state; no server-side migration needed.
    for event_type in ["m.image_pack.rooms", "im.ponies.emote_rooms"] {
        let content = client
            .account()
            .account_data_raw(event_type.into())
            .await
            .map_err(|e| {
                api_err(
                    "media",
                    format!("Failed to load image-pack room mapping: {e}"),
                )
            })?
            .and_then(|raw| {
                raw.deserialize_as_unchecked::<ImagePackRoomsEventContent>()
                    .ok()
            });
        if let Some(content) = content {
            for (room_id, packs) in content.rooms {
                imported_room_packs
                    .entry(room_id.to_string())
                    .or_default()
                    .extend(packs.into_keys());
            }
        }
    }

    if let Some(account_key) = sticker_pack_override_key(client) {
        let mut overrides = STICKER_PACK_OVERRIDES.write().await;
        if let Some(entry) = overrides.get_mut(&account_key) {
            apply_sticker_pack_overrides(entry, &mut imported_room_packs);
        }
    }

    let mut packs = Vec::new();
    let mut seen_pack_ids = HashSet::new();
    for pack in load_room_sticker_packs(room, None).await? {
        if seen_pack_ids.insert(pack.id.clone()) {
            packs.push(pack);
        }
    }
    for (source_room_id, enabled_state_keys) in imported_room_packs {
        let Ok(parsed_source_room_id) = matrix_sdk::ruma::RoomId::parse(&source_room_id) else {
            continue;
        };
        let Some(source_room) = client.get_room(&parsed_source_room_id) else {
            continue;
        };
        for pack in load_room_sticker_packs(&source_room, Some(&enabled_state_keys)).await? {
            if seen_pack_ids.insert(pack.id.clone()) {
                packs.push(pack);
            }
        }
    }
    packs.sort_by_key(|pack| pack.title.to_lowercase());
    Ok(packs)
}

/// Finds the room sticker pack that contains [image_url], preferring the room
/// the sticker was sent in and then any other joined room.
pub(super) async fn find_sticker_pack(
    client: &Client,
    image_url: &str,
    preferred_room_id: &str,
) -> Result<Option<StickerPackCandidate>, String> {
    let target = image_url.trim();
    if target.is_empty() {
        return Ok(None);
    }
    let mut rooms = Vec::new();
    if let Ok(room_id) = matrix_sdk::ruma::RoomId::parse(preferred_room_id) {
        if let Some(room) = client.get_room(&room_id) {
            rooms.push(room);
        }
    }
    for room in client.joined_rooms() {
        if rooms.iter().any(|known| known.room_id() == room.room_id()) {
            continue;
        }
        rooms.push(room);
    }
    for room in rooms {
        for pack in load_room_sticker_packs(&room, None).await? {
            if !pack
                .stickers
                .iter()
                .any(|sticker| sticker.image_url == target)
            {
                continue;
            }
            let Some((room_id, state_key)) = split_pack_id(&pack.id) else {
                continue;
            };
            return Ok(Some(StickerPackCandidate {
                room_id,
                state_key,
                pack,
            }));
        }
    }
    Ok(None)
}

/// Splits the room:{room_id}:{state_key} identifier used by [StickerPack].
fn split_pack_id(pack_id: &str) -> Option<(String, String)> {
    let rest = pack_id.strip_prefix("room:")?;
    let (room_id, state_key) = rest.rsplit_once(':')?;
    if room_id.is_empty() || state_key.is_empty() {
        return None;
    }
    Some((room_id.to_string(), state_key.to_string()))
}

/// Adds a room sticker pack to the account's imported packs (MSC2545
/// m.image_pack.rooms), which is what makes the picker show it.
pub(super) async fn import_sticker_pack(
    client: &Client,
    room_id: &str,
    state_key: &str,
) -> Result<(), String> {
    let parsed = matrix_sdk::ruma::RoomId::parse(room_id)
        .map_err(|e| api_err("media", format!("无效的房间 ID: {e}")))?;
    let room = client
        .get_room(&parsed)
        .ok_or_else(|| api_err("media", format!("房间不存在: {room_id}")))?;
    // An empty state key is published as "default" in StickerPack::id, so try
    // both spellings while confirming the pack against room state.
    let mut candidates = vec![state_key.to_string()];
    if state_key == "default" {
        candidates.push(String::new());
    }
    let mut resolved = None;
    for key in candidates {
        let keys = HashSet::from([key.clone()]);
        if !load_room_sticker_packs(&room, Some(&keys))
            .await?
            .is_empty()
        {
            resolved = Some(key);
            break;
        }
    }
    let key = resolved.ok_or_else(|| {
        api_err(
            "media",
            format!("贴纸包不存在: {} ({state_key})", room.room_id()),
        )
    })?;

    let mut content = client
        .account()
        .account_data_raw("m.image_pack.rooms".into())
        .await
        .map_err(|e| {
            api_err(
                "media",
                format!("Failed to load image-pack room mapping: {e}"),
            )
        })?
        .and_then(|raw| {
            raw.deserialize_as_unchecked::<ImagePackRoomsEventContent>()
                .ok()
        })
        .unwrap_or_default();
    content.rooms.entry(parsed.to_owned()).or_default().insert(
        key.clone(),
        matrix_sdk::ruma::events::image_pack::rooms::RoomImagePackMeta::new(),
    );
    client
        .account()
        .set_account_data(content)
        .await
        .map_err(|e| api_err("media", format!("Failed to import sticker pack: {e}")))?;
    // Keep the import visible while the account-data echo is still missing.
    if let Some(account_key) = sticker_pack_override_key(client) {
        let pack = (room.room_id().to_string(), key.clone());
        let mut overrides = STICKER_PACK_OVERRIDES.write().await;
        let entry = overrides.entry(account_key).or_default();
        entry.removed.remove(&pack);
        entry.added.insert(pack);
    }
    super::app_log(
        "info",
        "media",
        format!("Imported sticker pack {room_id} ({state_key})"),
    );
    Ok(())
}

/// Drops a room sticker pack from the account's imported packs, so the picker
/// stops offering it.
pub(super) async fn remove_sticker_pack(
    client: &Client,
    room_id: &str,
    state_key: &str,
) -> Result<(), String> {
    let parsed = matrix_sdk::ruma::RoomId::parse(room_id)
        .map_err(|e| api_err("media", format!("无效的房间 ID: {e}")))?;
    // An empty state key is published as "default" in StickerPack::id, so try
    // both spellings while dropping the mapping.
    let mut keys = vec![state_key.to_string()];
    if state_key == "default" {
        keys.push(String::new());
    }
    let mut removed = false;
    for event_type in ["m.image_pack.rooms", "im.ponies.emote_rooms"] {
        let Some(mut content) = client
            .account()
            .account_data_raw(event_type.into())
            .await
            .ok()
            .flatten()
            .and_then(|raw| {
                raw.deserialize_as_unchecked::<ImagePackRoomsEventContent>()
                    .ok()
            })
        else {
            continue;
        };
        let Some(packs) = content.rooms.get_mut(&parsed) else {
            continue;
        };
        let mut changed = false;
        for key in &keys {
            if packs.remove(key).is_some() {
                changed = true;
                removed = true;
            }
        }
        if !changed {
            continue;
        }
        if packs.is_empty() {
            content.rooms.remove(&parsed);
        }
        client
            .account()
            .set_account_data(content)
            .await
            .map_err(|e| api_err("media", format!("Failed to remove sticker pack: {e}")))?;
    }
    // Hide the pack immediately: the echo that clears the store entry may
    // still be missing.
    if let Some(account_key) = sticker_pack_override_key(client) {
        let mut overrides = STICKER_PACK_OVERRIDES.write().await;
        let entry = overrides.entry(account_key).or_default();
        for key in &keys {
            let pack = (parsed.to_string(), key.clone());
            entry.added.remove(&pack);
            entry.removed.insert(pack);
        }
    }
    if !removed {
        return Err(api_err(
            "media",
            format!("贴纸包不在个人收藏里: {room_id} ({state_key})"),
        ));
    }
    super::app_log(
        "info",
        "media",
        format!("Removed sticker pack {room_id} ({state_key})"),
    );
    Ok(())
}

/// FFI entry point: drop a room sticker pack from the account.
pub(super) async fn remove_sticker_pack_for_account(
    room_id: String,
    state_key: String,
) -> Result<(), String> {
    let client = super::get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    remove_sticker_pack(&client, &room_id, &state_key).await
}

/// FFI entry point: the pack behind a sticker message.
pub(super) async fn find_sticker_pack_for_message(
    image_url: String,
    room_id: String,
) -> Result<Option<StickerPackCandidate>, String> {
    let client = super::get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    find_sticker_pack(&client, &image_url, &room_id).await
}

/// FFI entry point: import a room sticker pack into the account.
pub(super) async fn import_sticker_pack_for_account(
    room_id: String,
    state_key: String,
) -> Result<(), String> {
    let client = super::get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    import_sticker_pack(&client, &room_id, &state_key).await
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};

    use super::{apply_sticker_pack_overrides, StickerPackOverrides};
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
                "event_id": format!("${event_type}-{state_key}:localhost"),
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
            .unwrap()
            .expect("pack holding the sticker");
        assert_eq!(found.room_id, "!stickers:localhost");
        assert_eq!(found.state_key, "default");
        assert_eq!(found.pack.stickers.len(), 1);

        let missing = super::find_sticker_pack(&client, "mxc://localhost/dog", "!other:localhost")
            .await
            .unwrap();
        assert!(missing.is_none());
    }

    #[test]
    fn a_pending_import_survives_a_stale_store() {
        let mut overrides = StickerPackOverrides::default();
        overrides
            .added
            .insert(("!room:localhost".to_string(), "cats".to_string()));
        let mut imported = HashMap::new();

        apply_sticker_pack_overrides(&mut overrides, &mut imported);

        assert_eq!(
            imported.get("!room:localhost"),
            Some(&HashSet::from(["cats".to_string()]))
        );
        // Still pending: no echo has confirmed it yet.
        assert!(overrides
            .added
            .contains(&("!room:localhost".to_string(), "cats".to_string())));
    }

    #[test]
    fn a_confirmed_import_drops_its_override() {
        let mut overrides = StickerPackOverrides::default();
        overrides
            .added
            .insert(("!room:localhost".to_string(), "cats".to_string()));
        let mut imported = HashMap::from([(
            "!room:localhost".to_string(),
            HashSet::from(["cats".to_string()]),
        )]);

        apply_sticker_pack_overrides(&mut overrides, &mut imported);

        assert_eq!(
            imported.get("!room:localhost"),
            Some(&HashSet::from(["cats".to_string()]))
        );
        assert!(overrides.added.is_empty());
    }

    #[test]
    fn a_pending_removal_hides_the_stored_pack() {
        let mut overrides = StickerPackOverrides::default();
        overrides
            .removed
            .insert(("!room:localhost".to_string(), "cats".to_string()));
        let mut imported = HashMap::from([(
            "!room:localhost".to_string(),
            HashSet::from(["cats".to_string(), "dogs".to_string()]),
        )]);

        apply_sticker_pack_overrides(&mut overrides, &mut imported);

        assert_eq!(
            imported.get("!room:localhost"),
            Some(&HashSet::from(["dogs".to_string()]))
        );
        // Still pending: the store has not dropped it yet.
        assert_eq!(overrides.removed.len(), 1);
    }

    #[test]
    fn a_confirmed_removal_drops_its_override() {
        let mut overrides = StickerPackOverrides::default();
        overrides
            .removed
            .insert(("!room:localhost".to_string(), "cats".to_string()));
        let mut imported = HashMap::new();

        apply_sticker_pack_overrides(&mut overrides, &mut imported);

        assert!(imported.is_empty());
        assert!(overrides.removed.is_empty());
    }

    #[test]
    fn a_removal_with_nothing_left_drops_the_room_entry() {
        let mut overrides = StickerPackOverrides::default();
        overrides
            .removed
            .insert(("!room:localhost".to_string(), "cats".to_string()));
        let mut imported = HashMap::from([(
            "!room:localhost".to_string(),
            HashSet::from(["cats".to_string()]),
        )]);

        apply_sticker_pack_overrides(&mut overrides, &mut imported);

        assert!(imported.is_empty());
    }

    #[test]
    fn splits_pack_ids() {
        assert_eq!(
            super::split_pack_id("room:!a:b:shared"),
            Some(("!a:b".to_string(), "shared".to_string()))
        );
        assert_eq!(
            super::split_pack_id("room:!a:b"),
            Some(("!a".to_string(), "b".to_string()))
        );
        assert_eq!(super::split_pack_id("user:!a:b:shared"), None);
    }
}
