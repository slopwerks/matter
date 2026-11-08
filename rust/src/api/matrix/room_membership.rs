//! Room membership implementation.

use super::*;

pub(super) async fn join_room(
    account_user_id: String,
    identifier: String,
) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let id_or_alias = matrix_sdk::ruma::RoomOrAliasId::parse(identifier.clone())
        .map_err(|e| api_err("rooms", format!("无效的房间或空间标识: {e}")))?;

    // Bounded like the other P0 writes: joining is a network operation
    // holding the client lease.
    let room_id = run_bounded(async move {
        let room = client
            .join_room_by_id_or_alias(&id_or_alias, &[])
            .await
            .map_err(|e| api_err("rooms", format!("加入房间失败: {e}")))?;
        app_log("info", "rooms", format!("Joined room: {}", room.room_id()));
        info!("Joined room: {}", room.room_id());
        Ok(room.room_id().to_string())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(room_id)
}

pub(super) async fn accept_room_invite(
    account_user_id: String,
    room_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Invited {
        return Err(api_err("rooms", format!("该房间不是邀请状态: {room_id}")));
    }
    run_bounded(async move {
        room.join()
            .await
            .map_err(|e| api_err("rooms", format!("接受邀请失败: {e}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

pub(super) async fn reject_room_invite(
    account_user_id: String,
    room_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Invited {
        return Err(api_err("rooms", format!("该房间不是邀请状态: {room_id}")));
    }
    run_bounded(async move {
        room.leave()
            .await
            .map_err(|e| api_err("rooms", format!("拒绝邀请失败: {e}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

pub(super) async fn withdraw_room_knock(
    account_user_id: String,
    room_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Knocked {
        return Err(api_err(
            "rooms",
            format!("该房间不是加入请求状态: {room_id}"),
        ));
    }
    run_bounded(async move {
        room.leave()
            .await
            .map_err(|e| api_err("rooms", format!("撤回加入请求失败: {e}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

pub(super) fn joined_non_space_room(client: &Client, room_id: &str) -> Result<Room, String> {
    let room = get_room_by_id(client, room_id)?;
    if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
        return Err(api_err(
            "rooms",
            format!("该房间不是已加入的非空间房间: {room_id}"),
        ));
    }
    Ok(room)
}

/// Member-count heuristic for whether a joined room without an `m.direct`
/// entry is a 1:1. Shared by the room list classification and unmute (the
/// latter must install the DM default rule, all-messages, on a real 1:1).
/// Uses the sync summary counts, which are accurate even while lazy-loaded
/// members are missing; without a summary the room is classified as a group
/// (the stored member list would be an unreliable sliding-window subset).
/// DM iff at most two joined members, with at most one pending invite
/// alongside a single joined member (a 1:1 the other party has not accepted
/// yet) and none for an accepted pair — a fresh room with several invitees
/// is a group.
pub(super) async fn is_dm_by_members(room: &Room) -> bool {
    let summary_joined = room.joined_members_count();
    if summary_joined > 0 {
        summary_joined <= 2
            && (match summary_joined {
                1 => room.invited_members_count() <= 1,
                _ => room.invited_members_count() == 0,
            })
    } else {
        // No sync summary was ever received (fresh login before the first
        // sync cycle, or a store without room summaries). The member list
        // here is a lazy-loaded sliding-window subset: for a quiet group it
        // can hold as few as one or two members, so it cannot prove a 1:1.
        // Classify conservatively as a group — a wrong DM call flips unmute
        // onto the all-messages default rule for a real group (persistent
        // server noise), while a wrong group call only delays the correct
        // label until the first sync summary arrives.
        false
    }
}

/// Guard a user-initiated P0 write against account switches racing between
/// the Dart-side guard and this call's execution: the operation must run on
/// the account the caller opened it for, never on whatever account became
/// active in between.
pub(super) fn ensure_account_matches(client: &Client, account_user_id: &str) -> Result<(), String> {
    let active_user_id = client
        .user_id()
        .ok_or_else(|| api_err("account", "No active user".to_string()))?
        .to_string();
    if active_user_id != account_user_id {
        return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
    }
    Ok(())
}

pub(super) async fn leave_room(account_user_id: String, room_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    run_bounded(async move {
        room.leave()
            .await
            .map_err(|error| api_err("rooms", format!("退出房间失败: {error}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

pub(super) async fn get_room_details(room_id: String) -> Result<RoomDetails, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = joined_non_space_room(&client, &room_id)?;
    let has_explicit_name = room.name().is_some_and(|name| !name.trim().is_empty());
    let (name_event_id, avatar_event_id, topic_event_id) = tokio::join!(
        room_name_event_id(&room),
        room_avatar_event_id(&room),
        room_topic_event_id(&room)
    );
    Ok(RoomDetails {
        id: room_id,
        name: room_display_name(&room),
        has_explicit_name,
        avatar_url: room.avatar_url().map(|url| url.to_string()),
        name_event_id,
        avatar_event_id,
        topic_event_id,
        topic: room
            .topic()
            .map(|topic| topic.trim().to_string())
            .filter(|topic| !topic.is_empty()),
    })
}

pub(super) async fn invite_user_to_room(
    account_user_id: String,
    room_id: String,
    user_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id.trim())
        .map_err(|error| api_err("rooms", format!("无效的用户 ID: {error}")))?;
    run_bounded(async move {
        room.invite_user_by_id(&user_id)
            .await
            .map_err(|error| api_err("rooms", format!("邀请用户失败: {error}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

pub(super) async fn update_room_details(
    account_user_id: String,
    room_id: String,
    name: String,
    update_name: bool,
    update_topic: bool,
    topic: Option<String>,
) -> Result<RoomDetailsUpdate, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let name = name.trim().to_owned();
    run_bounded(async move {
        let (name_event_id, name_error) = if update_name {
            if name.is_empty() {
                (None, Some("房间名称不能为空。".to_string()))
            } else {
                match room.set_name(name.clone()).await {
                    Ok(response) => (Some(response.event_id.to_string()), None),
                    Err(error) => (None, Some(error.to_string())),
                }
            }
        } else {
            (None, None)
        };
        let (topic_event_id, topic_error) = if update_topic {
            let new_topic = topic.unwrap_or_default().trim().to_owned();
            // Dart already sends update_topic only for an edited value. Do
            // not compare against room.topic(): the SDK snapshot may still
            // predate a just-completed write, which would drop a quick
            // A -> B -> A change.
            match room.set_room_topic(&new_topic).await {
                Ok(response) => (Some(response.event_id.to_string()), None),
                Err(error) => (None, Some(error.to_string())),
            }
        } else {
            (None, None)
        };
        if name_event_id.is_some() || topic_event_id.is_some() {
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        }
        Ok(RoomDetailsUpdate {
            name_event_id,
            topic_event_id,
            name_error,
            topic_error,
        })
    })
    .await
}

pub(super) async fn upload_room_avatar(
    account_user_id: String,
    room_id: String,
    content_type: String,
    data: Vec<u8>,
) -> Result<RoomAvatarUpdate, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    // Only validates the room exists and is joined; the room used for the
    // state event is re-fetched under a fresh lease after the upload.
    joined_non_space_room(&client, &room_id)?;
    let mime: mime::Mime = content_type
        .parse()
        .map_err(|error| api_err("rooms", format!("无效的内容类型 '{content_type}': {error}")))?;
    if mime.type_() != mime::IMAGE {
        return Err(api_err("rooms", format!("不是图片格式: {mime}")));
    }
    let media = client.media();
    // The upload can legitimately take minutes (the SDK sizes its own
    // timeout by the payload, at least 5 minutes per attempt), so release
    // the client lease for its duration — holding the SYNC_LIFECYCLE read
    // lock for that long would freeze logout/account switch. A generous
    // total bound still caps the multi-retry worst case.
    let upload = {
        drop(client);
        tokio::time::timeout(
            std::time::Duration::from_secs(600),
            media.upload(&mime, data, None),
        )
        .await
        .map_err(|_| api_err("rooms", "上传超时，请重试。".to_string()))?
        .map_err(|error| api_err("rooms", format!("上传房间头像失败: {error}")))?
    };
    // Re-acquire the lease for the state-event step (short, bounded by
    // run_bounded) and re-verify the account: the account may have switched
    // or logged out entirely during the upload. Either way the upload
    // already landed — say so (the Dart catch passes "已上传" messages
    // through verbatim).
    let client = get_client().await.ok_or_else(|| {
        api_err(
            "rooms",
            "头像已上传，但当前账号已登出，无法应用。请重新登录后重试。".to_string(),
        )
    })?;
    ensure_account_matches(&client, &account_user_id)
        .map_err(|_| "头像已上传，但当前账号已切换，未应用。请重新选择图片以应用。".to_string())?;
    let room = joined_non_space_room(&client, &room_id).map_err(|_| {
        // The upload already landed: a room-state change on another device
        // (left / removed) must not surface as a bare failure that hides
        // the "已上传" passthrough.
        "头像已上传，但房间状态已变化（可能已退出该房间），未能应用。".to_string()
    })?;
    run_bounded(async move {
        let mut info = matrix_sdk::ruma::events::room::avatar::ImageInfo::new();
        info.mimetype = Some(mime.to_string());
        info.blurhash = upload.blurhash;
        // The upload already succeeded: a timeout here means the image is
        // uploaded but not applied — say so (a retry re-applies cheaply,
        // while "刷新确认" would have nothing to confirm).
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(60),
            room.set_avatar_url(&upload.content_uri, Some(info)),
        )
        .await
        .map_err(|_| {
            api_err(
                "rooms",
                "头像已上传，但应用失败（请求超时），请重试。".to_string(),
            )
        })?
        .map_err(|error| api_err("rooms", format!("更新房间头像失败: {error}")))?;
        notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        Ok(RoomAvatarUpdate {
            avatar_url: upload.content_uri.to_string(),
            event_id: response.event_id.to_string(),
        })
    })
    .await
}
