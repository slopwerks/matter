//! Search history implementation.

use super::*;

pub(super) async fn load_older_search_history(
    client: &Client,
    room: &Room,
) -> Result<(bool, usize), String> {
    let mut metrics = search_metrics::SearchMetrics::new("history_page", true);
    let (room_cache, _drop_handles) = room.event_cache().await.map_err(|error| {
        api_err(
            "search",
            format!("Failed to open the room search cache: {error}"),
        )
    })?;
    let started = std::time::Instant::now();
    let outcome = room_cache
        .pagination()
        .run_backwards_once(SEARCH_HISTORY_BATCH_SIZE)
        .await
        .map_err(|error| {
            api_err(
                "search",
                format!("Failed to load older messages for search: {error}"),
            )
        })?;
    metrics.phase("history_fetch_decrypt_cache", started);
    let event_count = outcome.events.len();
    metrics.count("raw_events", event_count);
    if event_count > 0 {
        index_search_events(client, room, &room_cache, outcome.events).await?;
    }
    Ok((outcome.reached_start, event_count))
}

pub(super) fn message_search_room_key(client: &Client, room: &Room) -> Result<String, String> {
    message_search_scope_key(client, Some(room.room_id().as_str()))
}

pub(super) fn message_search_scope_key(
    client: &Client,
    room_id: Option<&str>,
) -> Result<String, String> {
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("search", "No logged-in account.".to_string()))?;
    Ok(format!("{user_id}\n{}", room_id.unwrap_or("*")))
}

pub(super) fn searchable_rooms(client: &Client) -> Vec<Room> {
    let mut rooms = client
        .rooms()
        .into_iter()
        .filter(|room| room.state() == matrix_sdk::RoomState::Joined && !room.is_space())
        .collect::<Vec<_>>();
    rooms.sort_by(|left, right| left.room_id().cmp(right.room_id()));
    rooms
}

pub(super) async fn message_search_backfill_lock(key: &str) -> Arc<Mutex<()>> {
    SEARCH_HISTORY_BACKFILLS
        .lock()
        .await
        .entry(key.to_owned())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

pub(super) async fn backfill_global_search_history_page(
    client: &Client,
) -> Result<MessageSearchBackfill, String> {
    let rooms = searchable_rooms(client);
    if rooms.is_empty() {
        return Ok(MessageSearchBackfill {
            loaded_events: 0,
            reached_start: true,
        });
    }

    let key = message_search_scope_key(client, None)?;
    let start = SEARCH_CACHE_BACKFILL_PROGRESS
        .lock()
        .await
        .get(&key)
        .copied()
        .unwrap_or(0)
        % rooms.len();
    for distance in 0..rooms.len() {
        let index = (start + distance) % rooms.len();
        let room = &rooms[index];
        let room_key = message_search_room_key(client, room)?;
        if cached_search_backfill_complete(client, room).await?
            && SEARCH_HISTORY_COMPLETE.lock().await.contains(&room_key)
        {
            continue;
        }
        let room_backfill_lock = message_search_backfill_lock(&room_key).await;
        let _room_backfill = room_backfill_lock.lock().await;
        let progress = backfill_room_search_history(client, room).await?;
        SEARCH_CACHE_BACKFILL_PROGRESS
            .lock()
            .await
            .insert(key.clone(), (index + 1) % rooms.len());
        if progress.loaded_events > 0 || !progress.reached_start {
            return Ok(MessageSearchBackfill {
                loaded_events: progress.loaded_events,
                reached_start: false,
            });
        }
    }

    SEARCH_CACHE_BACKFILL_PROGRESS.lock().await.remove(&key);
    Ok(MessageSearchBackfill {
        loaded_events: 0,
        reached_start: true,
    })
}

pub(super) async fn backfill_message_search_with_client(
    client: &Client,
    room_id: Option<String>,
) -> Result<MessageSearchBackfill, String> {
    let mut metrics = search_metrics::SearchMetrics::new("backfill", room_id.is_some());
    metrics.count("steps", 1);
    let key = message_search_scope_key(client, room_id.as_deref())?;
    let backfill_lock = message_search_backfill_lock(&key).await;
    let _backfill = backfill_lock.lock().await;

    let Some(room_id) = room_id else {
        return backfill_global_search_history_page(client).await;
    };
    let room = get_room_by_id(client, &room_id)?;
    backfill_room_search_history(client, &room).await
}

// Both scopes must complete the same cache and remote-history walk. A cache
// indexing marker says nothing about messages not yet downloaded from the room.
pub(super) async fn backfill_room_search_history(
    client: &Client,
    room: &Room,
) -> Result<MessageSearchBackfill, String> {
    let key = message_search_room_key(client, room)?;
    let (cache_complete, cached_events) = backfill_cached_search_index_page(client, room).await?;
    if !cache_complete {
        return Ok(MessageSearchBackfill {
            loaded_events: cached_events.min(u32::MAX as usize) as u32,
            reached_start: false,
        });
    }

    if SEARCH_HISTORY_COMPLETE.lock().await.contains(&key) {
        return Ok(MessageSearchBackfill {
            loaded_events: cached_events.min(u32::MAX as usize) as u32,
            reached_start: true,
        });
    }

    let (reached_start, remote_events) = load_older_search_history(client, room).await?;
    if reached_start {
        SEARCH_HISTORY_COMPLETE.lock().await.insert(key);
    }
    let loaded_events = cached_events.saturating_add(remote_events);
    Ok(MessageSearchBackfill {
        loaded_events: loaded_events.min(u32::MAX as usize) as u32,
        reached_start,
    })
}

pub(super) async fn backfill_message_search(
    room_id: Option<String>,
) -> Result<MessageSearchBackfill, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("search", "No client created.".to_string()))?;
    backfill_message_search_with_client(&client, room_id).await
}
