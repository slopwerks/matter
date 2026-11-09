//! Sdk history adaptation.
use super::*;

pub(in crate::api::matrix) async fn get_messages_before(
    client: &Client,
    room: &Room,
    from_event_id: &str,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let timeline = get_or_create_timeline(client, room).await?;
    let limit = limit.min(u16::MAX as u32) as usize;
    if limit == 0 {
        return Ok(Vec::new());
    }
    // A local (unsent) message ID — `local_outgoing_pending:` / `sent:` /
    // `failed:` — can never match a timeline event, and the focused fallback
    // below would reject it as an invalid event ID. The pre-Timeline code
    // returned an empty page for an unknown local anchor, ending history
    // loading gracefully; the caller re-anchors from the returned messages,
    // so an empty page is the correct end here too — and it skips the
    // pointless pagination rounds that would run before the fallback.
    if matrix_sdk::ruma::EventId::parse(from_event_id).is_err() {
        return Ok(Vec::new());
    }

    // The anchor (usually the oldest cached message from a previous session)
    // can sit outside the current timeline window when the cache is deeper
    // than the window. Paginate until the anchor is visible or history ends;
    // otherwise the first page would silently return nothing and the caller
    // would stop paginating, cutting off all older history.
    let mut anchor_visible = false;
    for _ in 0..4 {
        if raw_event_position(&snapshot(&timeline).await, from_event_id).is_some() {
            anchor_visible = true;
            break;
        }
        let hit_start = timeline
            .paginate_backwards(100u16)
            .await
            .map_err(|error| api_err("rooms", format!("分页加载房间时间线失败: {error}")))?;
        if raw_event_position(&snapshot(&timeline).await, from_event_id).is_some() {
            anchor_visible = true;
            break;
        }
        if hit_start {
            break;
        }
    }
    // Still invisible: the window may have SLID past the anchor (new
    // messages arriving while the caller browsed history push the old end
    // out). Keep extending before falling back to a focused context request.
    if !anchor_visible {
        for _ in 0..9 {
            let hit_start = timeline
                .paginate_backwards(100u16)
                .await
                .map_err(|error| api_err("rooms", format!("分页加载房间时间线失败: {error}")))?;
            if raw_event_position(&snapshot(&timeline).await, from_event_id).is_some() {
                anchor_visible = true;
                break;
            }
            if hit_start {
                break;
            }
        }
    }

    if !anchor_visible {
        // Never guess from the live window here: all of it may be newer than
        // the caller's anchor, so Dart would dedupe the result and conclude
        // that history ended. A focused request gives us an actual slice
        // around a deep or filtered anchor.
        return focused_messages_before(room, from_event_id, limit).await;
    }
    let items = snapshot(&timeline).await;
    let position = raw_event_position(&items, from_event_id)
        .ok_or_else(|| api_err("rooms", "分页锚点已离开当前时间线窗口，请重试。".to_owned()))?;
    let mut before = convert_snapshot(room, &items[..position]).await;
    // Fill the page: the caller re-anchors at the page's oldest, so every
    // returned message must be genuinely older than its anchor. When the
    // anchor sits at the window's edge (the caller has loaded everything
    // the window holds), an empty return would end history loading with
    // older messages still reachable — paginate until the page is full or
    // history ends instead.
    let mut reached_start = false;
    for _ in 0..4 {
        if before.len() >= limit {
            break;
        }
        let hit_start = timeline
            .paginate_backwards(100u16)
            .await
            .map_err(|error| api_err("rooms", format!("分页加载房间时间线失败: {error}")))?;
        let items = snapshot(&timeline).await;
        let position = raw_event_position(&items, from_event_id)
            .ok_or_else(|| api_err("rooms", "分页锚点已离开当前时间线窗口，请重试。".to_owned()))?;
        before = convert_snapshot(room, &items[..position]).await;
        reached_start = hit_start;
        if hit_start {
            break;
        }
    }
    checked_history_page(before, limit, reached_start)
}

pub(in crate::api::matrix) fn raw_event_position(
    items: &[Arc<TimelineItem>],
    event_id: &str,
) -> Option<usize> {
    items.iter().position(|item| {
        item.as_event()
            .and_then(EventTimelineItem::event_id)
            .is_some_and(|candidate| candidate.as_str() == event_id)
    })
}

pub(in crate::api::matrix) async fn focused_messages_before(
    room: &Room,
    from_event_id: &str,
    limit: usize,
) -> Result<Vec<ChatMessage>, String> {
    let target = matrix_sdk::ruma::EventId::parse(from_event_id)
        .map_err(|error| api_err("rooms", format!("无效的分页事件 ID: {error}")))?;
    let timeline = tokio::time::timeout(
        Duration::from_secs(25),
        TimelineBuilder::new(room)
            .with_focus(TimelineFocus::Event {
                target,
                num_context_events: limit.clamp(20, u16::MAX as usize) as u16,
                thread_mode: TimelineEventFocusThreadMode::Automatic {
                    hide_threaded_events: false,
                },
            })
            .build(),
    )
    .await
    .map_err(|_| api_err("rooms", "加载分页锚点超时，请重试。".to_owned()))?
    .map_err(|error| api_err("rooms", format!("加载分页锚点失败: {error}")))?;
    let items = snapshot(&timeline).await;
    let position = raw_event_position(&items, from_event_id)
        .ok_or_else(|| api_err("rooms", "分页锚点不可用，请重试。".to_owned()))?;
    let mut before = convert_snapshot(room, &items[..position]).await;
    let mut reached_start = false;
    for _ in 0..4 {
        if !before.is_empty() {
            break;
        }
        reached_start = timeline
            .paginate_backwards(100)
            .await
            .map_err(|error| api_err("rooms", format!("分页加载房间时间线失败: {error}")))?;
        let items = snapshot(&timeline).await;
        let position = raw_event_position(&items, from_event_id)
            .ok_or_else(|| api_err("rooms", "分页锚点不可用，请重试。".to_owned()))?;
        before = convert_snapshot(room, &items[..position]).await;
        if reached_start {
            break;
        }
    }
    checked_history_page(before, limit, reached_start)
}

pub(in crate::api::matrix) fn checked_history_page(
    before: Vec<ChatMessage>,
    limit: usize,
    reached_start: bool,
) -> Result<Vec<ChatMessage>, String> {
    // A budget exhausted by reactions/filtered events (or a pending SDK
    // update) is not proof that history ended. Keep Dart's retry path open.
    if before.is_empty() && !reached_start {
        return Err(api_err(
            "rooms",
            "尚未取得更早消息，历史未到头，请重试。".to_owned(),
        ));
    }
    Ok(before[before.len().saturating_sub(limit)..].to_vec())
}

pub(in crate::api::matrix) async fn get_messages_around(
    room: &Room,
    event_id: &str,
    limit: usize,
) -> Result<Vec<ChatMessage>, String> {
    super::super::history::messages_around(room, event_id, limit).await
}
