use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::Duration,
};

use futures_util::{stream, StreamExt};
use matrix_sdk::{
    event_cache::EventsOrigin,
    ruma::{
        api::client::receipt::create_receipt::v3::ReceiptType,
        events::{
            receipt::{ReceiptThread, ReceiptType as EventReceiptType},
            room::message::MessageType as RumaMessageType,
            AnySyncStateEvent, AnySyncTimelineEvent,
        },
    },
    Client, Room,
};
use matrix_sdk_ui::timeline::{
    EventTimelineItem, MembershipChange, MsgLikeKind, Profile, ReactionStatus, Timeline,
    TimelineBuilder, TimelineDetails, TimelineEventFocusThreadMode, TimelineFocus, TimelineItem,
    TimelineItemContent, TimelineReadReceiptTracking,
};
use once_cell::sync::Lazy;
use tokio::sync::Mutex;

use super::{
    api_err, image_info_dimensions, media_caption_parts, mentions_parts, sticker_info_dimensions,
    text_message_parts, uint_to_i32, unable_to_decrypt_message, ChatMessage, MessageReader,
    MessageType, PollAnswerInfo, PollAnswerResult, PollInfo, Reaction,
};

static REACTION_LOCKS: Lazy<Mutex<HashMap<String, Arc<Mutex<()>>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

static TIMELINES: Lazy<Mutex<HashMap<String, Arc<Timeline>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn timeline_key(client: &Client, room: &Room) -> Result<String, String> {
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("rooms", "No active user".to_string()))?;
    Ok(format!("{}\n{}", user_id, room.room_id()))
}

/// Drop the timelines of ONE account (key prefix `{user_id}\n`), leaving
/// the other accounts' timelines intact (a removed account's cache must
/// not tear down the timelines of the account the user is currently in).
pub(super) async fn clear_for_user(user_id: &str) {
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

async fn get_or_create_timeline(client: &Client, room: &Room) -> Result<Arc<Timeline>, String> {
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

async fn snapshot(timeline: &Timeline) -> Vec<Arc<TimelineItem>> {
    let (items, updates) = timeline.subscribe().await;
    drop(updates);
    items.into_iter().collect()
}

fn remote_event_count(items: &[Arc<TimelineItem>]) -> usize {
    items
        .iter()
        .filter_map(|item| item.as_event())
        .filter(|event| event.event_id().is_some())
        .count()
}

fn loaded_expected_event_count<I, S>(
    loaded_ids: I,
    expected_ids: &[&matrix_sdk::ruma::EventId],
) -> usize
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    loaded_expected_event_ids(loaded_ids, expected_ids).len()
}

fn loaded_expected_event_ids<I, S>(
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

fn pinned_events_ready(
    loaded_expected_events: usize,
    expected_events: usize,
    saw_network_update: bool,
) -> bool {
    loaded_expected_events == expected_events || (saw_network_update && loaded_expected_events > 0)
}

async fn ensure_initial_window(timeline: &Timeline, target: usize) -> Result<(), String> {
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

pub(super) async fn get_messages(client: &Client, room: &Room) -> Result<Vec<ChatMessage>, String> {
    const LIVE_WINDOW: usize = 100;

    let timeline = get_or_create_timeline(client, room).await?;
    ensure_initial_window(&timeline, LIVE_WINDOW).await?;

    let mut messages = convert_snapshot(room, &snapshot(&timeline).await).await;
    if messages.len() > LIVE_WINDOW {
        messages.drain(..messages.len() - LIVE_WINDOW);
    }
    Ok(messages)
}

/// Toggle through the SDK so pending reactions and remote reactions share
/// one source of truth. Wait for the local echo before accepting another click.
pub(super) async fn toggle_reaction(
    client: &Client,
    room: &Room,
    event_id: matrix_sdk::ruma::OwnedEventId,
    key: &str,
) -> Result<ChatMessage, String> {
    let room_key = timeline_key(client, room)?;
    let lock = REACTION_LOCKS
        .lock()
        .await
        .entry(room_key.clone())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone();
    let _guard = lock.lock().await;
    let live_timeline = get_or_create_timeline(client, room).await?;
    let timeline = if live_timeline.item_by_event_id(&event_id).await.is_some() {
        live_timeline
    } else {
        // Detached history and pinned messages may be outside the live window.
        // Keep their focused timeline alive so repeated clicks see local echoes.
        let focused_key = format!("{room_key}\n{event_id}");
        let cached = TIMELINES.lock().await.get(&focused_key).cloned();
        if let Some(timeline) = cached {
            timeline
        } else {
            let timeline = Arc::new(
                TimelineBuilder::new(room)
                    .with_focus(TimelineFocus::Event {
                        target: event_id.clone(),
                        num_context_events: 0,
                        thread_mode: TimelineEventFocusThreadMode::Automatic {
                            hide_threaded_events: false,
                        },
                    })
                    .build()
                    .await
                    .map_err(|error| api_err("rooms", format!("加载回应目标失败: {error}")))?,
            );
            TIMELINES.lock().await.insert(focused_key, timeline.clone());
            timeline
        }
    };
    let (_, mut updates) = timeline.subscribe().await;
    let added = timeline
        .toggle_reaction(
            &matrix_sdk_ui::timeline::TimelineEventItemId::EventId(event_id.clone()),
            key,
        )
        .await
        .map_err(|error| api_err("rooms", format!("Reaction failed: {error}")))?;
    let my_user_id = client.user_id().map(ToString::to_string);
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(item) = timeline.item_by_event_id(&event_id).await {
                let reactions = timeline_reactions(&item, my_user_id.as_deref());
                let has_reacted = reactions.iter().any(|reaction| {
                    reaction.key == key
                        && my_user_id
                            .as_ref()
                            .is_some_and(|user| reaction.senders.contains(user))
                });
                if has_reacted == added {
                    return convert_snapshot(room, &snapshot(&timeline).await)
                        .await
                        .into_iter()
                        .find(|message| message.id == event_id.as_str())
                        .ok_or_else(|| api_err("rooms", "回应目标消息不可用。".to_owned()));
                }
            }
            if updates.next().await.is_none() {
                return Err(api_err("rooms", "回应时间线已关闭。".to_owned()));
            }
        }
    })
    .await
    .map_err(|_| api_err("rooms", "回应状态更新超时，请刷新确认。".to_owned()))?
}

