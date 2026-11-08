use std::collections::{HashMap, HashSet};

use super::{
    backfill_message_search_with_client, insert_latest_search_result, message_matches_search_terms,
    message_search_index_query, message_search_room_key, message_search_terms,
    ordered_event_cache_chunk_ids, paginate_message_search_results, search_messages_with_client,
    MessageSearchResult, SEARCH_HISTORY_COMPLETE,
};
use matrix_sdk::{
    ruma::{event_id, room_id, user_id},
    search_index::SearchIndexStoreKind,
    test_utils::mocks::{MatrixMockServer, RoomMessagesResponseTemplate},
};
use matrix_sdk_base::linked_chunk::{ChunkIdentifier, ChunkMetadata};
use matrix_sdk_test::{event_factory::EventFactory, JoinedRoomBuilder};
use tantivy::{
    collector::TopDocs,
    doc,
    query::QueryParser,
    schema::{Schema, STRING, TEXT},
    Index,
};

fn search_count(body: &str, query: &str) -> usize {
    let mut schema = Schema::builder();
    let body_field = schema.add_text_field("body", TEXT);
    let body_ngram_field = schema.add_text_field("body_ngram", STRING);
    let schema = schema.build();
    let index = Index::create_in_ram(schema);
    let mut writer = index.writer(15_000_000).unwrap();
    let mut document = doc!(body_field => body);
    let normalized = body.to_lowercase();
    for term in normalized.split(|character: char| !character.is_alphanumeric()) {
        let characters = term.chars().collect::<Vec<_>>();
        for size in 1..=characters.len().min(3) {
            for gram in characters.windows(size) {
                document.add_text(body_ngram_field, gram.iter().collect::<String>());
            }
        }
    }
    writer.add_document(document).unwrap();
    writer.commit().unwrap();
    let reader = index.reader().unwrap();
    let parser = QueryParser::for_index(&index, vec![body_field]);
    let terms = message_search_terms(query);
    let query = parser
        .parse_query(&message_search_index_query(&terms))
        .unwrap();
    reader
        .searcher()
        .search(&query, &TopDocs::with_limit(10).order_by_score())
        .unwrap()
        .len()
}

#[test]
fn substring_query_matches_unsegmented_cjk_terms() {
    assert_eq!(search_count("今晚八点开会", "八点开会"), 1);
    assert_eq!(search_count("検索機能を確認する", "機能"), 1);
    assert_eq!(search_count("메시지 검색 기능", "검색"), 1);
}

#[test]
fn query_is_literal_case_insensitive_and_requires_every_term() {
    assert_eq!(
        search_count("ReleasePlanning starts today", "PLANNING TOD"),
        1
    );
    assert_eq!(search_count("明天在北京见", "明天 北京"), 1);
    assert_eq!(search_count("明天再说", "明天 北京"), 0);
    assert!(message_matches_search_terms(
        "混合 Matrix 消息",
        &message_search_terms("matrix 消息")
    ));
}

#[test]
fn edited_search_result_replaces_the_original_target() {
    let result = |body: &str, is_edited: bool| MessageSearchResult {
        room_id: "!room:example.org".to_owned(),
        room_name: "Room".to_owned(),
        room_avatar_url: None,
        event_id: "$original".to_owned(),
        sender_id: "@alice:example.org".to_owned(),
        sender_name: "Alice".to_owned(),
        body: body.to_owned(),
        timestamp: "10".to_owned(),
        is_dm: false,
        is_edited,
    };
    let mut results = HashMap::new();

    insert_latest_search_result(
        &mut results,
        result("原始内容", false),
        10,
        "$original".to_owned(),
    );
    insert_latest_search_result(
        &mut results,
        result("最新内容", true),
        30,
        "$edit-2".to_owned(),
    );
    insert_latest_search_result(
        &mut results,
        result("过时内容", true),
        20,
        "$edit-1".to_owned(),
    );

    assert_eq!(results.len(), 1);
    assert_eq!(results.into_values().next().unwrap().0.body, "最新内容");
}

