//! Room create implementation.

use super::*;

pub(super) async fn create_dm(account_user_id: String, user_id: String) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let invited_user = matrix_sdk::ruma::UserId::parse(&user_id)
        .map_err(|e| api_err("rooms", format!("无效的用户 ID: {e}")))?;

    // Serialize per (account, target) pair: two concurrent calls could both
    // scan before either create lands, each decide "no DM exists" and
    // create a duplicate room (same read-modify-write discipline as the
    // other queued writes). The account is part of the key — DM creation is
    // account-private, unlike `pinned:{room_id}` shared state, so one
    // account's slow scan must not stall another account's create.
    // Capture the account's current client instance id: the queued scan may
    // execute after a logout+relogin replaced the client (deep predecessor
    // chains), and creating a room under a stale session's token would
    // leave a duplicate DM the new session cannot see (same discipline as
    // `set_room_muted`). `account_user_id` is the LOGGED-IN account — the
    // `user_id` parameter is the DM target, which is not in CLIENTS.
    let expected_instance_id = CLIENTS
        .read()
        .await
        .get(&account_user_id)
        .map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = client.clone();
    let mutation_invited_user = invited_user.clone();
    run_bounded_mutation_undroppable(
        format!("dm:{account_user_id}:{user_id}"),
        lifecycle_protection,
        async move {
            // Fail fast when the account was logged out (its token may have
            // been revoked server-side while the CLIENTS entry survived) or
            // its client was replaced while this operation was queued: the
            // stale session's token may still be valid server-side, but
            // creating under it would orphan the room from the new session.
            let mutation_client = mutation_client;
            if !mutation_client.matrix_auth().logged_in() {
                return Err(api_err("rooms", "当前账号已登出，请重新登录。".to_string()));
            }
            let is_current_client = CLIENTS
                .read()
                .await
                .get(&account_user_id)
                .map(|e| e.instance_id)
                == expected_instance_id;
            if !is_current_client {
                return Err(api_err("rooms", "当前账号已切换，请重试。".to_string()));
            }
            // The reuse scan below calls `members()` per DM candidate, which can
            // fetch /members over the network while holding the client lease.
            // This operation runs UNDROPPABLE (a tail dropped mid-create can
            // orphan a room whose response never arrived, and the retry's
            // reuse scan cannot see it until sync delivers it — a duplicate
            // DM), so the scan is bounded internally: by the candidate cap,
            // by the elapsed-time cap, and by the per-request HTTP bound.
            // Deliberately NOT degrading to members_no_sync:
            // that could miss an existing DM whose member list has not synced
            // yet and silently create a duplicate room.
            let mut members_read_failed = false;
            let scan_started = std::time::Instant::now();
            let mut scanned_candidates = 0usize;
            let mut reused_room_id = None;
            for room in mutation_client.rooms() {
                if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
                    continue;
                }

                let is_direct = matches!(room.is_direct().await, Ok(true));
                // Mirror the room list's DM classification: when the OTHER
                // party created the DM, m.direct lives in their account data and
                // this account's is_direct() is false — skipping such rooms
                // would create a duplicate DM. A room is a DM candidate when it
                // is directly marked, or small per the sync summary (≤2 joined);
                // larger rooms are skipped without the network members() call
                // (which lazy-loaded rooms would otherwise trigger per
                // candidate).
                if !is_direct && room.joined_members_count() > 2 {
                    continue;
                }

                // The DM shape check mirrors `is_dm_by_members` for rooms NOT
                // directly marked: with two joined members there must be no
                // pending invite, or the room is a forming group. Directly
                // marked rooms are DMs by definition (the room list agrees).
                let joined_len = room.joined_members_count();
                if !is_direct {
                    if joined_len == 0 {
                        // No sync summary was ever received for this room: the
                        // member counts are unknown, and the room may be a
                        // large group (reusing it as a "DM" would be wrong —
                        // `is_dm_by_members` classifies the same state
                        // conservatively as a group). Skip until a summary
                        // arrives; the store members() call below would only
                        // re-confirm the unknown.
                        continue;
                    }
                    if joined_len == 1 {
                        if room.invited_members_count() > 1 {
                            continue;
                        }
                    } else if room.invited_members_count() != 0 {
                        continue;
                    }
                }

                // Bound the scan: each remaining candidate costs a `members()`
                // call that can fetch /members over the network (worst ~93s
                // under bounded_request_config), so an unbounded scan could
                // run for a very long time on accounts with many DM-shaped
                // rooms. Past either cap the remaining candidates are
                // unverifiable — fail closed like a members() failure instead
                // of risking a duplicate DM.
                if scanned_candidates >= DM_REUSE_SCAN_MAX_CANDIDATES
                    || scan_started.elapsed()
                        >= std::time::Duration::from_secs(DM_REUSE_SCAN_MAX_ELAPSED_SECS)
                {
                    app_log(
                        "warn",
                        "rooms",
                        "DM reuse scan hit its candidate/elapsed limit; failing closed."
                            .to_string(),
                    );
                    members_read_failed = true;
                    break;
                }
                scanned_candidates += 1;

                let members = match room
                    .members(
                        matrix_sdk::RoomMemberships::JOIN | matrix_sdk::RoomMemberships::INVITE,
                    )
                    .await
                {
                    Ok(members) => members,
                    Err(_) => {
                        // A candidate's membership could not be verified: it may
                        // be the existing DM with the target. Fail closed (the
                        // user can retry) instead of silently creating a
                        // duplicate DM room.
                        members_read_failed = true;
                        continue;
                    }
                };

                let own_user_id = mutation_client.user_id().map(|id| id.to_string());
                let is_self_dm = own_user_id.as_deref() == Some(mutation_invited_user.as_str());
                let matched = if is_self_dm {
                    // A self-DM is the room that contains ONLY the caller
                    // (1 joined, no invitees): matching "any room the caller is
                    // in" would silently navigate into an unrelated
                    // conversation, while a bare membership exclusion would
                    // never match anything and create a duplicate on every tap.
                    joined_len == 1
                        && room.invited_members_count() == 0
                        && members.iter().all(|m| m.user_id() == mutation_invited_user)
                } else {
                    members.iter().any(|member| {
                        member.user_id() == mutation_invited_user
                            && own_user_id.as_deref() != Some(member.user_id().as_str())
                    })
                };
                if matched {
                    app_log(
                        "info",
                        "rooms",
                        format!(
                            "Reusing existing DM room {} for {}",
                            room.room_id(),
                            user_id
                        ),
                    );
                    reused_room_id = Some(room.room_id().to_string());
                    break;
                }
            }
            if let Some(room_id) = reused_room_id {
                return Ok(room_id);
            }
            if members_read_failed {
                return Err(api_err(
                    "rooms",
                    "无法确认是否已有私聊，请重试。".to_string(),
                ));
            }

            let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
            request.invite = vec![mutation_invited_user];
            request.is_direct = true;

            let response = mutation_client
                .create_room(request)
                .await
                .map_err(|e| api_err("rooms", format!("创建房间失败: {e}")))?;

            app_log(
                "info",
                "rooms",
                format!("Created DM room: {}", response.room_id()),
            );
            info!("Created DM room: {}", response.room_id());
            Ok(response.room_id().to_string())
        },
    )
    .await
}

pub(super) async fn create_group_room(
    account_user_id: String,
    name: String,
    topic: Option<String>,
) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    // Mirror update_room_details: an empty name would create a nameless
    // room (the Dart callers already intercept, this is defense in depth).
    let name = name.trim().to_owned();
    if name.is_empty() {
        return Err(api_err("rooms", "房间名称不能为空。".to_string()));
    }
    // Mirror update_room_details: trim the topic too (the Dart callers
    // already pass trimmed values; this is defense in depth).
    let topic = topic.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty());

    // Bounded like the other P0 writes: the create request holds the client
    // lease.
    run_bounded(async move {
        let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
        request.name = Some(name);
        request.topic = topic;

        let response = client
            .create_room(request)
            .await
            .map_err(|e| api_err("rooms", format!("创建房间失败: {e}")))?;

        app_log(
            "info",
            "rooms",
            format!("Created group room: {}", response.room_id()),
        );
        info!("Created group room: {}", response.room_id());
        Ok(response.room_id().to_string())
    })
    .await
}
