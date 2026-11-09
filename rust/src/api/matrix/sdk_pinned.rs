//! Sdk pinned adaptation.
use super::*;

/// Fallback read of the pinned list from the local state store, used when
/// the server read fails or times out. The stored list may lag the server
/// (e.g. our own latest toggle has not echoed yet), but a stale list beats
/// failing the whole page; the pinned page re-reads after every sync echo.
pub(in crate::api::matrix) async fn pinned_ids_from_store(
    room: &Room,
) -> Result<Vec<matrix_sdk::ruma::OwnedEventId>, String> {
    match room
        .get_state_event_static::<
            matrix_sdk::ruma::events::room::pinned_events::RoomPinnedEventsEventContent,
        >()
        .await
    {
        Ok(Some(raw)) => raw
            .deserialize()
            .map(|event| match event.as_sync() {
                Some(matrix_sdk::ruma::events::SyncStateEvent::Original(original)) => {
                    original.content.pinned.clone()
                }
                _ => Vec::new(),
            })
            // A corrupt local state event is not "no pins": treating it as
            // empty would decide the wrong menu direction. Surface the
            // error, same as `get_pinned_event_ids`'s store fallback.
            .map_err(|error| api_err("pinned", format!("无法解析本地置顶状态，请重试: {error}"))),
        // `get_state_event_static` is a pure local-store read: `None`
        // means the synced store definitively has no such state event
        // (the room was never pinned) — show the empty state rather
        // than failing the page.
        Ok(None) => Ok(Vec::new()),
        // The store read itself failed: attribute the error to the STORE,
        // not to the network read that triggered the fallback (its
        // `source_error` would mislead — the network may be fine).
        Err(error) => Err(api_err("pinned", format!("无法读取本地置顶状态，请重试: {error}"))),
    }
}

