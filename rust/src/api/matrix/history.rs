//! Room-ordered context and forward pages, including threaded replies.

use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};

use flutter_rust_bridge::frb;
use futures_util::{stream, StreamExt};
use matrix_sdk::{
    deserialized_responses::TimelineEvent,
    room::MessagesOptions,
    ruma::{EventId, OwnedEventId},
    Room,
};
use matrix_sdk_ui::timeline::{
    default_event_filter, TimelineBuilder, TimelineEventFocusThreadMode, TimelineFocus,
};

use super::{api_err, sdk_timeline, ChatMessage};

#[frb]
#[derive(Clone, Debug)]
pub struct HistoryPage {
    pub messages: Vec<ChatMessage>,
    /// Last scanned server event, even if the page contains only hidden events.
    pub next_event_id: Option<String>,
    pub has_more: bool,
}

pub(super) async fn messages_after(
    room: &Room,
    from_event_id: &str,
    limit: u32,
) -> Result<HistoryPage, String> {
    let limit = limit.min(100) as usize;
    if limit == 0 {
        return Ok(HistoryPage {
            messages: Vec::new(),
            next_event_id: None,
            has_more: false,
        });
    }
    let target = EventId::parse(from_event_id)
        .map_err(|error| api_err("rooms", format!("无效的分页事件 ID: {error}")))?;
    let context = room
        .event_with_context(&target, true, (limit as u32).into(), None)
        .await
        .map_err(|error| api_err("rooms", format!("加载更新消息失败: {error}")))?;
    let mut events = context.events_after;
    let mut next = context.next_batch_token;
    let mut seen_tokens = HashSet::new();
    // Empty raw pages can still have a continuation token. The enclosing FFI
    // deadline bounds this walk; an empty page alone must never close history.
    while events.is_empty() {
        let Some(token) = next.take() else {
            return Ok(HistoryPage {
                messages: Vec::new(),
                next_event_id: None,
                has_more: false,
            });
        };
        if !seen_tokens.insert(token.clone()) {
            return Err(api_err(
                "rooms",
                "更新消息分页没有前进，请重试。".to_owned(),
            ));
        }
        let mut options = MessagesOptions::forward().from(Some(token.as_str()));
        options.limit = (limit as u32).into();
        let page = room
            .messages(options)
            .await
            .map_err(|error| api_err("rooms", format!("继续加载更新消息失败: {error}")))?;
        events = page.chunk;
        next = page.end;
    }
    let has_more = next.is_some() || events.len() > limit;
    events.truncate(limit);
    let next_event_id = events
        .iter()
        .rev()
        .find_map(|event| event.event_id().map(ToString::to_string))
        .ok_or_else(|| api_err("rooms", "更新消息没有有效的分页锚点，请重试。".to_owned()))?;
    let messages = convert_room_events(room, &events).await?;
    Ok(HistoryPage {
        messages,
        next_event_id: Some(next_event_id),
        has_more,
    })
}

pub(super) async fn messages_around(
    room: &Room,
    event_id: &str,
    limit: usize,
) -> Result<Vec<ChatMessage>, String> {
    let target = EventId::parse(event_id)
        .map_err(|error| api_err("rooms", format!("无效的目标事件 ID: {error}")))?;
    let context = room
        .event_with_context(&target, true, (limit.clamp(20, 100) as u32).into(), None)
        .await
        .map_err(|error| api_err("rooms", format!("加载目标消息失败: {error}")))?;
    let mut events = context.events_before;
    events.reverse();
    events.extend(context.event);
    events.extend(context.events_after);
    let messages = convert_room_events(room, &events).await?;
    if !messages.iter().any(|message| message.id == event_id) {
        return Err(api_err("rooms", "目标消息不可用或已被删除。".to_owned()));
    }
    Ok(messages)
}

pub(super) async fn convert_room_events(
    room: &Room,
    events: &[TimelineEvent],
) -> Result<Vec<ChatMessage>, String> {
    let rules = room.clone_info().room_version_rules_or_default();
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();
    for event in events {
        let raw = event
            .raw()
            .deserialize()
            .map_err(|error| api_err("rooms", format!("解析历史消息失败: {error}")))?;
        if !default_event_filter(&raw, &rules) {
            continue;
        }
        let Some(id) = event.event_id() else {
            continue;
        };
        if !seen.insert(id.to_owned()) {
            continue;
        }
        let threaded = event
            .raw()
            .get_field::<serde_json::Value>("content")
            .ok()
            .flatten()
            .and_then(|content| content.get("m.relates_to").cloned())
            .and_then(|relation| {
                relation
                    .get("rel_type")
                    .and_then(|value| value.as_str())
                    .map(|value| value == "m.thread")
            })
            .unwrap_or(false);
        candidates.push((id.to_owned(), threaded));
    }
    if candidates.is_empty() {
        return Ok(Vec::new());
    }
    // Event focus in SDK 0.19.1 filters thread replies even for a room-mode
    // anchor. Batch-convert the main context, then supplement omitted events.
    // The raw room page, not a focused thread's order/end, remains authoritative.
    let middle = candidates.len() / 2;
    let primary = candidates
        .iter()
        .skip(middle)
        .chain(candidates.iter().take(middle))
        .find(|(_, threaded)| !threaded)
        .unwrap_or(&candidates[middle])
        .0
        .clone();
    let timeline = tokio::time::timeout(
        Duration::from_secs(25),
        TimelineBuilder::new(room)
            .with_focus(TimelineFocus::Event {
                target: primary,
                num_context_events: events.len().clamp(20, 100) as u16,
                thread_mode: TimelineEventFocusThreadMode::Automatic {
                    hide_threaded_events: false,
                },
            })
            .build(),
    )
    .await
    .map_err(|_| api_err("rooms", "加载历史消息超时，请重试。".to_owned()))?
    .map_err(|error| api_err("rooms", format!("加载历史消息失败: {error}")))?;
    let (items, updates) = timeline.subscribe().await;
    drop(updates);
    let items: Vec<_> = items.into_iter().collect();
    let mut by_id: HashMap<_, _> = sdk_timeline::convert_snapshot(room, &items)
        .await
        .into_iter()
        .map(|message| (message.id.clone(), message))
        .collect();
    let missing: Vec<OwnedEventId> = candidates
        .iter()
        .map(|(id, _)| id)
        .filter(|id| !by_id.contains_key(id.as_str()))
        .cloned()
        .collect();
    let fetched = stream::iter(missing)
        .map(|id| async move { sdk_timeline::load_focused_message(room, id).await })
        .buffer_unordered(8)
        .collect::<Vec<_>>()
        .await;
    for result in fetched {
        if let Some(message) = result? {
            by_id.insert(message.id.clone(), message);
        }
    }
    // Never sort by timestamps: edits, clock skew and thread replies must not
    // change the server page's successor order or skip its nearest events.
    Ok(candidates
        .into_iter()
        .filter_map(|(id, _)| by_id.remove(id.as_str()))
        .collect())
}
