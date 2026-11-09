//! Search cached backfill implementation.

use super::*;

pub(super) async fn index_search_events(
    client: &Client,
    room: &Room,
    room_cache: &matrix_sdk::event_cache::RoomEventCache,
    events: Vec<matrix_sdk::deserialized_responses::TimelineEvent>,
) -> Result<(), String> {
    let mut metrics = search_metrics::SearchMetrics::new("index", true);
    metrics.count("raw_events", events.len());
    let redaction_rules = room.clone_info().room_version_rules_or_default().redaction;
    if events.is_empty() {
        return Ok(());
    }
    // One remote/cache page becomes one Tantivy transaction. Splitting a page
    // into tiny batches forced a commit, reader reload, and merge wait for each
    // slice and dominated first-search latency.
    let started = std::time::Instant::now();
    let mut index = client.search_index().lock().await;
    metrics.phase("index_lock_wait", started);
    let parsing = std::time::Instant::now();
    let result = index
        .bulk_handle_timeline_event(
            events.into_iter(),
            room_cache,
            room.room_id(),
            &redaction_rules,
        )
        .await
        .map_err(|error| {
            api_err(
                "search",
                format!("Failed to index cached messages: {error}"),
            )
        });
    metrics.phase("index_parse_and_write", parsing);
    metrics.phase("index_wait_and_commit", started);
    result
}

pub(super) async fn persisted_search_backfill_marker(
    client: &Client,
    room: &Room,
) -> Option<std::path::PathBuf> {
    let user_id = client.user_id()?;
    CLIENTS.read().await.get(user_id.as_str()).map(|entry| {
        let room_digest = Sha256::digest(room.room_id().as_str().as_bytes())
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        entry
            .search_index_dir
            .join(".cache-backfilled-v1")
            .join(room_digest)
    })
}

pub(super) async fn search_backfill_marker_exists(marker: &Path) -> Result<bool, String> {
    match tokio::fs::metadata(marker).await {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(api_err(
            "search",
            format!(
                "Failed to inspect search backfill marker at {}: {error}",
                marker.display()
            ),
        )),
    }
}

pub(super) async fn mark_cached_search_backfill_complete(
    marker: Option<&Path>,
) -> Result<(), String> {
    let Some(marker) = marker else {
        return Ok(());
    };
    if let Some(parent) = marker.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(|error| {
            api_err(
                "search",
                format!(
                    "Failed to create search backfill marker directory at {}: {error}",
                    parent.display()
                ),
            )
        })?;
    }
    tokio::fs::write(marker, b"complete\n")
        .await
        .map_err(|error| {
            api_err(
                "search",
                format!(
                    "Failed to persist search backfill marker at {}: {error}",
                    marker.display()
                ),
            )
        })
}

pub(super) async fn cached_search_backfill_complete(
    client: &Client,
    room: &Room,
) -> Result<bool, String> {
    let marker = persisted_search_backfill_marker(client, room).await;
    match marker.as_deref() {
        Some(marker) => search_backfill_marker_exists(marker).await,
        None => Ok(true),
    }
}

pub(super) async fn backfill_cached_search_index_page(
    client: &Client,
    room: &Room,
) -> Result<(bool, usize), String> {
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("search", "No logged-in account.".to_string()))?;
    let key = format!("{user_id}\n{}", room.room_id());
    let Some(persisted_marker) = persisted_search_backfill_marker(client, room).await else {
        return Ok((true, 0));
    };
    if search_backfill_marker_exists(&persisted_marker).await? {
        return Ok((true, 0));
    }

    let (room_cache, _drop_handles) = room.event_cache().await.map_err(|error| {
        api_err(
            "search",
            format!("Failed to open the room search cache: {error}"),
        )
    })?;
    let chunk_ids = {
        let store_state = client.event_cache_store().lock().await.map_err(|error| {
            api_err(
                "search",
                format!("Failed to lock cached messages for search: {error}"),
            )
        })?;
        let store = store_state.as_clean().ok_or_else(|| {
            api_err(
                "search",
                "Cached messages changed in another process".to_string(),
            )
        })?;
        let metadata = store
            .load_all_chunks_metadata(LinkedChunkId::Room(room.room_id()))
            .await
            .map_err(|error| {
                api_err(
                    "search",
                    format!("Failed to read cached message metadata: {error}"),
                )
            })?;
        ordered_event_cache_chunk_ids(metadata)?
    };
    // Copy newest chunks first so the first bounded step produces useful
    // recent search results instead of starting at the oldest cached event.
    let start = SEARCH_CACHE_BACKFILL_PROGRESS
        .lock()
        .await
        .get(&key)
        .copied()
        .unwrap_or(0)
        .min(chunk_ids.len());
    let mut processed_chunks = 0usize;
    let mut pending_events = Vec::with_capacity(SEARCH_CACHED_INDEX_BATCH_SIZE);
    for processed in start..chunk_ids.len() {
        let index = chunk_ids.len() - processed - 1;
        let identifier = chunk_ids[index];
        let next_identifier = chunk_ids.get(index + 1).copied();
        let chunk = {
            let store_state = client.event_cache_store().lock().await.map_err(|error| {
                api_err(
                    "search",
                    format!("Failed to lock a cached message chunk: {error}"),
                )
            })?;
            let store = store_state.as_clean().ok_or_else(|| {
                api_err(
                    "search",
                    "Cached messages changed in another process".to_string(),
                )
            })?;
            let chunk = if let Some(next_identifier) = next_identifier {
                store
                    .load_previous_chunk(LinkedChunkId::Room(room.room_id()), next_identifier)
                    .await
                    .map_err(|error| {
                        api_err(
                            "search",
                            format!("Failed to read a cached message chunk: {error}"),
                        )
                    })?
            } else {
                store
                    .load_last_chunk(LinkedChunkId::Room(room.room_id()))
                    .await
                    .map_err(|error| {
                        api_err(
                            "search",
                            format!("Failed to read the latest cached message chunk: {error}"),
                        )
                    })?
                    .0
            };
            chunk.ok_or_else(|| {
                api_err(
                    "search",
                    "A cached message chunk disappeared during indexing".to_string(),
                )
            })?
        };
        if chunk.identifier != identifier {
            return Err(api_err(
                "search",
                "Cached message chunks changed during indexing".to_string(),
            ));
        }
        processed_chunks += 1;
        if let ChunkContent::Items(events) = chunk.content {
            pending_events.extend(events);
        }
        if pending_events.len() >= SEARCH_CACHED_INDEX_BATCH_SIZE {
            break;
        }
    }

    let event_count = pending_events.len();
    if event_count > 0 {
        index_search_events(client, room, &room_cache, pending_events).await?;
    }
    let next = start.saturating_add(processed_chunks);
    let complete = next >= chunk_ids.len();
    if complete {
        SEARCH_CACHE_BACKFILL_PROGRESS.lock().await.remove(&key);
        mark_cached_search_backfill_complete(Some(&persisted_marker)).await?;
    } else {
        SEARCH_CACHE_BACKFILL_PROGRESS
            .lock()
            .await
            .insert(key, next);
    }
    Ok((complete, event_count))
}