/// Send the read receipts for the room's latest timeline position. Not a
/// read-modify-write (the Timeline guards against moving either marker
/// backwards), so callers may run it outside the mutation queue.
pub(super) async fn send_read_receipts(client: &Client, room: &Room) -> Result<(), String> {
    let timeline = get_or_create_timeline(client, room).await?;
    // Receipts are background housekeeping: auto-reads fire on every
    // message refresh while a chat is open. The pagination and receipt
    // HTTP calls run under the client's request config (~30s x 3 retries
    // each), which on a dead network would hold the client lease for the
    // whole 90s outer bound — and concurrent auto-reads would amplify
    // that, blocking logout/account switch. Bound the whole send at 15s:
    // on a healthy network it finishes in well under a second (the
    // window is normally already loaded), and a skipped receipt never
    // corrupts the marker — the Timeline guards backward moves, and the
    // next refresh re-sends.
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        ensure_initial_window(&timeline, 100).await?;
        mark_as_read(&timeline, room).await
    })
    .await
    .map_err(|_| "发送已读回执超时。".to_string())?
}

/// Clear `m.marked_unread` for the room when the local store has it set.
/// The room is being viewed by the user, so any flag that has synced locally
/// is cleared regardless of which device set it — being on screen is the
/// "handled now" signal. The flag is only written when one is actually set:
/// auto-reads fire on every incoming message while the chat is open, so
/// unconditionally writing the flag (and triggering its sync echo +
/// RoomListChanged refresh) would be a per-message write amplification.
/// Failures propagate: an explicit read action must not report success while
/// the server flag survives; the auto path merely logs at its caller.
/// Returns whether a clear was actually issued.
pub(super) async fn clear_marked_unread_if_set(room: &Room) -> Result<bool, String> {
    let raw = room
        .account_data_static::<matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent>()
        .await
        .map_err(|error| format!("读取未读标记失败: {error}"))?;
    let marked_unread = match raw {
        Some(raw) => {
            raw.deserialize()
                .map_err(|error| format!("解析未读标记失败: {error}"))?
                .content
                .unread
        }
        // No `m.marked_unread` account-data event: the flag is not set.
        None => false,
    };
    if marked_unread {
        clear_marked_unread(room).await?;
        Ok(true)
    } else {
        Ok(false)
    }
}

/// Fallback read of the pinned list from the local state store, used when
/// the server read fails or times out. The stored list may lag the server
/// (e.g. our own latest toggle has not echoed yet), but a stale list beats
/// failing the whole page; the pinned page re-reads after every sync echo.
async fn pinned_ids_from_store(room: &Room) -> Result<Vec<matrix_sdk::ruma::OwnedEventId>, String> {
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

pub(super) async fn get_pinned_messages(room: &Room) -> Result<Vec<ChatMessage>, String> {
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
                super::app_log(
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

    let (room_event_cache, _event_cache_drop_handles) = room
        .event_cache()
        .await
        .map_err(|error| api_err("pinned", format!("加载置顶消息失败: {error}")))?;
    let (events, mut updates) = room_event_cache
        .subscribe_to_pinned_events()
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
                super::app_log("warn", "pinned", format!("加载置顶消息失败: {error}"));
            }
            Err(_) => {
                super::app_log("warn", "pinned", "构建置顶时间线超时。".to_owned());
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
            super::app_log(
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
                super::app_log("warn", "pinned", format!("加载置顶事件失败: {error}"));
            }
        }
    }

    complete_pinned_messages(&pinned_ids, &by_id, &failed_ids, focused_error)
}

