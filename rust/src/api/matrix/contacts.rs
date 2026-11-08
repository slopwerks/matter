//! Contacts implementation.

use super::*;

pub(super) async fn get_contacts() -> Result<Vec<Contact>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("contacts", "No client created.".to_string()))?;
    let my_user_id = client.user_id().map(|user_id| user_id.to_string());
    // Bounded like the other P0 reads: each room's `members()` call can
    // fetch /members over the network while holding the client lease, so an
    // unbounded scan would block logout/account switch for N rooms x the
    // request budget on a dead network.
    let contacts_by_id = run_bounded(async move {
        let mut contacts_by_id: HashMap<String, Contact> = HashMap::new();
        for room in client.rooms() {
            if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
                continue;
            }

            let members = room
                .members(matrix_sdk::RoomMemberships::JOIN)
                .await
                .map_err(|e| api_err("contacts", format!("获取联系人失败: {e}")))?;

            for member in members {
                let user_id = member.user_id().to_string();
                if my_user_id.as_deref() == Some(user_id.as_str()) {
                    continue;
                }

                let name = member.name().to_string();
                let avatar_url = member.avatar_url().map(|u| u.to_string());
                let contact = contacts_by_id
                    .entry(user_id.clone())
                    .or_insert_with(|| Contact {
                        id: user_id.clone(),
                        name: if name == user_id {
                            user_id.clone()
                        } else {
                            name.clone()
                        },
                        avatar_url: avatar_url.clone(),
                        status: user_id.clone(),
                    });

                if contact.name == contact.id && name != user_id {
                    contact.name = name;
                }
                if contact.avatar_url.is_none() && avatar_url.is_some() {
                    contact.avatar_url = avatar_url;
                }
            }
        }
        Ok(contacts_by_id)
    })
    .await?;

    let mut contacts: Vec<Contact> = contacts_by_id.into_values().collect();
    contacts.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.id.cmp(&b.id))
    });

    app_log(
        "info",
        "contacts",
        format!("get_contacts: {} unique contacts", contacts.len()),
    );
    Ok(contacts)
}

pub(super) async fn get_room_members(room_id: String) -> Result<Vec<Contact>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    // Bounded like the other P0 calls: `members()` can issue a network
    // /members request (lazy-loaded member list) while holding the client
    // lease.
    run_bounded(async move {
        let members = room
            .members(matrix_sdk::RoomMemberships::JOIN)
            .await
            .map_err(|e| api_err("rooms", format!("获取成员失败: {e}")))?;

        app_log(
            "info",
            "rooms",
            format!(
                "get_room_members: {} members in room {}",
                members.len(),
                room_id
            ),
        );

        let mut contacts = Vec::new();
        for member in members {
            let name = member.name().to_string();
            let user_id = member.user_id().to_string();
            let avatar = member.avatar_url().map(|u| u.to_string());
            contacts.push(Contact {
                id: user_id.clone(),
                name: if name == user_id {
                    user_id.clone()
                } else {
                    name
                },
                status: user_id,
                avatar_url: avatar,
            });
        }
        Ok(contacts)
    })
    .await
}

pub(super) async fn get_room_avatar_url(room_id: String) -> Option<String> {
    let client = get_client().await?;
    let room = get_room_by_id(&client, &room_id).ok()?;
    room.avatar_url().map(|u| u.to_string())
}

pub(super) async fn search_rooms(
    query: String,
    ignored_user_ids: Option<Vec<String>>,
    authoritative: bool,
) -> Result<Vec<ChatRoom>, String> {
    let all = get_chat_rooms(ignored_user_ids, authoritative).await?;
    let q = query.to_lowercase();
    let filtered: Vec<ChatRoom> = all
        .into_iter()
        .filter(|r| r.name.to_lowercase().contains(&q))
        .collect();
    Ok(filtered)
}