pub(in crate::api::matrix) async fn get_pinned_messages(
    room: &Room,
) -> Result<Vec<ChatMessage>, String> {
    // Bound the server read more tightly than the client default (the SDK's
    // RequestConfig already caps a single request at 30s, but with 3
    // retries a dead network could still stall here) — the whole call
    // holds the client lease (blocking logout/account switch). On timeout,
    // fall back to the local store like any other network error.
    let pinned_ids =
        match tokio::time::timeout(Duration::from_secs(15), room.load_pinned_events()).await {
            Ok(Ok(ids)) => ids.unwrap_or_default(),
            Ok(Err(_)) => {
                // Offline fallback: the pinned list also lives in the local
                // state store.
                pinned_ids_from_store(room).await?
            }
            Err(_) => {
                super::super::app_log(
                    "warn",
                    "pinned",
                    "Timed out loading pinned events; falling back to the local store.".to_string(),
                );
                pinned_ids_from_store(room).await?
            }
        };
    if pinned_ids.is_empty() {
        return Ok(Vec::new());
    }

    let max_events_to_load = room
        .client()
        .event_cache()
        .config()
        .max_pinned_events_to_load;
    let expected_pinned_ids: Vec<_> = pinned_ids
        .iter()
        .rev()
        .take(max_events_to_load)
        .map(|event_id| event_id.as_ref())
        .collect();

    let (pinned_events_cache, _event_cache_drop_handles) = room
        .client()
        .event_cache()
        .pinned_events(room.room_id())
        .await
        .map_err(|error| api_err("pinned", format!("加载置顶消息失败: {error}")))?;
    let (events, mut updates) = pinned_events_cache
        .subscribe()
        .await
        .map_err(|error| api_err("pinned", format!("加载置顶消息失败: {error}")))?;
    let mut events: matrix_sdk_ui::eyeball_im::Vector<_> = events.into();
    // Bounded cache wait. Stage budgets: 15s list read + 20s cache wait +
    // 10s pinned-timeline build + 25s focused fetch = 70s, below the
    // FFI-level 90s total bound, so the inner stage timeouts (which degrade
    // to partial results) fire before the outer bound (which fails the
    // whole page). A cache error or timeout never fails the page by itself:
    // the focused per-event fetch below decides between placeholders and
    // transport errors, so the wait result is not surfaced.
    let _ = tokio::time::timeout(Duration::from_secs(20), async {
        let mut saw_network_update = false;
        loop {
            let loaded_ids = loaded_expected_event_ids(
                events.iter().filter_map(|event| event.event_id()),
                &expected_pinned_ids,
            );
            if pinned_events_ready(
                loaded_ids.len(),
                expected_pinned_ids.len(),
                saw_network_update,
            ) {
                break;
            }

            let update = if saw_network_update {
                match tokio::time::timeout(Duration::from_millis(750), updates.recv()).await {
                    Ok(result) => result.map_err(|error| error.to_string())?,
                    Err(_) => break,
                }
            } else {
                // The cache listener stays silent when every /event fetch
                // fails, so an unbounded wait here would stall for the full
                // outer timeout. Fall through to the focused timeline instead.
                match tokio::time::timeout(Duration::from_secs(5), updates.recv()).await {
                    Ok(result) => result.map_err(|error| error.to_string())?,
                    Err(_) => break,
                }
            };
            let came_from_sync = matches!(update.origin, EventsOrigin::Sync);
            for diff in update.diffs {
                diff.apply(&mut events);
            }
            saw_network_update |= came_from_sync;
        }
        Ok::<(), String>(())
    })
    .await;

    let loaded_count = loaded_expected_event_count(
        events.iter().filter_map(|event| event.event_id()),
        &expected_pinned_ids,
    );

    let mut by_id = HashMap::new();
    if loaded_count > 0 {
        // Bound the build: its /event requests have no SDK timeout and the
        // lease is held; on failure or timeout the events it would have
        // provided are left to the focused fetch below, so the outer total
        // bound stays the last safety net.
        match tokio::time::timeout(
            Duration::from_secs(10),
            TimelineBuilder::new(room)
                .with_focus(TimelineFocus::PinnedEvents)
                .build(),
        )
        .await
        {
            Ok(Ok(timeline)) => {
                let items = snapshot(&timeline).await;
                by_id.extend(
                    convert_snapshot(room, &items)
                        .await
                        .into_iter()
                        .map(|message| (message.id.clone(), message)),
                );
            }
            Ok(Err(error)) => {
                super::super::app_log("warn", "pinned", format!("加载置顶消息失败: {error}"));
            }
            Err(_) => {
                super::super::app_log("warn", "pinned", "构建置顶时间线超时。".to_owned());
            }
        }
    }

    let missing_ids = missing_pinned_event_ids(&pinned_ids, &by_id);
    // The focused fetch below deliberately covers ALL pinned ids, not just
    // the `max_pinned_events_to_load` cache bound: that bound only limits
    // how many events the cache-wait above expects, while the pinned list
    // itself is authoritative — older pins beyond the bound must still be
    // listed, fetched individually when the cache does not hold them.
    // A slow network may exhaust the 25s budget, degrading those events to
    // placeholder messages rather than hiding them.
    // Bound the aggregate focused fetch: each missing event triggers a
    // TimelineBuilder build whose /context request has no HTTP timeout in
    // the SDK, and the client lease is held for the whole call — an
    // unbounded wait here would block account logout/switch indefinitely.
    // On timeout, degrade to the partially loaded list (placeholder
    // messages stand in for the missing events).
    let fetched = match tokio::time::timeout(
        Duration::from_secs(25),
        stream::iter(missing_ids)
            .map(|event_id| {
                let room = room.clone();
                async move {
                    let result = load_focused_message(&room, event_id.clone()).await;
                    (event_id, result)
                }
            })
            .buffer_unordered(8)
            .collect::<Vec<_>>(),
    )
    .await
    {
        Ok(fetched) => fetched,
        Err(_) => {
            // Surface the aggregate timeout as a focused error: without it,
            // an all-timed-out load would degrade into "message deleted"
            // placeholders (or, when nothing loaded at all, a bare
            // placeholder list) instead of an actionable failure. Events
            // that were still missing are transport failures, so mark them
            // as such for the placeholder text.
            super::super::app_log(
                "warn",
                "pinned",
                "Timed out fetching pinned events.".to_string(),
            );
            let missing = missing_pinned_event_ids(&pinned_ids, &by_id)
                .into_iter()
                .map(|event_id| event_id.to_string())
                .collect::<HashSet<_>>();
            return complete_pinned_messages(
                &pinned_ids,
                &by_id,
                &missing,
                Some("加载置顶事件超时。".to_owned()),
            );
        }
    };
    let mut focused_error = None;
    let mut failed_ids = HashSet::new();
    for (event_id, result) in fetched {
        match result {
            Ok(Some(message)) => {
                by_id.insert(event_id.to_string(), message);
            }
            Ok(None) => {}
            Err(error) => {
                focused_error.get_or_insert_with(|| error.clone());
                failed_ids.insert(event_id.to_string());
                super::super::app_log("warn", "pinned", format!("加载置顶事件失败: {error}"));
            }
        }
    }

    complete_pinned_messages(&pinned_ids, &by_id, &failed_ids, focused_error)
}

