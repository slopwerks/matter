use std::{collections::BTreeMap, sync::Arc};

use matrix_sdk::{
    deserialized_responses::{
        AlgorithmInfo, DecryptedRoomEvent, EncryptionInfo, TimelineEvent, UnableToDecryptInfo,
        UnableToDecryptReason, VerificationState,
    },
    ruma::{room_id, serde::Raw, user_id, RoomId},
    test_utils::mocks::MatrixMockServer,
    Client,
};
use matrix_sdk_base::linked_chunk::{ChunkIdentifier, LinkedChunkId, Position, Update};
use matrix_sdk_test::{event_factory::EventFactory, JoinedRoomBuilder};
use serde_json::{json, Value};

use super::{cached_media_messages, MessageType};

fn raw_event(id: &str, content: Value) -> Value {
    json!({
        "type": "m.room.message", "event_id": id,
        "sender": "@alice:localhost", "origin_server_ts": 1000,
        "content": content,
    })
}

fn plaintext(value: Value) -> TimelineEvent {
    TimelineEvent::from_plaintext(Raw::from_json_string(value.to_string()).unwrap())
}

fn image(id: &str) -> TimelineEvent {
    plaintext(raw_event(
        id,
        json!({
            "msgtype": "m.image", "body": "photo.jpg", "url": "mxc://localhost/photo",
        }),
    ))
}

fn decrypted_audio(room_id: &RoomId) -> TimelineEvent {
    let mut event = raw_event(
        "$encrypted-audio",
        json!({
            "msgtype": "m.audio", "body": "voice.ogg", "info": {"mimetype": "audio/ogg"},
            "file": {
                "url": "mxc://localhost/audio", "v": "v2",
                "key": {"kty": "oct", "key_ops": ["encrypt", "decrypt"], "alg": "A256CTR",
                    "k": "A".repeat(43), "ext": true},
                "iv": "A".repeat(22),
                "hashes": {"sha256": "A".repeat(43)},
            },
        }),
    );
    event["room_id"] = json!(room_id);
    TimelineEvent::from_decrypted(
        DecryptedRoomEvent {
            event: Raw::from_json_string(event.to_string()).unwrap(),
            encryption_info: Arc::new(EncryptionInfo {
                sender: user_id!("@alice:localhost").to_owned(),
                sender_device: None,
                forwarder: None,
                algorithm_info: AlgorithmInfo::MegolmV1AesSha2 {
                    curve25519_key: String::new(),
                    sender_claimed_keys: BTreeMap::new(),
                    session_id: Some("available-session".to_owned()),
                },
                verification_state: VerificationState::Verified,
            }),
            unsigned_encryption_info: None,
        },
        None,
    )
}

async fn store_events(client: &Client, room_id: &RoomId, events: &[TimelineEvent]) {
    let mut updates = Vec::new();
    for (index, items) in events.chunks(100).enumerate() {
        let id = ChunkIdentifier::new(index as u64);
        updates.push(Update::NewItemsChunk {
            previous: index.checked_sub(1).map(|i| ChunkIdentifier::new(i as u64)),
            new: id,
            next: None,
        });
        updates.push(Update::PushItems {
            at: Position::new(id, 0),
            items: items.to_vec(),
        });
    }
    client
        .event_cache_store()
        .lock()
        .await
        .unwrap()
        .as_clean()
        .unwrap()
        .handle_linked_chunk_updates(LinkedChunkId::Room(room_id), updates)
        .await
        .unwrap();
}

