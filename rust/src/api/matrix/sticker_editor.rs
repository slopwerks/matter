use super::{ensure_account_matches, get_client, get_room_by_id, ClientLease, StickerPackSnapshot};
use matrix_sdk::{
    ruma::{
        api::{client::state::get_state_event_for_key::v3 as state, error::ErrorKind},
        events::room::image_pack::RoomImagePackEventContent,
    },
    Room, RoomState,
};
use serde::Deserialize;
use serde_json::{json, Value};

pub(super) const STABLE: &str = "m.room.image_pack";
const LEGACY: &str = "im.ponies.room_emotes";
static WRITER: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

pub(super) async fn room(account: &str, id: &str) -> Result<(ClientLease, Room), String> {
    let client = get_client().await.ok_or("请先登录")?;
    ensure_account_matches(&client, account)?;
    let room = get_room_by_id(&client, id)?;
    Ok((client, room))
}

pub(super) async fn can_write(room: &Room, kind: &str) -> Result<bool, String> {
    let client = room.client();
    let user = client.user_id().ok_or("请先登录")?;
    Ok(room.state() == RoomState::Joined
        && room
            .power_levels()
            .await
            .map_err(|err| err.to_string())?
            .user_can_send_state(user, kind.into()))
}

#[derive(Deserialize)]
struct Event {
    event_id: String,
    content: Value,
}

async fn latest(room: &Room, kind: &str, key: &str) -> Result<Option<Event>, String> {
    let mut request = state::Request::new(room.room_id().to_owned(), kind.into(), key.into());
    request.format = state::StateEventFormat::Event;
    match room.client().send(request).await {
        Ok(response) => serde_json::from_str(response.event_or_content.get())
            .map(Some)
            .map_err(|err| err.to_string()),
        Err(err) if matches!(err.client_api_error_kind(), Some(ErrorKind::NotFound)) => Ok(None),
        Err(err) => Err(err.to_string()),
    }
}

fn active(event: &Option<Event>) -> Option<&Event> {
    event
        .as_ref()
        .filter(|event| event.content["images"].is_object())
}

fn migrate(mut content: Value) -> Value {
    if !content["pack"].is_object() {
        content["pack"] = json!({});
    }
    let inherited = content["pack"]["usage"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let mut usages = std::collections::BTreeSet::new();
    if let Some(images) = content["images"].as_object_mut() {
        for image in images.values_mut().filter_map(Value::as_object_mut) {
            let usage = image.remove("usage");
            let effective = usage
                .as_ref()
                .and_then(Value::as_array)
                .filter(|list| !list.is_empty())
                .unwrap_or(&inherited);
            if effective.is_empty() {
                usages.extend(["emoticon".to_owned(), "sticker".to_owned()]);
            } else {
                usages.extend(
                    effective
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned),
                );
            }
        }
    }
    if !usages.is_empty() {
        content["pack"]["usage"] = json!(usages);
    }
    content
}

pub(super) async fn snapshot(room: &Room, key: &str) -> Result<StickerPackSnapshot, String> {
    let (stable, legacy) = tokio::try_join!(latest(room, STABLE, key), latest(room, LEGACY, key))?;
    let content = active(&stable)
        .map(|event| event.content.clone())
        .or_else(|| active(&legacy).map(|event| migrate(event.content.clone())));
    Ok(StickerPackSnapshot {
        stable_version: stable.map(|event| event.event_id),
        legacy_version: active(&legacy).map(|event| event.event_id.clone()),
        content_json: content.map(|content| content.to_string()),
    })
}

fn validate(content: &Value) -> Result<(), String> {
    let pack: RoomImagePackEventContent =
        serde_json::from_value(content.clone()).map_err(|err| format!("贴纸数据无效：{err}"))?;
    if pack.images.is_empty() {
        return Err("请先添加贴纸".into());
    }
    if pack
        .images
        .iter()
        .any(|(key, image)| key.trim().is_empty() || !image.url.is_valid())
        || pack.pack.avatar_url.is_some_and(|url| !url.is_valid())
    {
        return Err("请输入短码并选择有效的包图片".into());
    }
    Ok(())
}

async fn send(room: &Room, kind: &str, key: &str, content: Value) -> Result<(), String> {
    room.send_state_event_raw(kind, key, content)
        .await
        .map(|_| ())
        .map_err(|err| err.to_string())
}

pub(super) async fn write(
    room: &Room,
    key: &str,
    stable: Option<String>,
    legacy: Option<String>,
    json: Option<String>,
) -> Result<(), String> {
    let _writer = WRITER.lock().await;
    if !can_write(room, STABLE).await? {
        return Err("没有管理贴纸包的权限".into());
    }
    let current = snapshot(room, key).await?;
    let deleting = json.is_none();
    if current.stable_version != stable
        || (current.legacy_version != legacy && !(deleting && current.legacy_version.is_none()))
    {
        return Err("贴纸包已被更改，请重新打开后核对修改".into());
    }
    if let Some(json) = json {
        let content = serde_json::from_str(&json).map_err(|err| err.to_string())?;
        validate(&content)?;
        return send(room, STABLE, key, content).await;
    }
    if current.legacy_version.is_some() {
        if !can_write(room, LEGACY).await? {
            return Err("没有删除旧格式贴纸包的权限".into());
        }
        send(room, LEGACY, key, json!({})).await?;
    }
    if current.stable_version.is_some() {
        send(room, STABLE, key, json!({})).await?;
    }
    Ok(())
}

