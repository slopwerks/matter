//! Event handlers implementation.

use super::*;

pub(super) async fn active_generation_for_client(identity: &ClientIdentity) -> Option<u64> {
    let generation = SYNC_EVENT_GENERATION
        .try_with(|generation| *generation)
        .unwrap_or_else(|_| SYNC_GENERATION.load(Ordering::SeqCst));
    if !sync_generation_is_active(generation, &identity.user_id).await {
        return None;
    }
    let is_current_instance = CLIENTS
        .read()
        .await
        .get(&identity.user_id)
        .is_some_and(|entry| entry.instance_id == identity.instance_id);
    if !is_current_instance || !sync_generation_is_active(generation, &identity.user_id).await {
        return None;
    }
    Some(generation)
}

pub(super) async fn notify_sync_event_for_client(identity: &ClientIdentity, event: SyncEvent) {
    if let Some(generation) = active_generation_for_client(identity).await {
        notify_sync_event_for_generation(generation, event);
    }
}

pub(super) fn install_verification_event_handler(client: &Client, identity: ClientIdentity) {
    client.add_event_handler(
        move |event: ToDeviceKeyVerificationRequestEvent, client: Client| {
            let identity = identity.clone();
            async move {
                let Some(own_user_id) = client.user_id() else {
                    return;
                };
                if event.sender != own_user_id
                    || active_generation_for_client(&identity).await.is_none()
                {
                    return;
                }

                let session = VerificationSession {
                    user_id: event.sender.to_string(),
                    device_id: event.content.from_device.to_string(),
                    flow_id: event.content.transaction_id.to_string(),
                    incoming: true,
                    accepted: false,
                };
                *VERIFICATION_SESSION.write().await = Some(session);
                app_log(
                    "info",
                    "encryption",
                    "Received a device verification request".to_string(),
                );
            }
        },
    );
}

pub(super) fn install_live_update_event_handlers(client: &Client, identity: ClientIdentity) {
    let message_identity = identity.clone();
    client.add_event_handler(move |event: AnySyncMessageLikeEvent, room: Room| {
        let identity = message_identity.clone();
        async move {
            if let AnySyncMessageLikeEvent::RoomRedaction(redaction) = &event {
                let rules = room.clone_info().room_version_rules_or_default().redaction;
                if let Some(event_id) = redaction.redacts(&rules) {
                    notify_sync_event_for_client(
                        &identity,
                        SyncEvent::MessageRedacted {
                            room_id: room.room_id().to_string(),
                            event_id: event_id.to_string(),
                        },
                    )
                    .await;
                }
            }
            notify_sync_event_for_client(
                &identity,
                SyncEvent::MessageSent {
                    room_id: room.room_id().to_string(),
                },
            )
            .await;
        }
    });

    let receipt_identity = identity.clone();
    client.add_event_handler(move |event: SyncReceiptEvent, room: Room| {
        let identity = receipt_identity.clone();
        async move {
            let room_id = room.room_id().to_string();
            let public_receipt_count = event
                .content
                .values()
                .filter_map(|receipts| {
                    receipts.get(&matrix_sdk::ruma::events::receipt::ReceiptType::Read)
                })
                .map(|receipts| receipts.len())
                .sum::<usize>();
            app_log(
                "info",
                "receipts",
                format!(
                    "Received explicit receipt event for room {room_id}: {} public receipt(s)",
                    public_receipt_count
                ),
            );
            notify_sync_event_for_client(&identity, SyncEvent::MessageSent { room_id }).await;
        }
    });

    let pinned_identity = identity.clone();
    client.add_event_handler(
        move |_event: SyncStateEvent<RoomPinnedEventsEventContent>, room: Room| {
            let identity = pinned_identity.clone();
            async move {
                notify_sync_event_for_client(
                    &identity,
                    SyncEvent::PinnedMessagesChanged {
                        room_id: room.room_id().to_string(),
                    },
                )
                .await;
            }
        },
    );

    let member_identity = identity.clone();
    client.add_event_handler(
        move |_event: SyncStateEvent<RoomMemberEventContent>, room: Room| {
            let identity = member_identity.clone();
            async move {
                notify_sync_event_for_client(
                    &identity,
                    SyncEvent::RoomMembersChanged {
                        room_id: room.room_id().to_string(),
                    },
                )
                .await;
            }
        },
    );

    let marked_unread_identity = identity.clone();
    client.add_event_handler(
        move |event: RoomAccountDataEvent<MarkedUnreadEventContent>, room: Room, client: Client| {
            let identity = marked_unread_identity.clone();
            async move {
                if active_generation_for_client(&identity).await.is_none() {
                    return;
                }
                if let Some(key) = marked_unread_override_key(&client, &room) {
                    let mut overrides = MARKED_UNREAD_OVERRIDES.write().await;
                    let synced = event.content.unread;
                    reconcile_marked_unread_override(&mut overrides, &key, synced);
                }
                notify_sync_event_for_client(&identity, SyncEvent::RoomListChanged).await;
            }
        },
    );

    let ignored_identity = identity;
    client.add_event_handler(
        move |event: GlobalAccountDataEvent<IgnoredUserListEventContent>, client: Client| {
            let identity = ignored_identity.clone();
            async move {
                if active_generation_for_client(&identity).await.is_none() {
                    return;
                }
                reconcile_ignored_user_overrides(&client, &event.content).await;
                notify_sync_event_for_client(&identity, SyncEvent::IgnoredUsersChanged).await;
            }
        },
    );
}
