//! Room list implementation.

use super::*;

pub(super) async fn is_room_encrypted(room_id: String) -> Result<bool, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("encryption", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    Ok(room
        .latest_encryption_state()
        .await
        .map(|state| state.is_encrypted())
        .unwrap_or(true))
}

pub(super) async fn get_chat_rooms(
    ignored_user_ids: Option<Vec<String>>,
    authoritative: bool,
) -> Result<Vec<ChatRoom>, String> {
    let client = get_client().await.ok_or_else(|| {
        app_log(
            "error",
            "rooms",
            "get_chat_rooms: no client created".to_string(),
        );
        "No client created.".to_string()
    })?;
    let ignored_user_ids =
        ignored_user_ids.map(|ids| ids.into_iter().collect::<std::collections::HashSet<_>>());

    // Bounded like the other P0 reads: the room scan touches the shared
    // notification-settings instance while holding the client lease (the
    // instance itself is a local store read — push rules arrive via sync —
    // but the whole list build must stay bounded for the lease's sake).
    run_bounded(async move {
        let rooms = client.rooms();
        app_log(
            "info",
            "rooms",
            format!("get_chat_rooms: found {} total rooms", rooms.len()),
        );
        let mut result = Vec::new();
        let mut visible = 0;

        for room in rooms {
            if !matches!(
                room.state(),
                matrix_sdk::RoomState::Joined
                    | matrix_sdk::RoomState::Invited
                    | matrix_sdk::RoomState::Knocked
            ) {
                continue;
            }
            visible += 1;

            let mut chat_room =
                room_to_chat_room(&room, ignored_user_ids.as_ref(), authoritative).await;
            if !room.is_space() {
                // `is_direct` covers both joined rooms (m.direct account data)
                // and invited rooms (the invite event's is_direct flag), so it
                // is the primary signal. Only fall back to a member-count
                // heuristic for JOINED rooms whose m.direct entry is absent —
                // and use members_no_sync (a pure store read): `members()`
                // would trigger a serial HTTP /members request per room,
                // stalling the whole room list behind the network. Invited and
                // knocked rooms never fall back: their cache holds only
                // stripped state (~1-2 members), so a large group invite would
                // be misclassified as a DM.
                let is_dm = if room.state() == matrix_sdk::RoomState::Joined {
                    match room.is_direct().await {
                        Ok(true) => true,
                        Ok(false) | Err(_) => is_dm_by_members(&room).await,
                    }
                } else {
                    room.is_direct().await.unwrap_or(false)
                };
                if is_dm {
                    chat_room.room_type = "dm".to_string();
                } else if room.state() == matrix_sdk::RoomState::Joined {
                    chat_room.room_type = "group".to_string();
                }
            }
            result.push(chat_room);
        }

        app_log(
            "info",
            "rooms",
            format!("get_chat_rooms: {} visible rooms returned", visible),
        );
        result.sort_by(|a, b| {
            let a_time = a.last_message_time.parse::<u64>().unwrap_or_default();
            let b_time = b.last_message_time.parse::<u64>().unwrap_or_default();
            b_time
                .cmp(&a_time)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });

        Ok(result)
    })
    .await
}
