//! Preserve a room's entry read boundary and resolve its next visible message.

use std::collections::{HashMap, HashSet};

use flutter_rust_bridge::frb;
use matrix_sdk::{
    deserialized_responses::TimelineEvent,
    room::MessagesOptions,
    ruma::{
        events::{
            receipt::{Receipt, ReceiptThread, ReceiptType},
            AnySyncTimelineEvent,
        },
        EventId, OwnedEventId,
    },
    Room,
};
use matrix_sdk_base::linked_chunk::{ChunkContent, LinkedChunkId};
use matrix_sdk_ui::timeline::default_event_filter;

use super::{
    api_err, ensure_account_matches, get_client, get_room_by_id, run_bounded, sdk_timeline,
    ChatMessage,
};

type StoredReceipt = (OwnedEventId, Receipt);

#[frb]
#[derive(Clone, Debug)]
pub struct RoomUnreadState {
    /// Same notification-count / local-count fallback as the room list.
    pub unread_count: i32,
    pub read_event_id: Option<String>,
    /// Frozen remote tail for this visit; later sync events are not included.
    pub through_event_id: Option<String>,
    /// True only when receipt scopes/order justify a whole-room boundary.
    pub boundary_resolved: Option<bool>,
    /// Some means the complete, continuous entry interval was found locally.
    pub unread_event_ids: Option<Vec<String>>,
    pub unresolved_event_ids: Option<Vec<String>>,
}

/// This is a local read. Call it before enabling the viewed room's auto-reads.
#[frb]
pub async fn get_room_unread_state(
    account_user_id: String,
    room_id: String,
) -> Result<RoomUnreadState, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_owned()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    run_bounded(async move {
        let server_count = room.unread_notification_counts().notification_count;
        let unread_count = if server_count > 0 {
            server_count
        } else {
            room.num_unread_messages()
        }
        .min(i32::MAX as u64) as i32;
        let own_user = client.user_id().expect("authenticated client");
        let mut receipts = Vec::new();
        // Match the SDK's tie preferences: private over public within a scope,
        // unthreaded over main. Unlike its cached lookup, read all four slots.
        for thread in [ReceiptThread::Unthreaded, ReceiptThread::Main] {
            for kind in [ReceiptType::ReadPrivate, ReceiptType::Read] {
                receipts.push(
                    room.load_user_receipt(kind, &thread, own_user)
                        .await
                        .map_err(|error| api_err("rooms", format!("读取已读位置失败: {error}")))?,
                );
            }
        }
        let timeline = sdk_timeline::get_or_create_timeline(&client, &room).await?;
        let (items, updates) = timeline.subscribe().await;
        drop(updates);
        let positions: HashMap<String, usize> = items
            .iter()
            .enumerate()
            .filter_map(|(position, item)| {
                item.as_event()
                    .and_then(|event| event.event_id())
                    .map(|id| (id.to_string(), position))
            })
            .collect();
        let candidates: HashSet<_> = receipts
            .iter()
            .flatten()
            .map(|(id, _)| id.to_string())
            .collect();
        let unthreaded_ids: HashSet<_> = receipts
            .iter()
            .take(2)
            .flatten()
            .map(|(id, _)| id.to_string())
            .collect();
        let all_ordered = candidates.iter().all(|id| positions.contains_key(id));
        let mut slots = receipts.into_iter();
        let unthreaded = newer_receipt(slots.next().flatten(), slots.next().flatten(), &positions);
        let main = newer_receipt(slots.next().flatten(), slots.next().flatten(), &positions);
        let receipt = newer_receipt(unthreaded, main, &positions);
        let read_event_id = receipt.map(|(event_id, _)| event_id.to_string());
        let boundary_resolved = read_event_id.as_ref().is_some_and(|id| {
            unthreaded_ids.contains(id) && (candidates.len() == 1 || all_ordered)
        });
        let (room_cache, _handles) = room
            .event_cache()
            .await
            .map_err(|error| api_err("rooms", format!("读取未读快照失败: {error}")))?;
        let cached = room_cache
            .events()
            .await
            .map_err(|error| api_err("rooms", format!("读取未读快照失败: {error}")))?;
        let through_event_id = cached
            .iter()
            .rev()
            .find_map(|event| event.event_id().map(ToString::to_string));
        let local = if boundary_resolved {
            match (read_event_id.as_deref(), through_event_id.as_deref()) {
                (Some(read), Some(through)) => {
                    cached_entry_interval(&client, &room, read, through).await?
                }
                _ => None,
            }
        } else {
            None
        };
        let (unread_event_ids, unresolved_event_ids) = if let Some(events) = local {
            let known =
                sdk_timeline::convert_snapshot(&room, &items.iter().cloned().collect::<Vec<_>>())
                    .await;
            let (ids, unresolved) =
                classify_unread_events(&room, &events, &known, &account_user_id, &HashSet::new());
            (Some(ids), Some(unresolved))
        } else {
            (None, None)
        };
        Ok(RoomUnreadState {
            unread_count,
            read_event_id,
            through_event_id,
            boundary_resolved: Some(boundary_resolved),
            unread_event_ids,
            unresolved_event_ids,
        })
    })
    .await
}

