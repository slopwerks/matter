//! Sdk snapshot adaptation.
use super::*;

pub(in crate::api::matrix) async fn convert_snapshot(
    room: &Room,
    items: &[Arc<TimelineItem>],
) -> Vec<ChatMessage> {
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
                            &ReceiptThread::Unthreaded,
                            &user_id,
                        ),
                        room.load_user_receipt(
                            EventReceiptType::Read,
                            &ReceiptThread::Main,
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

pub(in crate::api::matrix) fn record_latest_receipt_position(
    receipt_positions: &mut HashMap<String, usize>,
    user_id: String,
    position: usize,
) {
    receipt_positions
        .entry(user_id)
        .and_modify(|current| *current = (*current).max(position))
        .or_insert(position);
}

pub(in crate::api::matrix) fn newest_receipt_position<'a>(
    receipt_event_ids: impl IntoIterator<Item = &'a matrix_sdk::ruma::EventId>,
    event_positions: &HashMap<String, usize>,
) -> Option<usize> {
    receipt_event_ids
        .into_iter()
        .filter_map(|event_id| resolve_receipt_position(event_id, event_positions))
        .max()
}

pub(in crate::api::matrix) fn resolve_receipt_position(
    receipt_event_id: &matrix_sdk::ruma::EventId,
    event_positions: &HashMap<String, usize>,
) -> Option<usize> {
    event_positions.get(receipt_event_id.as_str()).copied()
}

pub(in crate::api::matrix) fn reader_ids_for_position(
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
