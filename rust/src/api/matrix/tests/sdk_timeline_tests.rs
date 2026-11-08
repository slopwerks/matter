use super::{
    checked_history_page, complete_pinned_messages, loaded_expected_event_count,
    missing_pinned_event_ids, newest_receipt_position, ordered_pinned_messages,
    pinned_events_ready, reader_ids_for_position, record_latest_receipt_position,
    resolve_receipt_position,
};
use crate::api::matrix::uint_to_i32;
use crate::api::matrix::{ChatMessage, MessageType};
use std::collections::{HashMap, HashSet};

#[test]
fn empty_history_page_requires_a_confirmed_start() {
    assert!(checked_history_page(Vec::new(), 100, false).is_err());
    assert!(checked_history_page(Vec::new(), 100, true)
        .unwrap()
        .is_empty());
}

#[test]
fn partial_history_page_still_advances_the_anchor() {
    let page = checked_history_page(vec![message("$older")], 100, false).unwrap();
    assert_eq!(page[0].id, "$older");
}

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
        shared_caption: None,
        image_metadata: None,
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
        mime_type: None,
        duration_ms: None,
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
fn media_duration_uses_positive_milliseconds_and_rejects_overflow() {
    use matrix_sdk::ruma::events::room::message::{AudioInfo, VideoInfo};
    let audio: AudioInfo = serde_json::from_value(serde_json::json!({"duration": 65432})).unwrap();
    let video: VideoInfo = serde_json::from_value(serde_json::json!({"duration": 123456})).unwrap();
    assert_eq!(super::media_duration_ms(audio.duration), Some(65432));
    assert_eq!(super::media_duration_ms(video.duration), Some(123456));
    assert_eq!(super::media_duration_ms(None), None);
    assert_eq!(
        super::media_duration_ms(Some(std::time::Duration::ZERO)),
        None
    );
    assert_eq!(
        super::media_duration_ms(Some(std::time::Duration::from_millis(i32::MAX as u64 + 1))),
        None
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

#[test]
fn event_chat_message_populates_mime_type_and_event_type() {
    let msg = super::event_chat_message(
        "$123".to_owned(),
        "@alice:server".to_owned(),
        "Alice".to_owned(),
        "1000".to_owned(),
        "Alice 更改了头像".to_owned(),
        "m.room.member:avatar",
    );
    assert_eq!(msg.id, "$123");
    assert_eq!(msg.content, "Alice 更改了头像");
    assert_eq!(msg.mime_type, Some("m.room.member:avatar".to_owned()));
    assert!(matches!(msg.msg_type, MessageType::Event));
}
