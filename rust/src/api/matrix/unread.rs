//! Preserve a room's entry read boundary and resolve its next visible message.

use std::collections::{HashMap, HashSet};

use flutter_rust_bridge::frb;
use matrix_sdk::{
    deserialized_responses::TimelineEvent,
    room::MessagesOptions,
    ruma::{
        events::{
            fully_read::FullyReadEventContent,
            receipt::{Receipt, ReceiptThread, ReceiptType},
            room::message::MessageType as RumaMessageType,
            AnySyncMessageLikeEvent, AnySyncTimelineEvent,
        },
        EventId, OwnedEventId,
    },
    Room,
};
use matrix_sdk_base::linked_chunk::{ChunkContent, LinkedChunkId};
use matrix_sdk_ui::timeline::default_event_filter;
use once_cell::sync::Lazy;
use tokio::sync::Mutex;

use super::{
    api_err, ensure_account_matches, get_client, get_room_by_id, run_bounded, sdk_timeline,
    ChatMessage,
};

type StoredReceipt = (OwnedEventId, Receipt);

const MAX_LOCAL_CACHE_CHUNKS: usize = 64;
const MAX_ENTRY_BOUNDARY_SNAPSHOTS: usize = 64;

#[derive(Clone, Debug)]
struct EntryBoundarySnapshot {
    primary_read_event_id: Option<String>,
    candidate_ids: HashSet<String>,
    whole_room_ids: HashSet<String>,
}

#[derive(Clone, Debug)]
struct LocalEntryInterval {
    boundary_event_id: String,
    whole_room_boundary: bool,
    events: Vec<TimelineEvent>,
}

type EntryBoundaryKey = (String, String, String);
type EntryBoundaryMap = HashMap<EntryBoundaryKey, EntryBoundarySnapshot>;

static ENTRY_BOUNDARIES: Lazy<Mutex<EntryBoundaryMap>> = Lazy::new(|| Mutex::new(HashMap::new()));

pub(super) async fn clear_for_user(user_id: &str) {
    ENTRY_BOUNDARIES
        .lock()
        .await
        .retain(|(account, _, _), _| account != user_id);
}

async fn save_entry_boundaries(
    account_user_id: &str,
    room_id: &str,
    through_event_id: &str,
    snapshot: EntryBoundarySnapshot,
) {
    let mut store = ENTRY_BOUNDARIES.lock().await;
    if store.len() >= MAX_ENTRY_BOUNDARY_SNAPSHOTS {
        store.clear();
    }
    store.insert(
        (
            account_user_id.to_owned(),
            room_id.to_owned(),
            through_event_id.to_owned(),
        ),
        snapshot,
    );
}