/// Read only the latest bounded cache suffix. A gap is not continuity proof.
async fn cached_entry_interval(
    client: &matrix_sdk::Client,
    room: &Room,
    read: &str,
    through: &str,
) -> Result<Option<Vec<TimelineEvent>>, String> {
    if read == through {
        return Ok(Some(Vec::new()));
    }
    let state = client
        .event_cache_store()
        .lock()
        .await
        .map_err(|error| api_err("rooms", format!("读取未读缓存失败: {error}")))?;
    let store = state
        .as_clean()
        .ok_or_else(|| api_err("rooms", "未读缓存正在改变，请重试".to_owned()))?;
    let linked = LinkedChunkId::Room(room.room_id());
    let mut chunk = store
        .load_last_chunk(linked)
        .await
        .map_err(|error| api_err("rooms", format!("读取未读缓存失败: {error}")))?
        .0;
    let mut events = Vec::new();
    let mut found_tail = false;
    for _ in 0..8 {
        let Some(current) = chunk else {
            break;
        };
        let id = current.identifier;
        match current.content {
            ChunkContent::Gap(_) => break,
            ChunkContent::Items(items) => {
                for event in items.into_iter().rev() {
                    let event_id = event.event_id().map(ToString::to_string);
                    if !found_tail {
                        if event_id.as_deref() != Some(through) {
                            continue;
                        }
                        found_tail = true;
                    }
                    if event_id.as_deref() == Some(read) {
                        events.reverse();
                        return Ok(Some(events));
                    }
                    events.push(event);
                }
            }
        }
        chunk = store
            .load_previous_chunk(linked, id)
            .await
            .map_err(|error| api_err("rooms", format!("读取未读缓存失败: {error}")))?;
    }
    Ok(None)
}

fn classify_unread_events(
    room: &Room,
    events: &[TimelineEvent],
    messages: &[ChatMessage],
    account: &str,
    ignored: &HashSet<String>,
) -> (Vec<String>, Vec<String>) {
    let rules = room.clone_info().room_version_rules_or_default();
    let mut ids = Vec::new();
    let mut unresolved = Vec::new();
    for event in events {
        let Some(id) = event.event_id().map(ToString::to_string) else {
            continue;
        };
        let Ok(raw) = event.raw().deserialize() else {
            ids.push(id.clone());
            unresolved.push(id);
            continue;
        };
        if raw.sender().as_str() == account || ignored.contains(raw.sender().as_str()) {
            continue;
        }
        if event.kind.is_utd() {
            ids.push(id.clone());
            unresolved.push(id);
            continue;
        }
        if !default_event_filter(&raw, &rules) {
            continue;
        }
        let kind = event.raw().get_field::<String>("type").ok().flatten();
        if !matches!(
            kind.as_deref(),
            Some("m.room.message" | "m.sticker" | "m.poll.start" | "org.matrix.msc3381.poll.start")
        ) {
            continue;
        }
        if let Some(message) = messages.iter().find(|message| message.id == id) {
            if !message.is_me && !matches!(message.msg_type, super::MessageType::Event) {
                ids.push(id);
            }
        } else {
            ids.push(id.clone());
            unresolved.push(id);
        }
    }
    (ids, unresolved)
}