#[tokio::test]
async fn sdk_store_reads_old_chunks_and_decrypted_media_without_network_or_key_requests() {
    let server = MatrixMockServer::new().await;
    let client = server.client_builder().build().await;
    let room_id = room_id!("!encrypted-storage:localhost");
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id).add_state_event(
                EventFactory::new()
                    .room(room_id)
                    .sender(user_id!("@alice:localhost"))
                    .room_encryption(),
            ),
        )
        .await;
    let mut events = vec![image("$older-than-200")];
    events.extend((0..310).map(|i| {
        plaintext(raw_event(
            &format!("$text-{i}"),
            json!({
                "msgtype": "m.text", "body": "private text must not be returned",
            }),
        ))
    }));
    events.push(decrypted_audio(room_id));
    let mut encrypted = raw_event(
        "$missing-key",
        json!({
            "algorithm": "m.megolm.v1.aes-sha2", "session_id": "unavailable",
            "sender_key": "unavailable", "ciphertext": "unavailable", "device_id": "DEVICE",
        }),
    );
    encrypted["type"] = json!("m.room.encrypted");
    let missing = TimelineEvent::from_utd(
        Raw::from_json_string(encrypted.to_string()).unwrap(),
        UnableToDecryptInfo {
            session_id: Some("unavailable".to_owned()),
            reason: UnableToDecryptReason::MissingMegolmSession {
                withheld_code: None,
            },
        },
    );
    events.push(missing.clone());
    store_events(&client, room_id, &events).await;
    let machine = client.olm_machine_for_testing().await;
    let before_keys = match machine.as_ref() {
        Some(machine) => machine.outgoing_requests().await.unwrap().len(),
        None => 0,
    };
    drop(machine);
    server.verify_and_reset().await;
    let rooms = cached_media_messages(&client, client.user_id().unwrap().as_str())
        .await
        .unwrap();
    let messages = &rooms[room_id.as_str()];
    assert_eq!(messages.len(), 2);
    assert!(messages.iter().any(|m| m.id == "$older-than-200"));
    let audio = messages
        .iter()
        .find(|m| m.id == "$encrypted-audio")
        .unwrap();
    assert!(matches!(audio.msg_type, MessageType::File));
    assert_eq!(audio.mime_type.as_deref(), Some("audio/ogg"));
    assert_eq!(audio.filename.as_deref(), Some("voice.ogg"));
    let source: Value = serde_json::from_str(audio.media_source_json.as_ref().unwrap()).unwrap();
    assert_eq!(source["file"]["url"], "mxc://localhost/audio");
    assert!(messages
        .iter()
        .all(|m| m.content.is_empty() && m.sender_name.is_empty()));
    let machine = client.olm_machine_for_testing().await;
    let after_keys = match machine.as_ref() {
        Some(machine) => machine.outgoing_requests().await.unwrap().len(),
        None => 0,
    };
    assert_eq!(
        before_keys, after_keys,
        "Attribution must not enqueue key requests"
    );
    assert!(server
        .server()
        .received_requests()
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn sdk_store_ignores_redacted_media_and_edits_of_a_redacted_message() {
    let server = MatrixMockServer::new().await;
    let client = server.client_builder().build().await;
    let room_id = room_id!("!redacted-storage:localhost");
    server
        .sync_room(&client, JoinedRoomBuilder::new(room_id))
        .await;
    let edit = plaintext(raw_event(
        "$edit",
        json!({
            "msgtype": "m.image", "body": "replacement.jpg", "url": "mxc://localhost/edited",
            "m.relates_to": {"rel_type": "m.replace", "event_id": "$redacted"},
        }),
    ));
    let redaction = plaintext(json!({
        "type": "m.room.redaction", "event_id": "$redaction", "sender": "@alice:localhost",
        "origin_server_ts": 2000, "content": {"redacts": "$redacted"},
    }));
    let mut already_redacted = raw_event("$already-redacted", json!({"msgtype": "m.image"}));
    already_redacted["unsigned"] = json!({"redacted_because": {}});
    let kept = plaintext(raw_event(
        "$document",
        json!({
            "msgtype": "m.file", "body": "file.pdf", "url": "mxc://localhost/document",
        }),
    ));
    store_events(
        &client,
        room_id,
        &[
            image("$redacted"),
            edit,
            redaction,
            plaintext(already_redacted),
            kept,
        ],
    )
    .await;
    server.verify_and_reset().await;
    let rooms = cached_media_messages(&client, client.user_id().unwrap().as_str())
        .await
        .unwrap();
    let messages = &rooms[room_id.as_str()];
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].id, "$document");
    assert!(server
        .server()
        .received_requests()
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn sdk_store_rejects_a_switched_account_without_reading_or_requesting_history() {
    let server = MatrixMockServer::new().await;
    let client = server.client_builder().build().await;
    let error = cached_media_messages(&client, "@other:localhost")
        .await
        .unwrap_err();
    assert!(error.contains("账号已切换"));
    assert!(server
        .server()
        .received_requests()
        .await
        .unwrap()
        .is_empty());
}
