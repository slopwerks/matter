//! Sdk live adaptation.
use super::*;

pub(in crate::api::matrix) fn timeline_key(client: &Client, room: &Room) -> Result<String, String> {
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("rooms", "No active user".to_string()))?;
    Ok(format!("{}\n{}", user_id, room.room_id()))
}

/// Drop the timelines of ONE account (key prefix `{user_id}\n`), leaving
/// the other accounts' timelines intact (a removed account's cache must
/// not tear down the timelines of the account the user is currently in).
pub(in crate::api::matrix) async fn clear_for_user(user_id: &str) {
    let prefix = format!("{user_id}\n");
    TIMELINES
        .lock()
        .await
        .retain(|key, _| !key.starts_with(&prefix));
    REACTION_LOCKS
        .lock()
        .await
        .retain(|key, _| !key.starts_with(&prefix));
}

pub(in crate::api::matrix) async fn get_or_create_timeline(
    client: &Client,
    room: &Room,
) -> Result<Arc<Timeline>, String> {
    let key = timeline_key(client, room)?;
    if let Some(timeline) = TIMELINES.lock().await.get(&key).cloned() {
        return Ok(timeline);
    }

    let timeline = Arc::new(
        TimelineBuilder::new(room)
            .track_read_marker_and_receipts(TimelineReadReceiptTracking::AllEvents)
            .build()
            .await
            .map_err(|error| api_err("rooms", format!("构建房间时间线失败: {error}")))?,
    );
    let mut timelines = TIMELINES.lock().await;
    Ok(timelines
        .entry(key)
        .or_insert_with(|| timeline.clone())
        .clone())
}

pub(in crate::api::matrix) async fn snapshot(timeline: &Timeline) -> Vec<Arc<TimelineItem>> {
    let (items, updates) = timeline.subscribe().await;
    drop(updates);
    items.into_iter().collect()
}

pub(in crate::api::matrix) fn remote_event_count(items: &[Arc<TimelineItem>]) -> usize {
    items
        .iter()
        .filter_map(|item| item.as_event())
        .filter(|event| event.event_id().is_some())
        .count()
}

pub(in crate::api::matrix) fn loaded_expected_event_count<I, S>(
    loaded_ids: I,
    expected_ids: &[&matrix_sdk::ruma::EventId],
) -> usize
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    loaded_expected_event_ids(loaded_ids, expected_ids).len()
}

pub(in crate::api::matrix) fn loaded_expected_event_ids<I, S>(
    loaded_ids: I,
    expected_ids: &[&matrix_sdk::ruma::EventId],
) -> std::collections::HashSet<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let loaded_ids: std::collections::HashSet<_> = loaded_ids
        .into_iter()
        .map(|event_id| event_id.as_ref().to_owned())
        .collect();
    expected_ids
        .iter()
        .filter(|expected_id| loaded_ids.contains(expected_id.as_str()))
        .map(|event_id| event_id.to_string())
        .collect()
}

pub(in crate::api::matrix) fn pinned_events_ready(
    loaded_expected_events: usize,
    expected_events: usize,
    saw_network_update: bool,
) -> bool {
    loaded_expected_events == expected_events || (saw_network_update && loaded_expected_events > 0)
}

pub(in crate::api::matrix) async fn ensure_initial_window(
    timeline: &Timeline,
    target: usize,
) -> Result<(), String> {
    for _ in 0..4 {
        let items = snapshot(timeline).await;
        let count = remote_event_count(&items);
        if count >= target {
            return Ok(());
        }
        let requested = target.saturating_sub(count).clamp(20, u16::MAX as usize) as u16;
        let hit_start = timeline
            .paginate_backwards(requested)
            .await
            .map_err(|error| api_err("rooms", format!("分页加载房间时间线失败: {error}")))?;
        let updated_count = remote_event_count(&snapshot(timeline).await);
        if hit_start || updated_count <= count {
            return Ok(());
        }
    }
    Ok(())
}

pub(in crate::api::matrix) async fn get_messages(
    client: &Client,
    room: &Room,
) -> Result<Vec<ChatMessage>, String> {
    const LIVE_WINDOW: usize = 100;

    let timeline = get_or_create_timeline(client, room).await?;
    ensure_initial_window(&timeline, LIVE_WINDOW).await?;

    let mut messages = convert_snapshot(room, &snapshot(&timeline).await).await;
    if messages.len() > LIVE_WINDOW {
        messages.drain(..messages.len() - LIVE_WINDOW);
    }
    Ok(messages)
}