#[frb]
#[derive(Clone, Debug)]
pub struct UnreadPage {
    pub event_ids: Vec<String>,
    pub unresolved_event_ids: Vec<String>,
    pub next_batch: Option<String>,
    pub reached_end: bool,
}

/// Enumerate one finite room-ordered page against the saved entry receipt/tail.
/// Never reads the current receipt, which auto-read may already have advanced.
#[frb]
pub async fn get_unread_page(
    account_user_id: String,
    room_id: String,
    read_event_id: String,
    through_event_id: String,
    next_batch: Option<String>,
    ignored_user_ids: Vec<String>,
) -> Result<UnreadPage, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_owned()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    run_bounded(async move {
        if read_event_id == through_event_id {
            return Ok(UnreadPage {
                event_ids: Vec::new(),
                unresolved_event_ids: Vec::new(),
                next_batch: None,
                reached_end: true,
            });
        }
        let (mut events, next) = if let Some(token) = next_batch.as_deref() {
            let mut options = MessagesOptions::forward().from(Some(token));
            options.limit = 100u32.into();
            let page = room
                .messages(options)
                .await
                .map_err(|error| api_err("rooms", format!("读取未读消息失败: {error}")))?;
            (page.chunk, page.end)
        } else {
            let target = EventId::parse(&read_event_id)
                .map_err(|error| api_err("rooms", format!("无效的已读位置: {error}")))?;
            let context = room
                .event_with_context(&target, true, 100u32.into(), None)
                .await
                .map_err(|error| api_err("rooms", format!("读取未读边界失败: {error}")))?;
            (context.events_after, context.next_batch_token)
        };
        let end = events.iter().position(|event| {
            event
                .event_id()
                .is_some_and(|id| id.as_str() == through_event_id)
        });
        if let Some(index) = end {
            events.truncate(index + 1);
        }
        let reached_end = end.is_some();
        if !reached_end && next.is_none() {
            return Err(api_err(
                "rooms",
                "未核对到进入时的消息终点，请重试".to_owned(),
            ));
        }
        if !reached_end && next_batch.is_some() && next == next_batch {
            return Err(api_err("rooms", "未读消息分页没有前进，请重试".to_owned()));
        }
        let messages = super::history::convert_room_events(&room, &events).await?;
        let (event_ids, unresolved_event_ids) = classify_unread_events(
            &room,
            &events,
            &messages,
            &account_user_id,
            &ignored_user_ids.into_iter().collect(),
        );
        Ok(UnreadPage {
            event_ids,
            unresolved_event_ids,
            next_batch: if reached_end { None } else { next },
            reached_end,
        })
    })
    .await
}

/// Prefer timeline order when both targets are known, then receipt timestamps.
/// Missing timestamps leave the SDK-compatible preferred candidate unchanged.
fn newer_receipt(
    preferred: Option<StoredReceipt>,
    other: Option<StoredReceipt>,
    positions: &HashMap<String, usize>,
) -> Option<StoredReceipt> {
    match (preferred, other) {
        (Some(preferred), Some(other)) => {
            let ordering = match (
                positions.get(preferred.0.as_str()),
                positions.get(other.0.as_str()),
            ) {
                (Some(left), Some(right)) => Some(left.cmp(right)),
                _ => preferred
                    .1
                    .ts
                    .zip(other.1.ts)
                    .map(|(left, right)| left.cmp(&right)),
            };
            Some(if ordering == Some(std::cmp::Ordering::Less) {
                other
            } else {
                preferred
            })
        }
        (preferred, other) => preferred.or(other),
    }
}

