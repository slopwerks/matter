//! Room knocks implementation.

use super::*;

/// List current requests to join a knock-enabled room.
pub(super) fn knock_member_events_request(
    room_id: matrix_sdk::ruma::OwnedRoomId,
) -> matrix_sdk::ruma::api::client::membership::get_member_events::v3::Request {
    use matrix_sdk::ruma::events::room::member::MembershipState;

    let mut request =
        matrix_sdk::ruma::api::client::membership::get_member_events::v3::Request::new(room_id);
    request.membership = Some(MembershipState::Knock);
    request
}

pub(super) async fn get_room_knock_requests(room_id: String) -> Result<Vec<KnockRequest>, String> {
    use matrix_sdk::ruma::events::room::member::{MembershipState, RoomMemberEvent};

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = joined_non_space_room(&client, &room_id)?;
    let request = knock_member_events_request(room.room_id().to_owned());
    let response = run_bounded(async move {
        client
            .send(request)
            .await
            .map_err(|error| api_err("rooms", format!("无法加载加入请求列表: {error}")))
    })
    .await?;
    let mut requests = Vec::with_capacity(response.chunk.len());
    for raw in response.chunk {
        let event: RoomMemberEvent = raw
            .deserialize()
            .map_err(|error| api_err("rooms", format!("无法解析加入请求数据: {error}")))?;
        let RoomMemberEvent::Original(event) = event else {
            continue;
        };
        if event.content.membership != MembershipState::Knock {
            continue;
        }
        let user_id = event.state_key.to_string();
        requests.push(KnockRequest {
            display_name: event.content.displayname.unwrap_or_else(|| user_id.clone()),
            avatar_url: event.content.avatar_url.map(|url| url.to_string()),
            reason: event.content.reason,
            user_id,
        });
    }
    Ok(requests)
}

/// Map a knock pre-verification read failure: a 404 (the member event was
/// never synced, or was redacted after another admin handled the request)
/// is the same "state already changed" outcome as a non-knock membership —
/// the page hides the request and refreshes, so the generic "请重试"
/// wording would mislead. Other errors fail closed with a retryable
/// wording.
pub(super) fn knock_state_read_failure(error: &matrix_sdk::HttpError) -> String {
    let text = format!("{error}");
    // A missing member event surfaces as a 404 with the standard
    // M_NOT_FOUND error kind; match either marker.
    if text.contains("M_NOT_FOUND") || text.contains("404") {
        return api_err("rooms", "该用户已不再是此房间的加入请求。".to_string());
    }
    api_err("rooms", format!("无法确认加入请求状态，请重试: {error}"))
}

pub(super) async fn approve_room_knock(
    account_user_id: String,
    room_id: String,
    user_id: String,
) -> Result<(), String> {
    use matrix_sdk::ruma::api::client::state::get_state_event_for_key;
    use matrix_sdk::ruma::events::room::member::{MembershipState, RoomMemberEventContent};
    use matrix_sdk::ruma::events::StateEventType;

    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id.trim())
        .map_err(|error| api_err("rooms", format!("无效的用户 ID: {error}")))?;
    // Symmetric with reject_room_knock: the knock list can lag the server
    // (the user withdrew the request, or another admin handled it). Inviting
    // on stale data would add a member who is no longer knocking, so
    // re-verify the current membership from the server first. Fail closed
    // when the state cannot be read.
    let request = get_state_event_for_key::v3::Request::new(
        room.room_id().to_owned(),
        StateEventType::RoomMember,
        user_id.to_string(),
    );
    let client_for_verify = client.clone();
    run_bounded(async move {
        let response = client_for_verify
            .send(request)
            .await
            .map_err(|error| knock_state_read_failure(&error))?;
        // Spec-compliant servers return the bare event content; some return
        // the full state event instead. Try the content-only form first,
        // then extract the `content` field. Either way the decode failure
        // fails closed (no invite/kick on unverifiable state).
        let raw = response.event_or_content.get();
        let content: RoomMemberEventContent = match serde_json::from_str(raw) {
            Ok(content) => content,
            Err(_) => serde_json::from_str::<serde_json::Value>(raw)
                .ok()
                .and_then(|value| value.get("content").cloned())
                .and_then(|value| serde_json::from_value(value).ok())
                .ok_or_else(|| api_err("rooms", "无法确认加入请求状态，请重试。".to_string()))?,
        };
        if content.membership != MembershipState::Knock {
            return Err(api_err(
                "rooms",
                "该用户已不再是此房间的加入请求。".to_string(),
            ));
        }
        room.invite_user_by_id(&user_id).await.map_err(|error| {
            // The membership was verified as knock moments ago, but another
            // admin may have rejected the request (or the user withdrew it)
            // in between, turning the invite into a failed action on a
            // stale request. Tell the user the state may have changed
            // instead of a bare failure.
            api_err(
                "rooms",
                format!("批准加入请求失败: {error}（该用户可能已被其他管理员处理）"),
            )
        })?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

pub(super) async fn reject_room_knock(
    account_user_id: String,
    room_id: String,
    user_id: String,
) -> Result<(), String> {
    use matrix_sdk::ruma::api::client::state::get_state_event_for_key;
    use matrix_sdk::ruma::events::room::member::{MembershipState, RoomMemberEventContent};
    use matrix_sdk::ruma::events::StateEventType;

    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id.trim())
        .map_err(|error| api_err("rooms", format!("无效的用户 ID: {error}")))?;
    // The knock list can lag the server (another admin may have approved the
    // request, or the user withdrew it): re-verify the current membership
    // from the server before kicking, since `kick_user` would otherwise
    // eject a member who is no longer knocking. Fail closed when the state
    // cannot be read — never kick on stale data.
    let request = get_state_event_for_key::v3::Request::new(
        room.room_id().to_owned(),
        StateEventType::RoomMember,
        user_id.to_string(),
    );
    let client_for_verify = client.clone();
    run_bounded(async move {
        let response = client_for_verify
            .send(request)
            .await
            .map_err(|error| knock_state_read_failure(&error))?;
        // Spec-compliant servers return the bare event content; some return
        // the full state event instead. Try the content-only form first,
        // then extract the `content` field. Either way the decode failure
        // fails closed (no invite/kick on unverifiable state).
        let raw = response.event_or_content.get();
        let content: RoomMemberEventContent = match serde_json::from_str(raw) {
            Ok(content) => content,
            Err(_) => serde_json::from_str::<serde_json::Value>(raw)
                .ok()
                .and_then(|value| value.get("content").cloned())
                .and_then(|value| serde_json::from_value(value).ok())
                .ok_or_else(|| api_err("rooms", "无法确认加入请求状态，请重试。".to_string()))?,
        };
        if content.membership != MembershipState::Knock {
            return Err(api_err(
                "rooms",
                "该用户已不再是此房间的加入请求。".to_string(),
            ));
        }
        room.kick_user(&user_id, None).await.map_err(|error| {
            // The membership was verified as knock moments ago, but another
            // admin may have approved it in between, turning the kick into a
            // failed removal of a joined member. Tell the user the state may
            // have changed instead of a bare failure.
            api_err(
                "rooms",
                format!("拒绝加入请求失败: {error}（该用户可能已被其他管理员处理）"),
            )
        })?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}
