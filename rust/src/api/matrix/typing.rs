//! Typing implementation.

use super::*;

pub(super) fn take_typing_task_for_owner(
    task: &mut Option<TypingTask>,
    room_id: &str,
    subscription_id: &str,
) -> Option<TypingTask> {
    if task.as_ref().is_some_and(|active| {
        active.room_id == room_id && active.subscription_id == subscription_id
    }) {
        task.take()
    } else {
        None
    }
}

pub(super) fn watch_typing_notifications(
    sink: crate::frb_generated::StreamSink<TypingNotification>,
) {
    let mut rx = TYPING_TX.subscribe();
    std::thread::spawn(move || loop {
        match rx.blocking_recv() {
            Ok(event) => {
                if sink.add(event).is_err() {
                    break; // Dart side disconnected
                }
            }
            // A slow Dart side can overflow the broadcast buffer; drop the
            // stale backlog and keep listening instead of dying.
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    });
}

pub(super) async fn subscribe_typing_for_room(
    room_id: String,
    account_user_id: Option<String>,
) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("typing", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    let subscription_id = NEXT_TYPING_SUBSCRIPTION_ID
        .fetch_add(1, Ordering::Relaxed)
        .to_string();
    let (_subscription_user, mut task) = lock_subscription_state(
        &SUBSCRIPTION_USER,
        &TYPING_TASK,
        account_user_id.as_deref(),
        "Typing subscription belongs to an inactive account",
    )
    .await?;
    if let Some(prev) = task.take() {
        prev.handle.abort();
    }

    // subscribe_to_typing_notifications returns (drop_guard, receiver).
    // The guard must stay alive for the lifetime of the subscription, so we
    // move it into the spawned task along with the receiver.
    let (guard, mut rx) = room.subscribe_to_typing_notifications();
    let tx = TYPING_TX.clone();
    let room_id_for_task = room_id.clone();

    let handle = tokio::spawn(async move {
        // Keep the guard alive by holding it for the task's lifetime.
        let _guard = guard;
        while let Ok(user_ids) = rx.recv().await {
            let ids: Vec<String> = user_ids.into_iter().map(|u| u.to_string()).collect();
            let _ = tx.send(TypingNotification {
                room_id: room_id_for_task.clone(),
                user_ids: ids,
            });
        }
    });

    *task = Some(TypingTask {
        room_id,
        subscription_id: subscription_id.clone(),
        handle,
    });
    Ok(subscription_id)
}

pub(super) async fn unsubscribe_typing(
    room_id: String,
    subscription_id: String,
    account_user_id: Option<String>,
) -> Result<(), String> {
    let (_subscription_user, mut task) = lock_subscription_state(
        &SUBSCRIPTION_USER,
        &TYPING_TASK,
        account_user_id.as_deref(),
        "Typing subscription belongs to an inactive account",
    )
    .await?;
    if let Some(task) = take_typing_task_for_owner(&mut task, &room_id, &subscription_id) {
        task.handle.abort();
    }
    Ok(())
}

pub(super) fn live_room_subscription(
) -> matrix_sdk::ruma::api::client::sync::sync_events::v5::request::RoomSubscription {
    use matrix_sdk::ruma::{events::StateEventType, UInt};

    let mut subscription =
        matrix_sdk::ruma::api::client::sync::sync_events::v5::request::RoomSubscription::default();
    subscription.timeline_limit = UInt::from(50u32);
    subscription.required_state = vec![(StateEventType::RoomPinnedEvents, String::new())];
    subscription
}