pub(super) async fn upload(
    room: &Room,
    data: Vec<u8>,
    mime: String,
    confirmed: bool,
) -> Result<String, String> {
    if !can_write(room, STABLE).await? {
        return Err("没有管理贴纸包的权限".into());
    }
    if !confirmed
        && room
            .latest_encryption_state()
            .await
            .map_err(|err| err.to_string())?
            .is_encrypted()
    {
        return Err("请确认贴纸包媒体以明文上传".into());
    }
    let mime = mime.parse::<mime::Mime>().map_err(|err| err.to_string())?;
    if mime.type_() != mime::IMAGE || data.is_empty() {
        return Err("请选择图片".into());
    }
    room.client()
        .media()
        .upload(&mime, data, None)
        .await
        .map(|response| response.content_uri.to_string())
        .map_err(|err| err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::{
        ruma::{events::AnySyncStateEvent, room_id, serde::Raw},
        test_utils::mocks::MatrixMockServer,
    };
    use matrix_sdk_test::JoinedRoomBuilder;
    use wiremock::{
        matchers::{body_json, method, path_regex},
        Mock, ResponseTemplate,
    };

    #[test]
    fn migration_preserves_media_and_attribution() {
        let info = json!({"w":3,"h":2,"mimetype":"image/png"});
        let pack = migrate(
            json!({"pack":{"attribution":"artist","usage":["emoticon"]},"images":{"cat":{"url":"mxc://example.com/cat","body":"Cat","info":info,"usage":["sticker"]}}}),
        );
        assert_eq!(
            pack["pack"],
            json!({"attribution":"artist","usage":["sticker"]})
        );
        assert_eq!(
            pack["images"]["cat"],
            json!({"url":"mxc://example.com/cat","body":"Cat","info":info})
        );
        assert!(validate(&pack).is_ok());
        assert!(validate(&json!({"images":{}})).is_err());
    }

    async fn editing_room(server: &MatrixMockServer) -> Room {
        let client = server.client_builder().build().await;
        let user = client.user_id().unwrap();
        let event = |kind: &str, content: Value| {
            Raw::<AnySyncStateEvent>::from_json_string(json!({"type":kind,"event_id":format!("${kind}"),"state_key":"","origin_server_ts":1,"sender":user,"content":content}).to_string()).unwrap()
        };
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(room_id!("!pack:localhost"))
                    .add_state_event(event("m.room.create", json!({"creator":user})))
                    .add_state_event(event(
                        "m.room.encryption",
                        json!({"algorithm":"m.megolm.v1.aes-sha2"}),
                    ))
                    .add_state_event(event(
                        "m.room.power_levels",
                        json!({"users":{user.as_str():100}}),
                    )),
            )
            .await
    }

    #[tokio::test]
    async fn encrypted_room_upload_requires_confirmation_then_sends_original_bytes() {
        let server = MatrixMockServer::new().await;
        let room = editing_room(&server).await;
        let bytes = vec![137, 80, 78, 71];
        assert!(upload(&room, bytes.clone(), "image/png".into(), false)
            .await
            .unwrap_err()
            .contains("明文"));
        Mock::given(method("GET"))
            .and(path_regex("/media/(v3/)?config$"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"m.upload.size": 1024})))
            .mount(server.server())
            .await;
        Mock::given(method("POST"))
            .and(path_regex("/upload$"))
            .and(wiremock::matchers::body_bytes(bytes.clone()))
            .and(wiremock::matchers::header("content-type", "image/png"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(json!({"content_uri":"mxc://localhost/cat"})),
            )
            .expect(1)
            .mount(server.server())
            .await;
        assert_eq!(
            upload(&room, bytes, "image/png".into(), true)
                .await
                .unwrap(),
            "mxc://localhost/cat"
        );
    }

    #[tokio::test]
    async fn conflict_and_denied_legacy_delete_leave_stable_intact() {
        let server = MatrixMockServer::new().await;
        let room = editing_room(&server).await;
        let pack = json!({"images":{"cat":{"url":"mxc://localhost/cat"}}});
        for kind in [LEGACY, STABLE] {
            Mock::given(method("GET"))
                .and(path_regex(format!("/state/{kind}/raw(%3A|:)key$")))
                .respond_with(
                    ResponseTemplate::new(200)
                        .set_body_json(json!({"event_id":kind,"content":pack})),
                )
                .mount(server.server())
                .await;
        }
        let snapshot = snapshot(&room, "raw:key").await.unwrap();
        assert_eq!(snapshot.stable_version.as_deref(), Some(STABLE));
        assert_eq!(snapshot.legacy_version.as_deref(), Some(LEGACY));
        assert!(write(
            &room,
            "raw:key",
            Some("stale".into()),
            Some(LEGACY.into()),
            Some(pack.to_string())
        )
        .await
        .unwrap_err()
        .contains("已被更改"));
        Mock::given(method("PUT"))
            .and(path_regex(format!("/state/{LEGACY}/raw(%3A|:)key$")))
            .and(body_json(json!({})))
            .respond_with(
                ResponseTemplate::new(403)
                    .set_body_json(json!({"errcode":"M_FORBIDDEN","error":"denied"})),
            )
            .expect(1)
            .mount(server.server())
            .await;
        assert!(write(
            &room,
            "raw:key",
            snapshot.stable_version,
            snapshot.legacy_version,
            None
        )
        .await
        .is_err());
        assert!(
            !server
                .server()
                .received_requests()
                .await
                .unwrap()
                .iter()
                .any(|request| request.method.as_str() == "PUT"
                    && request.url.path().contains(STABLE))
        );
    }
}