pub(in crate::api::matrix) async fn load_focused_message(
    room: &Room,
    event_id: matrix_sdk::ruma::OwnedEventId,
) -> Result<Option<ChatMessage>, String> {
    let timeline = TimelineBuilder::new(room)
        .with_focus(TimelineFocus::Event {
            target: event_id.clone(),
            num_context_events: 0,
            thread_mode: TimelineEventFocusThreadMode::Automatic {
                hide_threaded_events: false,
            },
        })
        .build()
        .await
        .map_err(|error| format!("加载事件失败: {error}"))?;
    Ok(convert_snapshot(room, &snapshot(&timeline).await)
        .await
        .into_iter()
        .find(|message| message.id == event_id.as_str()))
}

#[cfg(test)]
pub(in crate::api::matrix) fn ordered_pinned_messages(
    pinned_ids: &[matrix_sdk::ruma::OwnedEventId],
    by_id: &HashMap<String, ChatMessage>,
) -> Vec<ChatMessage> {
    pinned_ids
        .iter()
        .filter_map(|event_id| by_id.get(event_id.as_str()).cloned())
        .collect()
}

pub(in crate::api::matrix) fn missing_pinned_event_ids(
    pinned_ids: &[matrix_sdk::ruma::OwnedEventId],
    by_id: &HashMap<String, ChatMessage>,
) -> Vec<matrix_sdk::ruma::OwnedEventId> {
    pinned_ids
        .iter()
        .filter(|event_id| !by_id.contains_key(event_id.as_str()))
        .cloned()
        .collect()
}

pub(in crate::api::matrix) fn complete_pinned_messages(
    pinned_ids: &[matrix_sdk::ruma::OwnedEventId],
    by_id: &HashMap<String, ChatMessage>,
    failed_ids: &HashSet<String>,
    focused_error: Option<String>,
) -> Result<Vec<ChatMessage>, String> {
    // A load where every pinned event failed to fetch is a transport-level
    // failure when the focused fetch itself reports an error: an unreachable
    // server must surface as a retryable error, not as "deleted" placeholders.
    // When every focused lookup returns Ok(None) with no error, the events
    // are genuinely unavailable (a redacted message stays pinned) and
    // placeholders stand in for them — earlier cache-side failures are not
    // surfaced here, the focused fetch is the authoritative availability
    // signal.
    if !pinned_ids.is_empty() && by_id.is_empty() {
        if let Some(error) = focused_error {
            return Err(format!("加载置顶消息失败: {error}"));
        }
    }
    Ok(pinned_ids
        .iter()
        .map(|event_id| {
            by_id.get(event_id.as_str()).cloned().unwrap_or_else(|| {
                if failed_ids.contains(event_id.as_str()) {
                    // Transport-level failure for this event: the
                    // placeholder must not masquerade as "deleted".
                    failed_pinned_message(event_id)
                } else {
                    unavailable_pinned_message(event_id)
                }
            })
        })
        .collect())
}

pub(in crate::api::matrix) fn failed_pinned_message(
    event_id: &matrix_sdk::ruma::EventId,
) -> ChatMessage {
    base_message(
        event_id.as_str(),
        "",
        "系统",
        "",
        false,
        "此置顶消息加载失败，请下拉刷新重试".to_owned(),
        None,
        Vec::new(),
        false,
        MessageType::Event,
        None,
    )
}

pub(in crate::api::matrix) fn unavailable_pinned_message(
    event_id: &matrix_sdk::ruma::EventId,
) -> ChatMessage {
    base_message(
        event_id.as_str(),
        "",
        "系统",
        "",
        false,
        "此置顶消息不可用或已被删除".to_owned(),
        None,
        Vec::new(),
        false,
        MessageType::Event,
        None,
    )
}