async fn load_matching_entry_boundaries(
    account_user_id: &str,
    room_id: &str,
    read_event_id: &str,
    through_event_id: &str,
) -> (HashSet<String>, HashSet<String>) {
    let mut candidate_ids = HashSet::from([read_event_id.to_owned()]);
    let mut whole_room_ids = HashSet::new();
    let store = ENTRY_BOUNDARIES.lock().await;
    if let Some(snapshot) = store.get(&(
        account_user_id.to_owned(),
        room_id.to_owned(),
        through_event_id.to_owned(),
    )) {
        // Only merge frozen entry candidates when Dart is still scanning the
        // same entry boundary, never when a resumed visit extends an older
        // pre-auto-read starting point past a newly written auto-read receipt.
        if snapshot.primary_read_event_id.as_deref() == Some(read_event_id) {
            candidate_ids.extend(snapshot.candidate_ids.iter().cloned());
            whole_room_ids.extend(snapshot.whole_room_ids.iter().cloned());
        }
    }
    (candidate_ids, whole_room_ids)
}

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
        let mut unread_count = if server_count > 0 {
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
        let latest_active = room
            .read_receipts()
            .latest_active
            .map(|receipt| receipt.event_id.to_string());
        let fully_read = room
            .account_data_static::<FullyReadEventContent>()
            .await
            .ok()
            .flatten()
            .and_then(|raw| raw.deserialize().ok())
            .map(|event| event.content.event_id.to_string());

        let timeline = sdk_timeline::get_or_create_timeline(&client, &room).await?;
        let (items, updates) = timeline.subscribe().await;
        drop(updates);
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

        // Build chronological positions from raw cached events so non-rendered
        // receipt targets (reactions, edits, state events) are also ordered.
        let mut positions: HashMap<String, usize> = cached
            .iter()
            .enumerate()
            .filter_map(|(position, event)| event.event_id().map(|id| (id.to_string(), position)))
            .collect();
        if positions.is_empty() {
            positions = items
                .iter()
                .enumerate()
                .filter_map(|(position, item)| {
                    item.as_event()
                        .and_then(|event| event.event_id())
                        .map(|id| (id.to_string(), position))
                })
                .collect();
        }

        let mut all_boundaries: HashSet<String> = receipts
            .iter()
            .flatten()
            .map(|(id, _)| id.to_string())
            .collect();
        let mut whole_room_ids: HashSet<String> = receipts
            .iter()
            .take(2)
            .flatten()
            .map(|(id, _)| id.to_string())
            .collect();
        if let Some(id) = latest_active.as_ref() {
            all_boundaries.insert(id.clone());
        }
        if let Some(id) = fully_read.as_ref() {
            all_boundaries.insert(id.clone());
            whole_room_ids.insert(id.clone());
        }

        let mut slots = receipts.into_iter();
        let unthreaded = newer_receipt(slots.next().flatten(), slots.next().flatten(), &positions);
        let main = newer_receipt(slots.next().flatten(), slots.next().flatten(), &positions);
        let explicit = newer_receipt(unthreaded, main, &positions);
        let mut read_event_id = select_entry_boundary(
            explicit.map(|(event_id, _)| event_id.to_string()),
            latest_active.as_deref(),
            fully_read.as_deref(),
            &positions,
        );
        let all_ordered = all_boundaries.iter().all(|id| positions.contains_key(id));
        let mut boundary_resolved = read_event_id.as_ref().is_some_and(|id| {
            whole_room_ids.contains(id) && (all_boundaries.len() == 1 || all_ordered)
        });

        let local = if let Some(through) = through_event_id.as_deref() {
            cached_entry_interval_any_boundary(
                &client,
                &room,
                &all_boundaries,
                &whole_room_ids,
                through,
                &account_user_id,
            )
            .await?
        } else {
            None
        };

        let (unread_event_ids, unresolved_event_ids) = if let Some(interval) = local {
            read_event_id = Some(interval.boundary_event_id);
            boundary_resolved = interval.whole_room_boundary;
            let item_vec: Vec<_> = items.iter().cloned().collect();
            let timeline_ids = timeline_event_id_set(&item_vec);
            let known = sdk_timeline::convert_snapshot(&room, &item_vec).await;
            let (ids, unresolved) = classify_unread_events(
                &room,
                &interval.events,
                &known,
                &timeline_ids,
                &account_user_id,
                &HashSet::new(),
            );
            unread_count = reconcile_local_unread_count(unread_count, &ids, &unresolved);
            (Some(ids), Some(unresolved))
        } else {
            if read_event_id.is_none()
                && server_count == 0
                && unread_count > 0
                && !cached.is_empty()
            {
                let tail_start = tail_after_own_event(&cached, &account_user_id);
                let item_vec: Vec<_> = items.iter().cloned().collect();
                let timeline_ids = timeline_event_id_set(&item_vec);
                let known = sdk_timeline::convert_snapshot(&room, &item_vec).await;
                let (ids, unresolved) = classify_unread_events(
                    &room,
                    &cached[tail_start..],
                    &known,
                    &timeline_ids,
                    &account_user_id,
                    &HashSet::new(),
                );
                unread_count = reconcile_local_unread_count(unread_count, &ids, &unresolved);
            }
            (None, None)
        };

        if let Some(through) = through_event_id.as_deref() {
            if !all_boundaries.is_empty() {
                save_entry_boundaries(
                    &account_user_id,
                    &room_id,
                    through,
                    EntryBoundarySnapshot {
                        primary_read_event_id: read_event_id.clone(),
                        candidate_ids: all_boundaries,
                        whole_room_ids,
                    },
                )
                .await;
            }
        }

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

fn timeline_event_id_set(
    items: &[std::sync::Arc<matrix_sdk_ui::timeline::TimelineItem>],
) -> HashSet<String> {
    items
        .iter()
        .filter_map(|item| item.as_event().and_then(|event| event.event_id()))
        .map(ToString::to_string)
        .collect()
}

/// Prefer the latest known boundary in cached timeline order, without moving
/// backwards when an untimestamped marker (`latest_active` / `m.fully_read`)
/// cannot be proven newer than an explicit receipt outside the cache window.
fn select_entry_boundary(
    explicit: Option<String>,
    latest_active: Option<&str>,
    fully_read: Option<&str>,
    positions: &HashMap<String, usize>,
) -> Option<String> {
    let mut best = explicit;
    for candidate in [latest_active, fully_read].into_iter().flatten() {
        match (&best, positions.get(candidate)) {
            (None, _) => best = Some(candidate.to_owned()),
            (Some(current), Some(&cand_pos)) => {
                if positions
                    .get(current.as_str())
                    .is_none_or(|&curr_pos| cand_pos > curr_pos)
                {
                    best = Some(candidate.to_owned());
                }
            }
            (Some(_), None) => {}
        }
    }
    best
}

/// Whether `event` is an implicit read receipt sent by `account`.
/// Excludes room state events (such as global profile/avatar `m.room.member`
/// broadcasts) which do not imply the user read the room's messages.
fn is_own_implicit_read_event(event: &TimelineEvent, account: &str) -> bool {
    let is_own_sender = event
        .raw()
        .get_field::<String>("sender")
        .ok()
        .flatten()
        .as_deref()
        == Some(account);
    if !is_own_sender {
        return false;
    }
    event
        .raw()
        .get_field::<serde_json::Value>("state_key")
        .ok()
        .flatten()
        .is_none()
}

/// Read only the latest bounded, gap-free cache suffix ending at `through`.
/// Stops at the newest matching entry boundary or own message-like event.
async fn cached_entry_interval_any_boundary(
    client: &matrix_sdk::Client,
    room: &Room,
    boundaries: &HashSet<String>,
    whole_room_ids: &HashSet<String>,
    through: &str,
    account: &str,
) -> Result<Option<LocalEntryInterval>, String> {
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
    for _ in 0..MAX_LOCAL_CACHE_CHUNKS {
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
                    let is_own = is_own_implicit_read_event(&event, account);
                    let matched_boundary = event_id
                        .as_deref()
                        .is_some_and(|eid| boundaries.contains(eid));
                    if is_own || matched_boundary {
                        if let Some(boundary_id) = event_id {
                            let whole_room_boundary =
                                is_own || whole_room_ids.contains(&boundary_id);
                            events.reverse();
                            return Ok(Some(LocalEntryInterval {
                                boundary_event_id: boundary_id,
                                whole_room_boundary,
                                events,
                            }));
                        }
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

/// Clamp reported unread count against a complete, fully-resolved local event slice.
/// Prevents stale server counts or non-message encrypted events (e.g. reactions/edits)
/// from keeping `unread_count > 0` when zero renderable messages remain, without
/// overriding `0` when an implicit own-message receipt already marked the room read.
fn reconcile_local_unread_count(reported: i32, ids: &[String], unresolved: &[String]) -> i32 {
    if unresolved.is_empty() {
        let exact = ids.len().min(i32::MAX as usize) as i32;
        reported.min(exact)
    } else {
        reported
    }
}

fn tail_after_own_event(events: &[TimelineEvent], account: &str) -> usize {
    events
        .iter()
        .rposition(|event| is_own_implicit_read_event(event, account))
        .map_or(0, |index| index + 1)
}

/// Find the latest event index in `events` that establishes a read boundary
/// (either an explicit/frozen boundary ID or an own message-like event).
fn last_boundary_in_slice(
    events: &[TimelineEvent],
    boundaries: &HashSet<String>,
    whole_room_ids: &HashSet<String>,
    account: &str,
) -> Option<(usize, bool)> {
    events.iter().enumerate().rev().find_map(|(index, event)| {
        let is_own = is_own_implicit_read_event(event, account);
        let matched = event
            .event_id()
            .is_some_and(|id| boundaries.contains(id.as_str()));
        if is_own || matched {
            let whole_room = is_own
                || event
                    .event_id()
                    .is_some_and(|id| whole_room_ids.contains(id.as_str()));
            Some((index, whole_room))
        } else {
            None
        }
    })
}

fn redacted_targets_in_slice(events: &[TimelineEvent]) -> HashSet<String> {
    let mut targets = HashSet::new();
    for event in events {
        let kind = event.raw().get_field::<String>("type").ok().flatten();
        if kind.as_deref() != Some("m.room.redaction") {
            continue;
        }
        if let Some(target) = event.raw().get_field::<String>("redacts").ok().flatten() {
            targets.insert(target);
        }
        if let Some(target) = event
            .raw()
            .get_field::<serde_json::Value>("content")
            .ok()
            .flatten()
            .and_then(|content| {
                content
                    .get("redacts")
                    .and_then(|value| value.as_str())
                    .map(ToOwned::to_owned)
            })
        {
            targets.insert(target);
        }
    }
    targets
}

fn is_renderable_raw_unread_event(raw: &AnySyncTimelineEvent) -> bool {
    let AnySyncTimelineEvent::MessageLike(event) = raw else {
        return false;
    };
    if event.is_redacted() {
        return false;
    }
    match event {
        AnySyncMessageLikeEvent::RoomMessage(message) => {
            let Some(original) = message.as_original() else {
                return false;
            };
            matches!(
                original.content.msgtype,
                RumaMessageType::Text(_)
                    | RumaMessageType::Notice(_)
                    | RumaMessageType::Emote(_)
                    | RumaMessageType::Image(_)
                    | RumaMessageType::Video(_)
                    | RumaMessageType::File(_)
                    | RumaMessageType::Audio(_)
                    | RumaMessageType::Location(_)
            )
        }
        AnySyncMessageLikeEvent::Sticker(sticker) => sticker.as_original().is_some(),
        AnySyncMessageLikeEvent::UnstablePollStart(poll) => poll.as_original().is_some(),
        AnySyncMessageLikeEvent::PollStart(poll) => poll.as_original().is_some(),
        _ => false,
    }
}

fn classify_unread_events(
    room: &Room,
    events: &[TimelineEvent],
    messages: &[ChatMessage],
    timeline_event_ids: &HashSet<String>,
    account: &str,
    ignored: &HashSet<String>,
) -> (Vec<String>, Vec<String>) {
    let rules = room.clone_info().room_version_rules_or_default();
    let redacted_targets = redacted_targets_in_slice(events);
    let messages_by_id: HashMap<&str, &ChatMessage> = messages
        .iter()
        .map(|message| (message.id.as_str(), message))
        .collect();
    let mut ids = Vec::new();
    let mut unresolved = Vec::new();
    for event in events {
        let Some(id) = event.event_id().map(ToString::to_string) else {
            continue;
        };
        if redacted_targets.contains(&id) {
            continue;
        }
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
        if matches!(&raw, AnySyncTimelineEvent::MessageLike(ev) if ev.is_redacted()) {
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
        if let Some(message) = messages_by_id.get(id.as_str()) {
            if !message.is_me && !matches!(message.msg_type, super::MessageType::Event) {
                ids.push(id);
            }
        } else if timeline_event_ids.contains(&id) {
            // Live timeline already processed this event and excluded it (e.g.
            // redacted by a later event or unsupported); do not keep it stuck
            // in `unresolved`.
            continue;
        } else if is_renderable_raw_unread_event(&raw) {
            ids.push(id);
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
    /// True when a newer read boundary (e.g. own sent message) appeared in this
    /// page, so candidates from earlier pages must be discarded.
    pub reset_before: bool,
    /// Some(true) when this page proved a whole-room read boundary.
    pub boundary_resolved: Option<bool>,
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
                reset_before: false,
                boundary_resolved: None,
            });
        }
        let ignored: HashSet<String> = ignored_user_ids.into_iter().collect();
        let (boundaries, whole_room_ids) = load_matching_entry_boundaries(
            &account_user_id,
            &room_id,
            &read_event_id,
            &through_event_id,
        )
        .await;
        let timeline = sdk_timeline::get_or_create_timeline(&client, &room).await?;
        let (items, updates) = timeline.subscribe().await;
        drop(updates);
        let item_vec: Vec<_> = items.iter().cloned().collect();
        let timeline_ids = timeline_event_id_set(&item_vec);
        let known = sdk_timeline::convert_snapshot(&room, &item_vec).await;

        // Fast path: after refreshMessagesFromNetwork populates the local event
        // cache with ~100 messages, resolve the complete continuous interval
        // directly from local storage with zero extra network roundtrips.
        if next_batch.is_none() {
            if let Some(interval) = cached_entry_interval_any_boundary(
                &client,
                &room,
                &boundaries,
                &whole_room_ids,
                &through_event_id,
                &account_user_id,
            )
            .await?
            {
                let (event_ids, unresolved_event_ids) = classify_unread_events(
                    &room,
                    &interval.events,
                    &known,
                    &timeline_ids,
                    &account_user_id,
                    &ignored,
                );
                return Ok(UnreadPage {
                    event_ids,
                    unresolved_event_ids,
                    next_batch: None,
                    reached_end: true,
                    reset_before: false,
                    boundary_resolved: interval.whole_room_boundary.then_some(true),
                });
            }
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
        let mut reset_before = false;
        let mut boundary_resolved = None;
        if let Some((cut_index, whole_room)) =
            last_boundary_in_slice(&events, &boundaries, &whole_room_ids, &account_user_id)
        {
            events.drain(..=cut_index);
            reset_before = next_batch.is_some();
            if whole_room {
                boundary_resolved = Some(true);
            }
        }
        let (event_ids, unresolved_event_ids) = classify_unread_events(
            &room,
            &events,
            &known,
            &timeline_ids,
            &account_user_id,
            &ignored,
        );
        Ok(UnreadPage {
            event_ids,
            unresolved_event_ids,
            next_batch: if reached_end { None } else { next },
            reached_end,
            reset_before,
            boundary_resolved,
        })
    })
    .await
}

/// Prefer timeline order when targets are known in the recent event cache,
/// then receipt timestamps. Missing timestamps keep the preferred candidate
/// when neither target is in the cache, but a cached target wins over an
/// uncached one unless timestamps prove the uncached receipt is newer.
fn newer_receipt(
    preferred: Option<StoredReceipt>,
    other: Option<StoredReceipt>,
    positions: &HashMap<String, usize>,
) -> Option<StoredReceipt> {
    match (preferred, other) {
        (Some(preferred), Some(other)) => {
            let ts_ordering = preferred
                .1
                .ts
                .zip(other.1.ts)
                .map(|(left, right)| left.cmp(&right));
            let ordering = match (
                positions.get(preferred.0.as_str()),
                positions.get(other.0.as_str()),
            ) {
                (Some(left), Some(right)) => Some(left.cmp(right)),
                (None, Some(_)) => Some(if ts_ordering == Some(std::cmp::Ordering::Greater) {
                    std::cmp::Ordering::Greater
                } else {
                    std::cmp::Ordering::Less
                }),
                (Some(_), None) => Some(if ts_ordering == Some(std::cmp::Ordering::Less) {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Greater
                }),
                (None, None) => ts_ordering,
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
    use matrix_sdk::ruma::{serde::Raw, MilliSecondsSinceUnixEpoch};
    use serde_json::json;

    fn receipt(id: &str, ts: u64) -> StoredReceipt {
        (
            EventId::parse(id).unwrap(),
            Receipt::new(MilliSecondsSinceUnixEpoch(ts.try_into().unwrap())),
        )
    }

    fn make_text_event(sender: &str, id: &str) -> TimelineEvent {
        let raw: Raw<AnySyncTimelineEvent> = serde_json::from_value(json!({
            "type": "m.room.message",
            "event_id": id,
            "sender": sender,
            "origin_server_ts": 1,
            "content": { "msgtype": "m.text", "body": "hi" }
        }))
        .unwrap();
        TimelineEvent::from_plaintext(raw)
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
    fn cached_receipt_beats_uncached_receipt_when_timestamps_missing() {
        let mut preferred = receipt("$old_unthreaded", 1);
        preferred.1.ts = None;
        let mut other = receipt("$recent_main", 2);
        other.1.ts = None;
        let positions = HashMap::from([("$recent_main".to_owned(), 15)]);
        let result = newer_receipt(Some(preferred), Some(other), &positions);
        assert_eq!(result.unwrap().0.as_str(), "$recent_main");
    }

    #[test]
    fn missing_timestamps_keep_the_preferred_scope() {
        let mut preferred = receipt("$preferred", 1);
        preferred.1.ts = None;
        let result = newer_receipt(Some(preferred), Some(receipt("$other", 2)), &HashMap::new());
        assert_eq!(result.unwrap().0.as_str(), "$preferred");
    }

    #[test]
    fn select_entry_boundary_advances_to_newer_cached_markers_never_backwards() {
        let positions = HashMap::from([
            ("$old_fully_read".to_owned(), 2),
            ("$explicit".to_owned(), 5),
            ("$latest_active".to_owned(), 10),
        ]);
        // Newer latest_active advances over explicit; older fully_read does not move back.
        assert_eq!(
            select_entry_boundary(
                Some("$explicit".to_owned()),
                Some("$latest_active"),
                Some("$old_fully_read"),
                &positions,
            )
            .as_deref(),
            Some("$latest_active")
        );
        // Cached fully_read beats an explicit receipt that is older than the cache window.
        let recent_only = HashMap::from([("$recent_fully_read".to_owned(), 3)]);
        assert_eq!(
            select_entry_boundary(
                Some("$ancient_explicit".to_owned()),
                None,
                Some("$recent_fully_read"),
                &recent_only,
            )
            .as_deref(),
            Some("$recent_fully_read")
        );
        // Uncached fully_read does not override an explicit receipt.
        assert_eq!(
            select_entry_boundary(
                Some("$explicit".to_owned()),
                None,
                Some("$unknown_fully_read"),
                &HashMap::new(),
            )
            .as_deref(),
            Some("$explicit")
        );
    }

    #[test]
    fn resolved_empty_interval_zeros_stale_reported_unread_count() {
        assert_eq!(reconcile_local_unread_count(3, &[], &[]), 0);
        assert_eq!(reconcile_local_unread_count(5, &["$a".to_owned()], &[]), 1);
        assert_eq!(reconcile_local_unread_count(0, &["$a".to_owned()], &[]), 0);
        assert_eq!(
            reconcile_local_unread_count(3, &[], &["$utd".to_owned()]),
            3
        );
    }

    #[test]
    fn tail_after_own_event_ignores_own_state_events() {
        let member_raw: Raw<AnySyncTimelineEvent> = serde_json::from_value(json!({
            "type": "m.room.member",
            "event_id": "$member",
            "sender": "@alice:example.org",
            "state_key": "@alice:example.org",
            "origin_server_ts": 2,
            "content": { "membership": "join", "displayname": "Alice New" }
        }))
        .unwrap();
        let events = vec![
            make_text_event("@bob:example.org", "$1"),
            make_text_event("@alice:example.org", "$2"),
            make_text_event("@bob:example.org", "$3"),
            TimelineEvent::from_plaintext(member_raw),
            make_text_event("@bob:example.org", "$4"),
        ];
        // Stops at own text message $2 (index 1 -> tail_start 2), not own m.room.member.
        assert_eq!(tail_after_own_event(&events, "@alice:example.org"), 2);
        assert_eq!(tail_after_own_event(&events, "@carol:example.org"), 0);
    }

    #[test]
    fn last_boundary_in_slice_cuts_at_own_event_or_frozen_boundary() {
        let events = vec![
            make_text_event("@bob:example.org", "$1"),
            make_text_event("@bob:example.org", "$2"),
            make_text_event("@alice:example.org", "$own"),
            make_text_event("@bob:example.org", "$3"),
        ];
        let boundaries = HashSet::from(["$1".to_owned()]);
        let whole_room = HashSet::from(["$1".to_owned()]);
        assert_eq!(
            last_boundary_in_slice(&events, &boundaries, &whole_room, "@alice:example.org"),
            Some((2, true))
        );
        // Main-only boundary cuts at $2 without falsely claiming whole_room.
        let main_only = HashSet::from(["$2".to_owned()]);
        assert_eq!(
            last_boundary_in_slice(&events, &main_only, &HashSet::new(), "@carol:example.org"),
            Some((1, false))
        );
    }

    #[test]
    fn renderable_raw_unread_event_filters_redacted_and_unsupported_events() {
        let text: AnySyncTimelineEvent = serde_json::from_value(json!({
            "type": "m.room.message",
            "event_id": "$text",
            "sender": "@bob:example.org",
            "origin_server_ts": 1,
            "content": { "msgtype": "m.text", "body": "hello" }
        }))
        .unwrap();
        assert!(is_renderable_raw_unread_event(&text));

        let redacted: AnySyncTimelineEvent = serde_json::from_value(json!({
            "type": "m.room.message",
            "event_id": "$redacted",
            "sender": "@bob:example.org",
            "origin_server_ts": 2,
            "content": {},
            "unsigned": { "redacted_because": {
                "type": "m.room.redaction",
                "event_id": "$red",
                "sender": "@bob:example.org",
                "origin_server_ts": 3,
                "content": {},
                "redacts": "$redacted"
            } }
        }))
        .unwrap();
        assert!(!is_renderable_raw_unread_event(&redacted));

        let custom: AnySyncTimelineEvent = serde_json::from_value(json!({
            "type": "m.room.message",
            "event_id": "$custom",
            "sender": "@bob:example.org",
            "origin_server_ts": 4,
            "content": { "msgtype": "com.example.unsupported", "body": "x" }
        }))
        .unwrap();
        assert!(!is_renderable_raw_unread_event(&custom));
    }

    #[tokio::test]
    async fn frozen_entry_boundaries_only_apply_when_primary_read_matches() {
        let account = "@boundary-test:example.org";
        let room = "!boundary-room:example.org";
        let through = "$tail";
        save_entry_boundaries(
            account,
            room,
            through,
            EntryBoundarySnapshot {
                primary_read_event_id: Some("$auto_read".to_owned()),
                candidate_ids: HashSet::from(["$auto_read".to_owned(), "$fully_read".to_owned()]),
                whole_room_ids: HashSet::from(["$auto_read".to_owned(), "$fully_read".to_owned()]),
            },
        )
        .await;

        let (matched, whole) =
            load_matching_entry_boundaries(account, room, "$auto_read", through).await;
        assert!(matched.contains("$fully_read"));
        assert!(whole.contains("$fully_read"));

        // A resumed visit extending an older pre-auto-read starting point must
        // not pick up the post-auto-read boundary snapshot.
        let (resumed, resumed_whole) =
            load_matching_entry_boundaries(account, room, "$old_entry", through).await;
        assert_eq!(resumed, HashSet::from(["$old_entry".to_owned()]));
        assert!(resumed_whole.is_empty());

        clear_for_user(account).await;
    }
}