/// Resolve the first renderable successor in server order, not timestamp order.
/// Raw room context avoids filtering a thread receipt down to its own thread,
/// and does not require the receipt itself (e.g. a reaction) to be renderable.
#[frb]
pub async fn get_unread_context(
    account_user_id: String,
    room_id: String,
    read_event_id: Option<String>,
    ignored_user_ids: Vec<String>,
) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_owned()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    run_bounded(async move {
        let ignored: HashSet<_> = ignored_user_ids.into_iter().collect();
        let rules = room.clone_info().room_version_rules_or_default();
        let (mut events, mut next) = if let Some(event_id) = read_event_id {
            let target = EventId::parse(event_id)
                .map_err(|error| api_err("rooms", format!("无效的已读位置: {error}")))?;
            let context = room
                .event_with_context(&target, true, 100u32.into(), None)
                .await
                .map_err(|error| api_err("rooms", format!("加载未读位置失败: {error}")))?;
            (context.events_after, context.next_batch_token)
        } else {
            // With no recorded receipt, the UI explicitly offers earlier
            // history rather than claiming an exact first-unread boundary.
            let mut options = MessagesOptions::forward();
            options.limit = 100u32.into();
            let page = room
                .messages(options)
                .await
                .map_err(|error| api_err("rooms", format!("加载最早消息失败: {error}")))?;
            (page.chunk, page.end)
        };
        let mut previous_token = None;
        loop {
            for event in &events {
                let raw = event
                    .raw()
                    .deserialize()
                    .map_err(|error| api_err("rooms", format!("解析未读消息失败: {error}")))?;
                if raw.sender().as_str() == account_user_id
                    || ignored.contains(raw.sender().as_str())
                    || !matches!(raw, AnySyncTimelineEvent::MessageLike(_))
                    || !default_event_filter(&raw, &rules)
                {
                    continue;
                }
                if let Some(id) = event.event_id() {
                    // Reuse the normal converter: calls, edits, redactions and
                    // other unsupported items must not become false targets.
                    if let Some(message) =
                        sdk_timeline::load_focused_message(&room, id.to_owned()).await?
                    {
                        return Ok(vec![message]);
                    }
                }
            }
            let Some(token) = next.take() else {
                return Ok(Vec::new());
            };
            if previous_token.as_ref() == Some(&token) {
                return Err(api_err(
                    "rooms",
                    "未读消息分页没有前进，请重试。".to_owned(),
                ));
            }
            let mut options = MessagesOptions::forward().from(Some(token.as_str()));
            options.limit = 100u32.into();
            let page = room
                .messages(options)
                .await
                .map_err(|error| api_err("rooms", format!("继续加载未读消息失败: {error}")))?;
            previous_token = Some(token);
            events = page.chunk;
            next = page.end;
        }
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::MilliSecondsSinceUnixEpoch;

    fn receipt(id: &str, ts: u64) -> StoredReceipt {
        (
            EventId::parse(id).unwrap(),
            Receipt::new(MilliSecondsSinceUnixEpoch(ts.try_into().unwrap())),
        )
    }

    #[test]
    fn newer_main_receipt_is_not_hidden_by_old_unthreaded_receipt() {
        let result = newer_receipt(
            Some(receipt("$old", 1)),
            Some(receipt("$new", 2)),
            &HashMap::new(),
        );
        assert_eq!(result.unwrap().0.as_str(), "$new");
    }

    #[test]
    fn timeline_position_wins_over_clock_skew() {
        let positions = HashMap::from([("$old".to_owned(), 0), ("$new".to_owned(), 1)]);
        let result = newer_receipt(
            Some(receipt("$old", 200)),
            Some(receipt("$new", 100)),
            &positions,
        );
        assert_eq!(result.unwrap().0.as_str(), "$new");
    }

    #[test]
    fn missing_timestamps_keep_the_preferred_scope() {
        let mut preferred = receipt("$preferred", 1);
        preferred.1.ts = None;
        let result = newer_receipt(Some(preferred), Some(receipt("$other", 2)), &HashMap::new());
        assert_eq!(result.unwrap().0.as_str(), "$preferred");
    }
}
