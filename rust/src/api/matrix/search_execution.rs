//! Search execution implementation.

use super::*;

pub(super) async fn search_messages(
    query: String,
    room_id: Option<String>,
    offset: u32,
    limit: u32,
    ignored_user_ids: Option<Vec<String>>,
) -> Result<MessageSearchPage, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("search", "No client created.".to_string()))?;
    search_messages_with_client(&client, query, room_id, offset, limit, ignored_user_ids).await
}

pub(super) async fn search_messages_with_client(
    client: &Client,
    query: String,
    room_id: Option<String>,
    offset: u32,
    limit: u32,
    ignored_user_ids: Option<Vec<String>>,
) -> Result<MessageSearchPage, String> {
    let mut metrics = search_metrics::SearchMetrics::new("query", room_id.is_some());
    let terms = message_search_terms(query.trim());
    if terms.is_empty() {
        return Ok(MessageSearchPage {
            results: Vec::new(),
            has_more: false,
            terms,
            history_complete: true,
        });
    }

    let (search_key, search_generation) = begin_message_search(client, room_id.as_deref()).await;
    let room_scoped = room_id.is_some();
    let rooms = if let Some(room_id) = room_id {
        vec![get_room_by_id(client, &room_id)?]
    } else {
        searchable_rooms(client)
    };
    let ignored_user_ids = ignored_user_ids.map(|ids| ids.into_iter().collect::<HashSet<_>>());
    let index_query = message_search_index_query(&terms);
    let offset = offset as usize;
    let limit = limit.max(1) as usize;
    let result_target = offset.saturating_add(limit).saturating_add(1);
    let room_target = result_target;
    let batch_size = room_target.clamp(32, 128);
    let mut results = HashMap::new();
    let mut successful_rooms = 0usize;
    let mut room_failures = Vec::new();
    let mut history_complete = true;

    for room in rooms {
        metrics.count("rooms", 1);
        if !message_search_is_current(&search_key, search_generation).await {
            return Err(message_search_cancelled());
        }
        let cache_complete = match cached_search_backfill_complete(client, &room).await {
            Ok(complete) => complete,
            Err(error) => {
                app_log(
                    "warn",
                    "search",
                    format!(
                        "Could not inspect search backfill state for {}: {error}",
                        room.room_id()
                    ),
                );
                false
            }
        };
        let key = message_search_room_key(client, &room)?;
        history_complete &= cache_complete && SEARCH_HISTORY_COMPLETE.lock().await.contains(&key);
        let is_dm = match room.is_direct().await {
            Ok(true) => true,
            Ok(false) | Err(_) => is_dm_by_members(&room).await,
        };
        let sender_names = search_hydration::SenderNames::new();
        let mut raw_offset = 0usize;
        let mut room_result_ids = HashSet::new();
        let mut room_succeeded = false;
        loop {
            if !message_search_is_current(&search_key, search_generation).await {
                return Err(message_search_cancelled());
            }
            let started = std::time::Instant::now();
            let searched = room
                .search(&index_query, batch_size, Some(raw_offset))
                .await;
            metrics.phase("index_query", started);
            metrics.count("index_batches", 1);
            let event_ids = match searched {
                Ok(event_ids) => event_ids,
                Err(error) => {
                    let error = api_err("search", format!("Message search failed: {error}"));
                    if room_scoped {
                        return Err(error);
                    }
                    app_log(
                        "warn",
                        "search",
                        format!("Skipping failed room search {}: {error}", room.room_id()),
                    );
                    room_failures.push(error);
                    break;
                }
            };
            room_succeeded = true;
            let raw_exhausted = event_ids.len() < batch_size;
            raw_offset = raw_offset.saturating_add(event_ids.len());
            let batch_started = std::time::Instant::now();
            let hydrated = search_hydration::HydrationContext {
                client,
                room: &room,
                terms: &terms,
                ignored: ignored_user_ids.as_ref(),
                is_dm,
                sender_names: &sender_names,
                search_key: &search_key,
                generation: search_generation,
            }
            .hydrate(event_ids.into_iter().map(|(_, id)| id).collect())
            .await;
            metrics.phase("hydration_batch_wall", batch_started);
            if !message_search_is_current(&search_key, search_generation).await {
                return Err(message_search_cancelled());
            }
            for candidate in hydrated {
                if candidate.attempted {
                    metrics.count("candidate_events", 1);
                }
                if candidate.cache_hit {
                    metrics.count("cache_hits", 1);
                }
                if candidate.remote_fetch {
                    metrics.count("remote_fetches", 1);
                }
                // Concurrent work durations are sums, not additive wall time.
                metrics.accumulated_us("event_hydration_sum", candidate.hydration_us);
                metrics.accumulated_us("filter_and_metadata_sum", candidate.conversion_us);
                if let Some((result, source_timestamp, source_event_id)) = candidate.result {
                    room_result_ids.insert(result.event_id.clone());
                    insert_latest_search_result(
                        &mut results,
                        result,
                        source_timestamp,
                        source_event_id,
                    );
                }
            }
            if room_result_ids.len() >= room_target {
                break;
            }
            if raw_exhausted {
                break;
            }
        }
        if room_succeeded {
            successful_rooms += 1;
        }
    }

    if successful_rooms == 0 {
        if let Some(error) = room_failures.into_iter().next() {
            return Err(error);
        }
    }

    let started = std::time::Instant::now();
    let mut results = results
        .into_values()
        .map(|(result, _, _)| result)
        .collect::<Vec<_>>();
    results.sort_by(|left, right| {
        right
            .timestamp
            .parse::<u64>()
            .unwrap_or_default()
            .cmp(&left.timestamp.parse::<u64>().unwrap_or_default())
            .then_with(|| right.event_id.cmp(&left.event_id))
    });

    metrics.phase("result_merge_sort", started);
    let (page, has_more) = paginate_message_search_results(results, offset, limit);
    metrics.count("returned_results", page.len());
    Ok(MessageSearchPage {
        results: page,
        has_more,
        terms,
        history_complete,
    })
}