async fn load_focused_message(
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
fn ordered_pinned_messages(
    pinned_ids: &[matrix_sdk::ruma::OwnedEventId],
    by_id: &HashMap<String, ChatMessage>,
) -> Vec<ChatMessage> {
    pinned_ids
        .iter()
        .filter_map(|event_id| by_id.get(event_id.as_str()).cloned())
        .collect()
}

fn missing_pinned_event_ids(
    pinned_ids: &[matrix_sdk::ruma::OwnedEventId],
    by_id: &HashMap<String, ChatMessage>,
) -> Vec<matrix_sdk::ruma::OwnedEventId> {
    pinned_ids
        .iter()
        .filter(|event_id| !by_id.contains_key(event_id.as_str()))
        .cloned()
        .collect()
}

fn complete_pinned_messages(
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

fn failed_pinned_message(event_id: &matrix_sdk::ruma::EventId) -> ChatMessage {
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

fn unavailable_pinned_message(event_id: &matrix_sdk::ruma::EventId) -> ChatMessage {
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

async fn mark_as_read(timeline: &Timeline, room: &Room) -> Result<(), String> {
    // The Timeline guards against moving either marker backwards.
    match timeline.mark_as_read(ReceiptType::Read).await {
        Ok(sent) => {
            if sent {
                super::app_log(
                    "info",
                    "receipts",
                    format!("Sent explicit read receipt for room {}", room.room_id()),
                );
            }
            Ok(())
        }
        Err(error) => {
            let error = error.to_string();
            super::app_log(
                "warn",
                "receipts",
                format!(
                    "Failed to send explicit read receipt for room {}: {error}",
                    room.room_id()
                ),
            );
            Err(format!("标记房间已读失败（已读回执）: {error}"))
        }
    }?;
    // The fully-read marker is best-effort: the read receipt above carries
    // the user-visible read state, and a failed marker update must not turn
    // a successful read into an error — the auto-read path fires on every
    // message refresh while the room is open, so an error here would repeat
    // on every refresh for a marker the user never sees. Log and move on.
    if let Err(error) = timeline.mark_as_read(ReceiptType::FullyRead).await {
        super::app_log(
            "warn",
            "receipts",
            format!(
                "Failed to update fully-read marker for room {}: {error}",
                room.room_id()
            ),
        );
    }
    Ok(())
}

/// Drop the explicit `m.marked_unread` flag for an explicit read action.
pub(super) async fn clear_marked_unread(room: &Room) -> Result<(), String> {
    use matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent;

    room.set_account_data(MarkedUnreadEventContent::new(false))
        .await
        .map(|_| ())
        .map_err(|error| format!("清除未读标记失败: {error}"))
}

pub(super) async fn get_messages_before(
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
        if hit_start {
            break;
        }
    }
    Ok(before[before.len().saturating_sub(limit)..].to_vec())
}

fn raw_event_position(items: &[Arc<TimelineItem>], event_id: &str) -> Option<usize> {
    items.iter().position(|item| {
        item.as_event()
            .and_then(EventTimelineItem::event_id)
            .is_some_and(|candidate| candidate.as_str() == event_id)
    })
}

async fn focused_messages_before(
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
    let before = convert_snapshot(room, &items[..position]).await;
    Ok(before[before.len().saturating_sub(limit)..].to_vec())
}

pub(super) async fn get_messages_around(
    room: &Room,
    event_id: &str,
    limit: usize,
) -> Result<Vec<ChatMessage>, String> {
    let target = matrix_sdk::ruma::EventId::parse(event_id)
        .map_err(|error| api_err("rooms", format!("无效的目标事件 ID: {error}")))?;
    let timeline = tokio::time::timeout(
        Duration::from_secs(25),
        TimelineBuilder::new(room)
            .with_focus(TimelineFocus::Event {
                target,
                num_context_events: limit.clamp(20, 100) as u16,
                thread_mode: TimelineEventFocusThreadMode::Automatic {
                    hide_threaded_events: false,
                },
            })
            .build(),
    )
    .await
    .map_err(|_| api_err("rooms", "加载目标消息超时，请重试。".to_owned()))?
    .map_err(|error| api_err("rooms", format!("加载目标消息失败: {error}")))?;
    let messages = convert_snapshot(room, &snapshot(&timeline).await).await;
    if !messages.iter().any(|message| message.id == event_id) {
        return Err(api_err("rooms", "目标消息不可用或已被删除。".to_owned()));
    }
    Ok(messages)
}

async fn convert_snapshot(room: &Room, items: &[Arc<TimelineItem>]) -> Vec<ChatMessage> {
    let my_user_id = room.client().user_id().map(ToString::to_string);
    let event_items: Vec<&EventTimelineItem> =
        items.iter().filter_map(|item| item.as_event()).collect();
    let event_positions: HashMap<String, usize> = event_items
        .iter()
        .enumerate()
        .filter_map(|(position, event)| {
            event
                .event_id()
                .map(|event_id| (event_id.to_string(), position))
        })
        .collect();
    let mut receipt_positions = HashMap::new();
    for (position, event) in event_items.iter().enumerate() {
        for user_id in event.read_receipts().keys() {
            if my_user_id.as_deref() != Some(user_id.as_str()) {
                record_latest_receipt_position(
                    &mut receipt_positions,
                    user_id.to_string(),
                    position,
                );
            }
        }
    }
    // `Room::members()` calls `sync_members()` when the lazy-loaded member
    // list is not complete, issuing a network /members request. This runs on
    // every message refresh, so in a large lazy-loaded room each incoming
    // message would amplify into another /members fetch while holding the
    // client lease. Read the store only: before the member list is synced,
    // this returns the lazy-loaded subset (recent participants), which still
    // covers the senders and receipts in view; the full list arrives via the
    // user-triggered member load (room management page) or the SDK's own
    // sync.
    let members = room
        .members_no_sync(matrix_sdk::RoomMemberships::JOIN)
        .await
        .unwrap_or_default();

    // The timeline includes implicit receipts (for example, sending an event
    // means that member read everything before it), which the state store does
    // not persist. Keep those positions, then merge in explicit receipts from
    // the store. The store is written synchronously while the sync response is
    // processed, so it also covers the race where the timeline's background
    // receipt task has not drained before this snapshot.
    //
    // A store receipt only supplies a position when its target is in this
    // snapshot. An unknown target can be either older or newer than the
    // window, so inventing a position would show a false receipt. Check both
    // unthreaded and main receipts: clients can write either one.
    let member_receipts = futures_util::future::join_all(
        members
            .iter()
            .filter_map(|member| {
                let user_id = member.user_id();
                if my_user_id.as_deref() == Some(user_id.as_str()) {
                    return None;
                }
                let user_id = user_id.to_owned();
                let room = room.clone();
                let event_positions = &event_positions;
                Some(async move {
                    let (unthreaded, main) = tokio::join!(
                        room.load_user_receipt(
                            EventReceiptType::Read,
                            ReceiptThread::Unthreaded,
                            &user_id,
                        ),
                        room.load_user_receipt(
                            EventReceiptType::Read,
                            ReceiptThread::Main,
                            &user_id,
                        ),
                    );
                    let unthreaded = unthreaded.ok().flatten();
                    let main = main.ok().flatten();
                    let position = newest_receipt_position(
                        [unthreaded.as_ref(), main.as_ref()]
                            .into_iter()
                            .flatten()
                            .map(|receipt| receipt.0.as_ref()),
                        event_positions,
                    )?;
                    Some((user_id.to_string(), position))
                })
            })
            .collect::<Vec<_>>(),
    )
    .await;
    for (user_id, position) in member_receipts.into_iter().flatten() {
        record_latest_receipt_position(&mut receipt_positions, user_id, position);
    }

    let mut profiles: HashMap<String, (String, Option<String>)> = members
        .iter()
        .map(|member| {
            (
                member.user_id().to_string(),
                (
                    member.name().to_string(),
                    member.avatar_url().map(ToString::to_string),
                ),
            )
        })
        .collect();
    for event in &event_items {
        if let TimelineDetails::Ready(Profile {
            display_name,
            avatar_url,
            ..
        }) = event.sender_profile()
        {
            profiles
                .entry(event.sender().to_string())
                .or_insert_with(|| {
                    (
                        display_name
                            .clone()
                            .unwrap_or_else(|| event.sender().localpart().to_owned()),
                        avatar_url.as_ref().map(ToString::to_string),
                    )
                });
        }
    }
    let base_total_members = room.active_members_count().min(i32::MAX as u64) as i32;

    let mut messages: Vec<ChatMessage> = event_items
        .iter()
        .filter_map(|event| timeline_item_to_message(event, my_user_id.as_deref()))
        .collect();
    for message in &mut messages {
        message.total_members = base_total_members;
        if !message.is_me {
            continue;
        }
        let Some(message_position) = event_positions.get(&message.id) else {
            continue;
        };
        let readers_at_message = reader_ids_for_position(&receipt_positions, *message_position);
        let readers: Vec<MessageReader> = readers_at_message
            .into_iter()
            .map(|user_id| {
                let (display_name, avatar_url) =
                    profiles.get(&user_id).cloned().unwrap_or_else(|| {
                        (
                            user_id
                                .split(':')
                                .next()
                                .unwrap_or(&user_id)
                                .trim_start_matches('@')
                                .to_owned(),
                            None,
                        )
                    });
                MessageReader {
                    user_id,
                    display_name,
                    avatar_url,
                }
            })
            .collect();
        message.total_members = message.total_members.max(readers.len() as i32 + 1);
        message.readers = readers;
    }
    messages
}

fn record_latest_receipt_position(
    receipt_positions: &mut HashMap<String, usize>,
    user_id: String,
    position: usize,
) {
    receipt_positions
        .entry(user_id)
        .and_modify(|current| *current = (*current).max(position))
        .or_insert(position);
}

fn newest_receipt_position<'a>(
    receipt_event_ids: impl IntoIterator<Item = &'a matrix_sdk::ruma::EventId>,
    event_positions: &HashMap<String, usize>,
) -> Option<usize> {
    receipt_event_ids
        .into_iter()
        .filter_map(|event_id| resolve_receipt_position(event_id, event_positions))
        .max()
}

fn resolve_receipt_position(
    receipt_event_id: &matrix_sdk::ruma::EventId,
    event_positions: &HashMap<String, usize>,
) -> Option<usize> {
    event_positions.get(receipt_event_id.as_str()).copied()
}

fn reader_ids_for_position(
    receipt_positions: &HashMap<String, usize>,
    message_position: usize,
) -> Vec<String> {
    let mut readers: Vec<String> = receipt_positions
        .iter()
        .filter(|(_, receipt_position)| **receipt_position >= message_position)
        .map(|(user_id, _)| user_id.clone())
        .collect();
    readers.sort();
    readers
}

fn timeline_item_to_message(
    item: &EventTimelineItem,
    my_user_id: Option<&str>,
) -> Option<ChatMessage> {
    let event_id = item.event_id()?.to_string();
    let sender_id = item.sender().to_string();
    let is_me = my_user_id == Some(sender_id.as_str());
    let sender_name = if is_me {
        "我".to_owned()
    } else if let TimelineDetails::Ready(profile) = item.sender_profile() {
        profile
            .display_name
            .clone()
            .unwrap_or_else(|| item.sender().localpart().to_owned())
    } else {
        item.sender().localpart().to_owned()
    };
    let timestamp = u64::from(item.timestamp().0).to_string();

    let mut message = match item.content() {
        TimelineItemContent::MsgLike(content) => {
            let in_reply_to = content
                .in_reply_to
                .as_ref()
                .map(|reply| reply.event_id.to_string());
            match &content.kind {
                MsgLikeKind::Message(message) => message_to_chat_message(
                    &event_id,
                    &sender_id,
                    &sender_name,
                    &timestamp,
                    is_me,
                    in_reply_to,
                    message,
                    item,
                )?,
                MsgLikeKind::Sticker(sticker) => {
                    let content = sticker.content();
                    let source = &content.source;
                    let image_url = match source {
                        matrix_sdk::ruma::events::sticker::StickerMediaSource::Plain(mxc) => {
                            Some(mxc.to_string())
                        }
                        _ => None,
                    };
                    let (image_width, image_height) = sticker_info_dimensions(&content.info);
                    ChatMessage {
                        id: event_id,
                        sender_id,
                        sender_name,
                        content: content.body.clone(),
                        formatted_body: None,
                        caption: None,
                        caption_formatted_body: None,
                        mentioned_user_ids: Vec::new(),
                        mentions_room: false,
                        timestamp,
                        is_me,
                        msg_type: MessageType::Sticker,
                        image_url,
                        media_source_json: serde_json::to_string(source).ok(),
                        image_width,
                        image_height,
                        filename: None,
                        file_size: None,
                        geo_uri: None,
                        poll: None,
                        in_reply_to,
                        is_edited: false,
                        edit_history: Vec::new(),
                        reactions: Vec::new(),
                        readers: Vec::new(),
                        total_members: 0,
                    }
                }
                MsgLikeKind::UnableToDecrypt(_) => {
                    unable_to_decrypt_message(event_id, sender_id, sender_name, timestamp, is_me)
                }
                MsgLikeKind::Poll(state) => poll_message(
                    event_id,
                    sender_id,
                    sender_name,
                    timestamp,
                    is_me,
                    in_reply_to,
                    state,
                    my_user_id,
                )?,
                _ => return None,
            }
        }
        TimelineItemContent::MembershipChange(change) => ChatMessage {
            id: event_id,
            sender_id,
            sender_name,
            content: membership_label(change)?,
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp,
            is_me: false,
            msg_type: MessageType::Event,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            filename: None,
            file_size: None,
            geo_uri: None,
            poll: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 0,
        },
        TimelineItemContent::OtherState(_) => ChatMessage {
            id: event_id,
            sender_id,
            sender_name,
            content: state_event_label(item)?,
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp,
            is_me: false,
            msg_type: MessageType::Event,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            filename: None,
            file_size: None,
            geo_uri: None,
            poll: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 0,
        },
        _ => return None,
    };
    message.reactions = timeline_reactions(item, my_user_id);
    Some(message)
}

#[allow(clippy::too_many_arguments)]
fn message_to_chat_message(
    event_id: &str,
    sender_id: &str,
    sender_name: &str,
    timestamp: &str,
    is_me: bool,
    in_reply_to: Option<String>,
    message: &matrix_sdk_ui::timeline::Message,
    item: &EventTimelineItem,
) -> Option<ChatMessage> {
    let mentions = message.mentions();
    let mut result = match message.msgtype() {
        RumaMessageType::Text(text) => {
            let (content, formatted_body, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                content,
                formatted_body,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Notice(text) => {
            let (content, formatted_body, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                content,
                formatted_body,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Emote(text) => {
            let (body, _, mentioned_user_ids, mentions_room) = text_message_parts(
                &text.body,
                text.formatted.as_ref(),
                mentions,
                in_reply_to.is_some(),
            );
            base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                format!("* {sender_name} {body}"),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Text,
                in_reply_to,
            )
        }
        RumaMessageType::Image(image) => {
            let image_url = match &image.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (image_width, image_height) = image_info_dimensions(image.info.as_deref());
            let (caption, caption_formatted_body) =
                media_caption_parts(image.formatted_caption(), image.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                image.filename().to_string(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Image,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&image.source).ok();
            result.image_width = image_width;
            result.image_height = image_height;
            result
        }
        RumaMessageType::Video(video) => {
            let image_url = match &video.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (image_width, image_height) = video
                .info
                .as_ref()
                .map(|info| (uint_to_i32(info.width), uint_to_i32(info.height)))
                .unwrap_or((None, None));
            let (caption, caption_formatted_body) =
                media_caption_parts(video.formatted_caption(), video.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                video.filename().to_string(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Video,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&video.source).ok();
            result.image_width = image_width;
            result.image_height = image_height;
            result
        }
        RumaMessageType::File(file) => {
            let filename = file.filename().to_string();
            let image_url = match &file.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (caption, caption_formatted_body) =
                media_caption_parts(file.formatted_caption(), file.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                filename.clone(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::File,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.filename = Some(filename);
            result.file_size = file.info.as_deref().and_then(|info| uint_to_i32(info.size));
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&file.source).ok();
            result
        }
        RumaMessageType::Audio(audio) => {
            let filename = audio.filename().to_string();
            let image_url = match &audio.source {
                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                _ => None,
            };
            let (caption, caption_formatted_body) =
                media_caption_parts(audio.formatted_caption(), audio.caption());
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                filename.clone(),
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::File,
                in_reply_to,
            );
            result.caption = caption;
            result.caption_formatted_body = caption_formatted_body;
            result.filename = Some(filename);
            result.file_size = audio
                .info
                .as_deref()
                .and_then(|info| uint_to_i32(info.size));
            result.image_url = image_url;
            result.media_source_json = serde_json::to_string(&audio.source).ok();
            result
        }
        RumaMessageType::Location(location) => {
            let geo_uri = location.geo_uri.clone();
            let body = location.body.clone();
            let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
            let mut result = base_message(
                event_id,
                sender_id,
                sender_name,
                timestamp,
                is_me,
                if body.trim().is_empty() {
                    geo_uri.clone()
                } else {
                    body
                },
                None,
                mentioned_user_ids,
                mentions_room,
                MessageType::Location,
                in_reply_to,
            );
            result.geo_uri = Some(geo_uri);
            result
        }
        _ => return None,
    };
    result.is_edited = message.is_edited();
    if result.is_edited {
        if let Some(original) = original_message_body(item) {
            result.edit_history = vec![original, result.content.clone()];
        }
    }
    Some(result)
}

#[allow(clippy::too_many_arguments)]
fn base_message(
    event_id: &str,
    sender_id: &str,
    sender_name: &str,
    timestamp: &str,
    is_me: bool,
    content: String,
    formatted_body: Option<String>,
    mentioned_user_ids: Vec<String>,
    mentions_room: bool,
    msg_type: MessageType,
    in_reply_to: Option<String>,
) -> ChatMessage {
    ChatMessage {
        id: event_id.to_owned(),
        sender_id: sender_id.to_owned(),
        sender_name: sender_name.to_owned(),
        content,
        formatted_body,
        caption: None,
        caption_formatted_body: None,
        mentioned_user_ids,
        mentions_room,
        timestamp: timestamp.to_owned(),
        is_me,
        msg_type,
        image_url: None,
        media_source_json: None,
        image_width: None,
        image_height: None,
        filename: None,
        file_size: None,
        geo_uri: None,
        poll: None,
        in_reply_to,
        is_edited: false,
        edit_history: Vec::new(),
        reactions: Vec::new(),
        readers: Vec::new(),
        total_members: 0,
    }
}

/// Build a [ChatMessage] from a poll timeline item. Polls use the unstable
/// `org.matrix.msc3381.*` event type, surfaced as [MsgLikeKind::Poll].
#[allow(clippy::too_many_arguments)]
fn poll_message(
    event_id: String,
    sender_id: String,
    sender_name: String,
    timestamp: String,
    is_me: bool,
    in_reply_to: Option<String>,
    state: &matrix_sdk_ui::timeline::PollState,
    my_user_id: Option<&str>,
) -> Option<ChatMessage> {
    let result = state.results();

    let answers = result
        .answers
        .into_iter()
        .map(|answer| PollAnswerInfo {
            id: answer.id,
            text: answer.text,
        })
        .collect::<Vec<_>>();
    if answers.is_empty() {
        return None;
    }

    let disclosed = result.kind == matrix_sdk::ruma::events::poll::start::PollKind::Disclosed;
    let ended = result.end_time.is_some();
    // Aggregate per-answer tallies and detect the current user's selections.
    let mut my_answer_ids = Vec::new();
    let mut tally: HashMap<&str, i32> = HashMap::new();
    let mut voters: HashMap<&str, ()> = HashMap::new();
    for (answer_id, voters_for_answer) in &result.votes {
        let count = i32::try_from(voters_for_answer.len()).unwrap_or(i32::MAX);
        tally.insert(answer_id.as_str(), count);
        for voter in voters_for_answer {
            voters.insert(voter.as_str(), ());
            if Some(voter.as_str()) == my_user_id {
                my_answer_ids.push(answer_id.clone());
            }
        }
    }

    let results = answers
        .iter()
        .map(|answer| PollAnswerResult {
            answer_id: answer.id.clone(),
            count: *tally.get(answer.id.as_str()).unwrap_or(&0),
            is_mine: my_answer_ids.iter().any(|id| id == &answer.id),
        })
        .collect::<Vec<_>>();

    let mut message = base_message(
        &event_id,
        &sender_id,
        &sender_name,
        &timestamp,
        is_me,
        result.question.clone(),
        None,
        Vec::new(),
        false,
        MessageType::Poll,
        in_reply_to,
    );
    message.poll = Some(PollInfo {
        question: result.question,
        answers,
        disclosed,
        max_selections: i32::try_from(result.max_selections).unwrap_or(i32::MAX),
        my_answer_ids,
        results,
        total_voters: i32::try_from(voters.len()).unwrap_or(i32::MAX),
        ended,
    });
    Some(message)
}

fn original_message_body(item: &EventTimelineItem) -> Option<String> {
    let event: AnySyncTimelineEvent = item.original_json()?.deserialize().ok()?;
    let AnySyncTimelineEvent::MessageLike(
        matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(message),
    ) = event
    else {
        return None;
    };
    Some(message.as_original()?.content.msgtype.body().to_owned())
}

fn timeline_reactions(item: &EventTimelineItem, my_user_id: Option<&str>) -> Vec<Reaction> {
    item.content()
        .reactions()
        .into_iter()
        .flat_map(|reactions| reactions.iter())
        .map(|(key, by_sender)| Reaction {
            key: key.clone(),
            senders: by_sender.keys().map(ToString::to_string).collect(),
            my_event_id: my_user_id
                .and_then(|user_id| by_sender.get(user_id))
                .and_then(|reaction| match &reaction.status {
                    ReactionStatus::RemoteToRemote(event_id) => Some(event_id.to_string()),
                    _ => None,
                }),
        })
        .collect()
}

fn membership_label(change: &matrix_sdk_ui::timeline::RoomMembershipChange) -> Option<String> {
    let name = change
        .display_name()
        .unwrap_or_else(|| change.user_id().localpart().to_owned());
    match change.change()? {
        MembershipChange::Joined | MembershipChange::InvitationAccepted => {
            Some(format!("{name} 加入了房间"))
        }
        MembershipChange::Left
        | MembershipChange::Kicked
        | MembershipChange::InvitationRejected
        | MembershipChange::InvitationRevoked => Some(format!("{name} 离开了房间")),
        MembershipChange::Banned | MembershipChange::KickedAndBanned => {
            Some(format!("{name} 被封禁"))
        }
        MembershipChange::Invited => Some(format!("{name} 收到了加入房间的邀请")),
        MembershipChange::Knocked => Some(format!("{name} 请求加入房间")),
        _ => None,
    }
}

fn state_event_label(item: &EventTimelineItem) -> Option<String> {
    let event: AnySyncTimelineEvent = item.original_json()?.deserialize().ok()?;
    let AnySyncTimelineEvent::State(state) = event else {
        return None;
    };
    match state {
        AnySyncStateEvent::RoomCreate(_) => Some("房间已创建".to_owned()),
        AnySyncStateEvent::RoomName(name) => name
            .as_original()
            .map(|event| format!("房间名称更改为: {}", event.content.name)),
        AnySyncStateEvent::RoomTopic(topic) => topic
            .as_original()
            .map(|event| format!("主题更改为: {}", event.content.topic)),
        AnySyncStateEvent::RoomAvatar(_) => Some("房间头像已更改".to_owned()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        complete_pinned_messages, loaded_expected_event_count, missing_pinned_event_ids,
        newest_receipt_position, ordered_pinned_messages, pinned_events_ready,
        reader_ids_for_position, record_latest_receipt_position, resolve_receipt_position,
    };
    use crate::api::matrix::uint_to_i32;
    use crate::api::matrix::{ChatMessage, MessageType};
    use std::collections::{HashMap, HashSet};

    #[tokio::test(flavor = "multi_thread")]
    async fn reaction_toggle_updates_count_and_cancels_before_sync() {
        use matrix_sdk::{
            ruma::{event_id, room_id, user_id},
            test_utils::mocks::MatrixMockServer,
        };
        use matrix_sdk_test::{event_factory::EventFactory, JoinedRoomBuilder};

        let server = MatrixMockServer::new().await;
        let client = server.client_builder().build().await;
        client.event_cache().subscribe().unwrap();
        let room_id = room_id!("!reaction:localhost");
        let event_id = event_id!("$message:localhost");
        let other_user = user_id!("@bob:localhost");
        let factory = EventFactory::new().room(room_id).sender(other_user);
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(room_id)
                    .add_timeline_event(factory.text_msg("hello").event_id(event_id))
                    .add_timeline_event(
                        factory
                            .reaction(event_id, "👍")
                            .event_id(event_id!("$bob:localhost")),
                    ),
            )
            .await;
        let room = client.get_room(room_id).unwrap();
        server.mock_room_state_encryption().plain().mount().await;
        server
            .mock_room_send()
            .ok(event_id!("$sent:localhost"))
            .mount()
            .await;
        // Pause sending: the second click must cancel a local reaction even
        // though it has no server event ID yet.
        room.send_queue().set_enabled(false);
        let message = super::toggle_reaction(&client, &room, event_id.to_owned(), "👍")
            .await
            .unwrap();
        assert_eq!(message.reactions[0].senders.len(), 2);
        assert!(message.reactions[0]
            .senders
            .contains(&client.user_id().unwrap().to_string()));
        assert!(message.reactions[0].my_event_id.is_none());

        let message = super::toggle_reaction(&client, &room, event_id.to_owned(), "👍")
            .await
            .unwrap();
        assert_eq!(message.reactions[0].senders, [other_user.to_string()]);
        let message = super::toggle_reaction(&client, &room, event_id.to_owned(), "🎉")
            .await
            .unwrap();
        assert_eq!(message.reactions.len(), 2);
        let message = super::toggle_reaction(&client, &room, event_id.to_owned(), "🎉")
            .await
            .unwrap();
        assert_eq!(message.reactions.len(), 1);
        super::clear_for_user(client.user_id().unwrap().as_str()).await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn reaction_toggle_redacts_synced_own_reaction_without_sending_a_duplicate() {
        use matrix_sdk::{
            ruma::{event_id, room_id, user_id},
            test_utils::mocks::MatrixMockServer,
        };
        use matrix_sdk_test::{event_factory::EventFactory, JoinedRoomBuilder};

        let server = MatrixMockServer::new().await;
        let client = server.client_builder().build().await;
        client.event_cache().subscribe().unwrap();
        let room_id = room_id!("!synced-reaction:localhost");
        let event_id = event_id!("$message:localhost");
        let factory = EventFactory::new()
            .room(room_id)
            .sender(user_id!("@bob:localhost"));
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(room_id)
                    .add_timeline_event(factory.text_msg("hello").event_id(event_id))
                    .add_timeline_event(factory.reaction(event_id, "👍"))
                    .add_timeline_event(
                        factory
                            .reaction(event_id, "👍")
                            .sender(client.user_id().unwrap())
                            .event_id(event_id!("$mine:localhost")),
                    ),
            )
            .await;
        let room = client.get_room(room_id).unwrap();
        server
            .mock_room_redact()
            .ok(event_id!("$redaction:localhost"))
            .expect(1)
            .mount()
            .await;
        server
            .mock_room_send()
            .ok(event_id!("$duplicate:localhost"))
            .expect(0)
            .mount()
            .await;

        let message = super::toggle_reaction(&client, &room, event_id.to_owned(), "👍")
            .await
            .unwrap();
        assert_eq!(message.reactions[0].senders, ["@bob:localhost"]);
        assert!(message.reactions[0].my_event_id.is_none());
        server.verify_and_reset().await;
        super::clear_for_user(client.user_id().unwrap().as_str()).await;
    }

    fn message(id: &str) -> ChatMessage {
        ChatMessage {
            id: id.to_owned(),
            sender_id: "@alice:example.org".to_owned(),
            sender_name: "Alice".to_owned(),
            content: id.to_owned(),
            formatted_body: None,
            caption: None,
            caption_formatted_body: None,
            mentioned_user_ids: Vec::new(),
            mentions_room: false,
            timestamp: "0".to_owned(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
            media_source_json: None,
            image_width: None,
            image_height: None,
            filename: None,
            file_size: None,
            geo_uri: None,
            poll: None,
            in_reply_to: None,
            is_edited: false,
            edit_history: Vec::new(),
            reactions: Vec::new(),
            readers: Vec::new(),
            total_members: 2,
        }
    }

    #[test]
    fn counts_only_expected_loaded_events() {
        use matrix_sdk::ruma::EventId;

        let first = EventId::parse("$first:example.org").unwrap();
        let missing = EventId::parse("$missing:example.org").unwrap();
        let expected = [first.as_ref(), missing.as_ref()];

        assert_eq!(
            loaded_expected_event_count([first.as_str(), "$other"].into_iter(), &expected),
            1
        );
        assert_eq!(
            loaded_expected_event_count(std::iter::empty::<&str>(), &expected),
            0
        );
    }

    #[test]
    fn complete_cache_is_ready_without_a_network_update() {
        assert!(pinned_events_ready(2, 2, false));
    }

    #[test]
    fn partial_cache_waits_for_a_network_update() {
        assert!(!pinned_events_ready(1, 2, false));
        assert!(pinned_events_ready(1, 2, true));
    }

    #[test]
    fn partial_cache_is_not_ready_before_network_completion() {
        assert!(!pinned_events_ready(1, 2, false));
    }

    #[test]
    fn empty_network_result_is_not_ready() {
        assert!(!pinned_events_ready(0, 2, true));
    }

    #[test]
    fn supplements_a_bounded_pinned_cache_and_preserves_state_order() {
        use matrix_sdk::ruma::EventId;

        let pinned_ids = (0..130)
            .map(|index| EventId::parse(format!("$pin-{index}:example.org")).unwrap())
            .collect::<Vec<_>>();
        let bounded_cache = pinned_ids
            .iter()
            .skip(2)
            .map(|event_id| (event_id.to_string(), message(event_id.as_str())))
            .collect::<HashMap<_, _>>();

        assert_eq!(
            missing_pinned_event_ids(&pinned_ids, &bounded_cache)
                .iter()
                .map(|event_id| event_id.as_str())
                .collect::<Vec<_>>(),
            ["$pin-0:example.org", "$pin-1:example.org"]
        );

        let all_messages = pinned_ids
            .iter()
            .map(|event_id| (event_id.to_string(), message(event_id.as_str())))
            .collect::<HashMap<_, _>>();
        let ordered = ordered_pinned_messages(&pinned_ids, &all_messages);
        assert_eq!(ordered.len(), 130);
        assert_eq!(ordered.first().unwrap().id, "$pin-0:example.org");
        assert_eq!(ordered.last().unwrap().id, "$pin-129:example.org");
    }

    #[test]
    fn partial_pinned_results_keep_available_messages_and_add_a_placeholder() {
        use matrix_sdk::ruma::EventId;

        let first = EventId::parse("$first:example.org").unwrap();
        let second = EventId::parse("$second:example.org").unwrap();
        let pinned_ids = vec![first.clone(), second];
        let partial = HashMap::from([(first.to_string(), message(first.as_str()))]);

        let messages = complete_pinned_messages(
            &pinned_ids,
            &partial,
            &HashSet::new(),
            Some("event unavailable".to_owned()),
        )
        .unwrap();

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].id, "$first:example.org");
        assert_eq!(messages[1].id, "$second:example.org");
        assert!(matches!(messages[1].msg_type, MessageType::Event));
        assert!(messages[1].content.contains("不可用"));
    }

    #[test]
    fn partially_failed_pinned_results_distinguish_transport_failures() {
        use matrix_sdk::ruma::EventId;

        let first = EventId::parse("$first:example.org").unwrap();
        let second = EventId::parse("$second:example.org").unwrap();
        let pinned_ids = vec![first.clone(), second.clone()];
        let partial = HashMap::from([(first.to_string(), message(first.as_str()))]);

        let messages = complete_pinned_messages(
            &pinned_ids,
            &partial,
            &HashSet::from([second.to_string()]),
            Some("request failed".to_owned()),
        )
        .unwrap();

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].id, "$first:example.org");
        assert!(messages[0].content.contains("$first"));
        // A transport failure must not masquerade as "deleted".
        assert!(messages[1].content.contains("加载失败"));
        assert!(!messages[1].content.contains("已删除"));
    }

    #[test]
    fn wholly_unavailable_pinned_results_without_errors_are_replaced_by_placeholders() {
        use matrix_sdk::ruma::EventId;

        let pinned_ids = vec![EventId::parse("$missing:example.org").unwrap()];
        let messages =
            complete_pinned_messages(&pinned_ids, &HashMap::new(), &HashSet::new(), None).unwrap();

        // Every event was confirmed unavailable (no fetch errors): a
        // redacted message stays pinned, and the page must not fail
        // entirely, so placeholders stand in for the missing events.
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].id, "$missing:example.org");
        assert!(matches!(messages[0].msg_type, MessageType::Event));
        assert_eq!(messages[0].content, "此置顶消息不可用或已被删除");
    }

    #[test]
    fn wholly_failed_pinned_fetch_surfaces_the_load_error() {
        use matrix_sdk::ruma::EventId;

        let pinned_ids = vec![EventId::parse("$missing:example.org").unwrap()];
        let error = complete_pinned_messages(
            &pinned_ids,
            &HashMap::new(),
            &HashSet::new(),
            Some("request failed".to_owned()),
        )
        .unwrap_err();

        // Every per-event fetch failed: that is a transport-level failure
        // (unreachable server, timeout), not "the message is deleted", so it
        // must surface as an error with a retry path.
        assert!(error.contains("request failed"));
    }

    #[test]
    fn receipt_positions_apply_cumulatively_without_timestamps() {
        let receipts = HashMap::from([
            ("@bob:example.org".to_owned(), 4),
            ("@carol:example.org".to_owned(), 2),
        ]);

        assert_eq!(reader_ids_for_position(&receipts, 3), ["@bob:example.org"]);
        assert_eq!(
            reader_ids_for_position(&receipts, 2),
            ["@bob:example.org", "@carol:example.org"]
        );
    }

    #[test]
    fn implicit_receipt_is_not_replaced_by_older_explicit_receipt() {
        let mut positions = HashMap::new();

        record_latest_receipt_position(&mut positions, "@bob:example.org".to_owned(), 4);
        record_latest_receipt_position(&mut positions, "@bob:example.org".to_owned(), 1);

        assert_eq!(positions["@bob:example.org"], 4);
        assert_eq!(reader_ids_for_position(&positions, 3), ["@bob:example.org"]);
    }

    #[test]
    fn store_receipts_use_the_newest_known_main_timeline_position() {
        use matrix_sdk::ruma::EventId;

        let positions = HashMap::from([
            ("$a:example.org".to_owned(), 0),
            ("$unthreaded:example.org".to_owned(), 1),
            ("$main:example.org".to_owned(), 4),
        ]);
        let unthreaded = EventId::parse("$unthreaded:example.org").unwrap();
        let main = EventId::parse("$main:example.org").unwrap();

        assert_eq!(
            newest_receipt_position([unthreaded.as_ref(), main.as_ref()], &positions),
            Some(4)
        );
    }

    #[test]
    fn unknown_receipt_target_does_not_mark_the_oldest_message_as_read() {
        use matrix_sdk::ruma::EventId;

        let positions = HashMap::from([("$a:example.org".to_owned(), 0)]);

        assert_eq!(
            resolve_receipt_position(
                EventId::parse("$outside:example.org").unwrap().as_ref(),
                &positions
            ),
            None
        );
    }

    #[test]
    fn unknown_unthreaded_receipt_does_not_hide_a_known_main_receipt() {
        use matrix_sdk::ruma::EventId;

        let positions = HashMap::from([("$main:example.org".to_owned(), 4)]);
        let unthreaded = EventId::parse("$outside:example.org").unwrap();
        let main = EventId::parse("$main:example.org").unwrap();

        assert_eq!(
            newest_receipt_position([unthreaded.as_ref(), main.as_ref()], &positions),
            Some(4)
        );
    }

    #[test]
    fn file_sizes_cross_the_bridge_as_saturating_i32() {
        assert_eq!(
            uint_to_i32(matrix_sdk::ruma::UInt::new(64 * 1024 * 1024)),
            Some(64 * 1024 * 1024)
        );
        assert_eq!(
            uint_to_i32(matrix_sdk::ruma::UInt::new(i32::MAX as u64 + 1)),
            Some(i32::MAX)
        );
        assert_eq!(uint_to_i32(None), None);
    }
}
