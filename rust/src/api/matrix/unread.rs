//! Preserve a room's entry read boundary and resolve its next visible message.

use std::collections::{HashMap, HashSet};

use flutter_rust_bridge::frb;
use matrix_sdk::{
    room::MessagesOptions,
    ruma::{
        events::{
            receipt::{Receipt, ReceiptThread, ReceiptType},
            AnySyncTimelineEvent,
        },
        EventId, OwnedEventId,
    },
};
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
        let positions = items
            .iter()
            .enumerate()
            .filter_map(|(position, item)| {
                item.as_event()
                    .and_then(|event| event.event_id())
                    .map(|id| (id.to_string(), position))
            })
            .collect();
        let mut slots = receipts.into_iter();
        let unthreaded = newer_receipt(slots.next().flatten(), slots.next().flatten(), &positions);
        let main = newer_receipt(slots.next().flatten(), slots.next().flatten(), &positions);
        let receipt = newer_receipt(unthreaded, main, &positions);
        Ok(RoomUnreadState {
            unread_count,
            read_event_id: receipt.map(|(event_id, _)| event_id.to_string()),
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