#[test]
fn message_search_pages_skip_results_without_reloading_the_first_page() {
    let result = |event_id: &str| MessageSearchResult {
        room_id: "!room:example.org".to_owned(),
        room_name: "Room".to_owned(),
        room_avatar_url: None,
        event_id: event_id.to_owned(),
        sender_id: "@alice:example.org".to_owned(),
        sender_name: "Alice".to_owned(),
        body: "消息".to_owned(),
        timestamp: "10".to_owned(),
        is_dm: false,
        is_edited: false,
    };
    let results = vec![result("$first"), result("$second"), result("$third")];

    let (page, has_more) = paginate_message_search_results(results, 1, 1);

    assert_eq!(page.len(), 1);
    assert_eq!(page[0].event_id, "$second");
    assert!(has_more);
}

#[test]
fn cached_message_chunks_are_indexed_oldest_first() {
    let id = ChunkIdentifier::new;
    let chunks = vec![
        ChunkMetadata {
            num_items: 5,
            previous: Some(id(1)),
            identifier: id(2),
            next: None,
        },
        ChunkMetadata {
            num_items: 5,
            previous: None,
            identifier: id(0),
            next: Some(id(1)),
        },
        ChunkMetadata {
            num_items: 5,
            previous: Some(id(0)),
            identifier: id(1),
            next: Some(id(2)),
        },
    ];

    assert_eq!(
        ordered_event_cache_chunk_ids(chunks).unwrap(),
        [id(0), id(1), id(2)]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn bounded_hydration_preserves_ignored_filters_and_page_order() {
    let server = MatrixMockServer::new().await;
    let client = server
        .client_builder()
        .on_builder(|builder| builder.search_index_store(SearchIndexStoreKind::InMemory))
        .build()
        .await;
    client.event_cache().subscribe().unwrap();
    let room_id = room_id!("!parallel-search:localhost");
    let events = EventFactory::new()
        .room(room_id)
        .sender(user_id!("@alice:localhost"));
    let ids = [
        event_id!("$parallel-0"),
        event_id!("$parallel-1"),
        event_id!("$parallel-2"),
        event_id!("$parallel-3"),
    ];
    let mut builder = JoinedRoomBuilder::new(room_id);
    for (index, id) in ids.iter().enumerate() {
        builder = builder.add_timeline_event(
            events
                .text_msg("needle body")
                .event_id(id)
                .server_ts((index as u64 + 1) * 1000),
        );
    }
    server.sync_room(&client, builder).await;
    let ignored = search_messages_with_client(
        &client,
        "needle".to_owned(),
        Some(room_id.to_string()),
        0,
        2,
        Some(vec!["@alice:localhost".to_owned()]),
    )
    .await
    .unwrap();
    assert!(ignored.results.is_empty());
    let first = search_messages_with_client(
        &client,
        "needle".to_owned(),
        Some(room_id.to_string()),
        0,
        2,
        Some(Vec::new()),
    )
    .await
    .unwrap();
    let second = search_messages_with_client(
        &client,
        "needle".to_owned(),
        Some(room_id.to_string()),
        2,
        2,
        Some(Vec::new()),
    )
    .await
    .unwrap();
    assert!(first.has_more);
    assert!(!second.has_more);
    assert_eq!(
        first
            .results
            .iter()
            .map(|result| result.event_id.as_str())
            .collect::<Vec<_>>(),
        ["$parallel-3", "$parallel-2"]
    );
    assert_eq!(
        second
            .results
            .iter()
            .map(|result| result.event_id.as_str())
            .collect::<Vec<_>>(),
        ["$parallel-1", "$parallel-0"]
    );
    server.verify_and_reset().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn bounded_hydration_stops_before_fetching_a_superseded_query() {
    let server = MatrixMockServer::new().await;
    let client = server.client_builder().build().await;
    let room_id = room_id!("!cancel-parallel:localhost");
    let room = server
        .sync_room(&client, JoinedRoomBuilder::new(room_id))
        .await;
    let (key, generation) = super::begin_message_search(&client, Some(room_id.as_str())).await;
    let _ = super::begin_message_search(&client, Some(room_id.as_str())).await;
    let names = super::search_hydration::SenderNames::new();
    let candidates = super::search_hydration::HydrationContext {
        client: &client,
        room: &room,
        terms: &["needle".to_owned()],
        ignored: Some(&HashSet::new()),
        is_dm: false,
        sender_names: &names,
        search_key: &key,
        generation,
    }
    .hydrate(vec![event_id!("$must-not-fetch").to_owned()])
    .await;
    assert_eq!(candidates.len(), 1);
    assert!(!candidates[0].attempted);
    assert!(candidates[0].result.is_none());
    server.verify_and_reset().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn loaded_search_window_can_refresh_more_than_one_hundred_hits() {
    let server = MatrixMockServer::new().await;
    let client = server
        .client_builder()
        .on_builder(|builder| builder.search_index_store(SearchIndexStoreKind::InMemory))
        .build()
        .await;
    client.event_cache().subscribe().unwrap();
    let room_id = room_id!("!large-search-window:localhost");
    let events = EventFactory::new()
        .room(room_id)
        .sender(user_id!("@alice:localhost"));
    let mut builder = JoinedRoomBuilder::new(room_id);
    for index in 0..140u64 {
        let id =
            matrix_sdk::ruma::EventId::parse(format!("$large-window-{index}:localhost")).unwrap();
        builder = builder.add_timeline_event(
            events
                .text_msg("needle body")
                .event_id(&id)
                .server_ts((index + 1) * 1000),
        );
    }
    server.sync_room(&client, builder).await;
    let prefix = search_messages_with_client(
        &client,
        "needle".to_owned(),
        Some(room_id.to_string()),
        0,
        125,
        Some(Vec::new()),
    )
    .await
    .unwrap();
    assert_eq!(prefix.results.len(), 125);
    assert!(prefix.has_more);
    let tail = search_messages_with_client(
        &client,
        "needle".to_owned(),
        Some(room_id.to_string()),
        125,
        30,
        Some(Vec::new()),
    )
    .await
    .unwrap();
    assert_eq!(tail.results.len(), 15);
    assert!(!tail.has_more);
    let ids: HashSet<_> = prefix
        .results
        .iter()
        .chain(tail.results.iter())
        .map(|result| result.event_id.as_str())
        .collect();
    assert_eq!(ids.len(), 140);
    server.verify_and_reset().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn global_search_fetches_remote_history_after_its_cache_is_indexed() {
    let server = MatrixMockServer::new().await;
    let client = server
        .client_builder()
        .on_builder(|builder| builder.search_index_store(SearchIndexStoreKind::InMemory))
        .build()
        .await;
    client.event_cache().subscribe().unwrap();
    let room_id = room_id!("!global-search-history:localhost");
    let events = EventFactory::new()
        .room(room_id)
        .sender(user_id!("@alice:localhost"));
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id)
                .set_timeline_limited()
                .set_timeline_prev_batch("global-older")
                .add_timeline_event(
                    events
                        .text_msg("history match")
                        .event_id(event_id!("$global-new:localhost"))
                        .server_ts(2000),
                ),
        )
        .await;
    server
        .mock_room_messages()
        .match_from("global-older")
        .ok(RoomMessagesResponseTemplate::default().events(vec![events
            .text_msg("history match")
            .event_id(event_id!("$global-old:localhost"))
            .server_ts(1000)]))
        .mock_once()
        .mount()
        .await;
    // An in-memory client has no cache-backfill marker to migrate. Even
    // then, global search must not confuse cache completion with history.
    let before =
        search_messages_with_client(&client, "history".to_owned(), None, 0, 30, Some(Vec::new()))
            .await
            .unwrap();
    assert!(!before.history_complete);
    let progress = backfill_message_search_with_client(&client, None)
        .await
        .unwrap();
    assert_eq!(progress.loaded_events, 1);
    let after =
        search_messages_with_client(&client, "history".to_owned(), None, 0, 30, Some(Vec::new()))
            .await
            .unwrap();
    assert!(after
        .results
        .iter()
        .any(|result| result.event_id == "$global-old:localhost"));
    assert!(after.history_complete);
    let room = client.get_room(room_id).unwrap();
    SEARCH_HISTORY_COMPLETE
        .lock()
        .await
        .remove(&message_search_room_key(&client, &room).unwrap());
    server.verify_and_reset().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn room_search_returns_cached_results_before_progressively_loading_history() {
    let server = MatrixMockServer::new().await;
    let client = server
        .client_builder()
        .on_builder(|builder| builder.search_index_store(SearchIndexStoreKind::InMemory))
        .build()
        .await;
    client.event_cache().subscribe().unwrap();

    let room_id = room_id!("!search:localhost");
    let sender = user_id!("@alice:localhost");
    let events = EventFactory::new().room(room_id).sender(sender);
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id)
                .set_timeline_limited()
                .set_timeline_prev_batch("older")
                .add_state_event(events.room_encryption())
                .add_timeline_event(
                    events
                        .text_msg("歇逼")
                        .event_id(event_id!("$cached:localhost"))
                        .server_ts(5_000),
                ),
        )
        .await;

    server
        .mock_room_messages()
        .match_from("older")
        .ok(RoomMessagesResponseTemplate::default()
            .events(vec![
                events
                    .text_msg("歇逼")
                    .event_id(event_id!("$older1:localhost"))
                    .server_ts(4_000),
                events
                    .text_msg("歇逼")
                    .event_id(event_id!("$older2:localhost"))
                    .server_ts(3_000),
            ])
            .end_token("older-2"))
        .mock_once()
        .mount()
        .await;
    server
        .mock_room_messages()
        .match_from("older-2")
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            events
                .text_msg("歇逼")
                .event_id(event_id!("$older3:localhost"))
                .server_ts(2_000),
            events
                .text_msg("歇逼")
                .event_id(event_id!("$older4:localhost"))
                .server_ts(1_000),
        ]))
        .mock_once()
        .mount()
        .await;

    let cached_page = search_messages_with_client(
        &client,
        "歇逼".to_owned(),
        Some(room_id.to_string()),
        0,
        30,
        Some(Vec::new()),
    )
    .await
    .unwrap();
    assert_eq!(cached_page.results.len(), 1);
    assert_eq!(cached_page.results[0].event_id, "$cached:localhost");
    assert!(!cached_page.history_complete);

    let first_backfill = backfill_message_search_with_client(&client, Some(room_id.to_string()))
        .await
        .unwrap();
    assert_eq!(first_backfill.loaded_events, 2);
    assert!(!first_backfill.reached_start);
    let partial_page = search_messages_with_client(
        &client,
        "歇逼".to_owned(),
        Some(room_id.to_string()),
        0,
        30,
        Some(Vec::new()),
    )
    .await
    .unwrap();
    assert_eq!(partial_page.results.len(), 3);
    assert!(!partial_page.history_complete);

    let final_backfill = backfill_message_search_with_client(&client, Some(room_id.to_string()))
        .await
        .unwrap();
    assert_eq!(final_backfill.loaded_events, 2);
    assert!(final_backfill.reached_start);
    let complete_page = search_messages_with_client(
        &client,
        "歇逼".to_owned(),
        Some(room_id.to_string()),
        0,
        30,
        Some(Vec::new()),
    )
    .await
    .unwrap();
    assert!(complete_page.history_complete);
    let ordered_event_ids = complete_page
        .results
        .into_iter()
        .map(|result| result.event_id)
        .collect::<Vec<_>>();
    let event_ids = ordered_event_ids.iter().cloned().collect::<HashSet<_>>();

    assert_eq!(event_ids.len(), 5);
    assert!(event_ids.contains("$cached:localhost"));
    assert!(event_ids.contains("$older1:localhost"));
    assert!(event_ids.contains("$older2:localhost"));
    assert!(event_ids.contains("$older3:localhost"));
    assert!(event_ids.contains("$older4:localhost"));
    assert_eq!(
        ordered_event_ids,
        [
            "$cached:localhost",
            "$older1:localhost",
            "$older2:localhost",
            "$older3:localhost",
            "$older4:localhost",
        ]
    );
    server.verify_and_reset().await;
}
