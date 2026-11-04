//! Desktop notifications use the SDK's evaluated push actions, not unread badges.

use flutter_rust_bridge::frb;
use matrix_sdk::{ruma::push::Action, Client, Room};
use once_cell::sync::Lazy;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

use super::{
    active_generation_for_client, effective_is_user_ignored, room_message_preview,
    sync_generation_is_active, ClientIdentity,
};

#[frb]
#[derive(Clone, Debug)]
pub struct DesktopNotification {
    pub user_id: String,
    pub room_id: String,
    pub event_id: String,
    pub room_name: String,
    pub sender_name: String,
    pub body: String,
}

static EVENTS: Lazy<tokio::sync::broadcast::Sender<DesktopNotification>> =
    Lazy::new(|| tokio::sync::broadcast::channel(128).0);

#[frb]
pub fn watch_desktop_notifications(sink: crate::frb_generated::StreamSink<DesktopNotification>) {
    let mut events = EVENTS.subscribe();
    std::thread::spawn(move || loop {
        match events.blocking_recv() {
            Ok(event) => {
                if sink.add(event).is_err() {
                    break;
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    });
}

pub(super) async fn install(client: &Client, identity: ClientIdentity) {
    if !cfg!(target_os = "linux") {
        return;
    }
    let started = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    client
        .register_notification_handler(move |notification, room: Room, client: Client| {
            let identity = identity.clone();
            async move {
                let Some(generation) = active_generation_for_client(&identity).await else {
                    return;
                };
                if !notification.actions.iter().any(Action::should_notify)
                    || room.num_unread_notifications() == 0
                {
                    return;
                }
                let Ok(event) = serde_json::to_value(notification.event) else {
                    return;
                };
                let sender = event["sender"].as_str().unwrap_or_default();
                let event_id = event["event_id"].as_str().unwrap_or_default();
                if event_id.is_empty()
                    || sender == identity.user_id
                    || event["origin_server_ts"].as_u64().unwrap_or_default()
                        < started.saturating_sub(10_000)
                    || event["content"]["m.relates_to"]["rel_type"] == "m.replace"
                {
                    return;
                }
                let Ok(sender_id) = matrix_sdk::ruma::UserId::parse(sender) else {
                    return;
                };
                if effective_is_user_ignored(&client, &sender_id).await {
                    return;
                }
                let encrypted = room
                    .latest_encryption_state()
                    .await
                    .map(|state| state.is_encrypted())
                    .unwrap_or(true);
                let body = if encrypted {
                    "收到一条加密消息".to_owned()
                } else {
                    preview(&event)
                };
                let sender_name = room
                    .get_member_no_sync(&sender_id)
                    .await
                    .ok()
                    .flatten()
                    .map(|member| member.name().to_owned())
                    .unwrap_or_else(|| sender.to_owned());
                let room_name = room
                    .display_name()
                    .await
                    .map(|name| name.to_string())
                    .unwrap_or_else(|_| room.room_id().to_string());
                if sync_generation_is_active(generation, &identity.user_id).await {
                    let _ = EVENTS.send(DesktopNotification {
                        user_id: identity.user_id,
                        room_id: room.room_id().to_string(),
                        event_id: event_id.to_owned(),
                        room_name,
                        sender_name,
                        body,
                    });
                }
            }
        })
        .await;
}

fn preview(event: &Value) -> String {
    let body = serde_json::from_value(event["content"].clone())
        .ok()
        .and_then(|content| room_message_preview(&content))
        .unwrap_or_else(|| "收到一条新消息".to_owned());
    body.chars().take(240).collect()
}
