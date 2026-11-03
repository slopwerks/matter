//! Reproducible lab profile of the production search path, not a phone benchmark.

use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};

use matrix_sdk::{
    ruma::{user_id, EventId, RoomId},
    search_index::SearchIndexStoreKind,
    test_utils::mocks::{MatrixMockServer, RoomMessagesResponseTemplate},
};
use matrix_sdk_test::{event_factory::EventFactory, JoinedRoomBuilder};
use serde::Serialize;

use super::{
    backfill_message_search_with_client, search_messages_with_client, search_metrics, ClientEntry,
    CLIENTS, SEARCH_CACHE_BACKFILL_PROGRESS, SEARCH_HISTORY_COMPLETE,
};

#[derive(Serialize)]
struct Sample {
    scenario: String,
    total_ms: f64,
    first_results_ms: f64,
    result_count: usize,
    raw_history_events: usize,
    phases_us: BTreeMap<String, u64>,
    work: BTreeMap<String, usize>,
}

fn sample(
    scenario: String,
    started: Instant,
    first_results_ms: f64,
    result_count: usize,
    raw_history_events: usize,
) -> Sample {
    let mut phases_us = BTreeMap::new();
    let mut work = BTreeMap::new();
    for report in search_metrics::take_reports() {
        for (phase, value) in report.phases_us {
            *phases_us
                .entry(format!("{}.{}", report.operation, phase))
                .or_default() += value;
        }
        for (count, value) in report.counts {
            *work
                .entry(format!("{}.{}", report.operation, count))
                .or_default() += value;
        }
    }
    Sample {
        scenario,
        total_ms: started.elapsed().as_secs_f64() * 1000.0,
        first_results_ms,
        result_count,
        raw_history_events,
        phases_us,
        work,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn search_performance_profile() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join(".pi");
    std::fs::create_dir_all(&root).unwrap();
    let mut samples = Vec::new();
    for rooms in [1, 4] {
        for repeat in 0..3 {
            let directory = tempfile::tempdir_in(&root).unwrap();
            let index_dir = directory.path().join("search-index");
            let server = MatrixMockServer::new().await;
            let client = server
                .client_builder()
                .on_builder(|builder| {
                    builder.search_index_store(SearchIndexStoreKind::EncryptedDirectory(
                        index_dir.clone(),
                        "lab-profile-password".to_owned(),
                    ))
                })
                .build()
                .await;
            client.event_cache().subscribe().unwrap();
            let user_id = client.user_id().unwrap().to_string();
            assert!(!CLIENTS.read().await.contains_key(&user_id));
            CLIENTS.write().await.insert(
                user_id.clone(),
                ClientEntry {
                    client: client.clone(),
                    data_dir: directory.path().display().to_string(),
                    search_index_dir: index_dir,
                    instance_id: 0,
                    room_key_task: tokio::spawn(std::future::pending()),
                },
            );
            let mut room_ids = Vec::new();
            for room_index in 0..rooms {
                let room_id =
                    RoomId::parse(format!("!search-profile-{repeat}-{room_index}:localhost"))
                        .unwrap();
                let events = EventFactory::new()
                    .room(&room_id)
                    .sender(user_id!("@alice:localhost"));
                let token = format!("profile-{repeat}-{room_index}-0");
                let mut builder = JoinedRoomBuilder::new(&room_id)
                    .set_timeline_limited()
                    .set_timeline_prev_batch(&token);
                for event_index in 500..520 {
                    builder = builder.add_timeline_event(
                        events
                            .text_msg("recent unrelated message")
                            .event_id(
                                &EventId::parse(format!(
                                    "$profile-{repeat}-{room_index}-{event_index}:localhost"
                                ))
                                .unwrap(),
                            )
                            .server_ts(1000000 + event_index),
                    );
                }
                server.sync_room(&client, builder).await;
                for page in 0..2 {
                    let from = format!("profile-{repeat}-{room_index}-{page}");
                    let mut response = RoomMessagesResponseTemplate::default()
                        .with_delay(Duration::from_millis(20));
                    response = response.events((0..250).map(|index| {
                        let event_index = 499 - (page * 250 + index);
                        let body = if event_index % 5 == 0 { "needle matching historical message" } else { "unrelated historical message" };
                        events.text_msg(body)
                            .event_id(&EventId::parse(format!("$profile-{repeat}-{room_index}-{event_index}:localhost")).unwrap())
                            .server_ts(1000000 + event_index)
                            .into_raw()
                    }).collect::<Vec<_>>());
                    if page == 0 {
                        response = response.end_token(format!("profile-{repeat}-{room_index}-1"));
                    }
                    server
                        .mock_room_messages()
                        .match_from(&from)
                        .ok(response)
                        .mock_once()
                        .mount()
                        .await;
                }
                room_ids.push(room_id);
            }
            let scope = if rooms == 1 {
                Some(room_ids[0].to_string())
            } else {
                None
            };
            let kind = if rooms == 1 { "room" } else { "global" };
            search_metrics::take_reports();
            let started = Instant::now();
            let mut page = search_messages_with_client(
                &client,
                "needle".to_owned(),
                scope.clone(),
                0,
                30,
                Some(Vec::new()),
            )
            .await
            .unwrap();
            assert!(page.results.is_empty());
            let mut first_results = None;
            let mut loaded = 0usize;
            let mut steps = 0;
            while !page.history_complete {
                let progress = backfill_message_search_with_client(&client, scope.clone())
                    .await
                    .unwrap();
                loaded += progress.loaded_events as usize;
                page = search_messages_with_client(
                    &client,
                    "needle".to_owned(),
                    scope.clone(),
                    0,
                    30,
                    Some(Vec::new()),
                )
                .await
                .unwrap();
                if !page.results.is_empty() && first_results.is_none() {
                    first_results = Some(started.elapsed().as_secs_f64() * 1000.0);
                }
                steps += 1;
                assert!(steps <= 32, "history backfill did not complete");
            }
            assert_eq!(page.results.len(), 30);
            assert!(page.has_more);
            samples.push(sample(
                format!("{kind}_cold"),
                started,
                first_results.unwrap(),
                page.results.len(),
                loaded,
            ));
            for _ in 0..3 {
                search_metrics::take_reports();
                let started = Instant::now();
                let warm = search_messages_with_client(
                    &client,
                    "needle".to_owned(),
                    scope.clone(),
                    0,
                    30,
                    Some(Vec::new()),
                )
                .await
                .unwrap();
                assert_eq!(warm.results.len(), 30);
                assert!(warm.history_complete);
                samples.push(sample(
                    format!("{kind}_warm"),
                    started,
                    started.elapsed().as_secs_f64() * 1000.0,
                    warm.results.len(),
                    0,
                ));
            }
            server.verify_and_reset().await;
            let prefix = format!("{user_id}\n");
            SEARCH_HISTORY_COMPLETE
                .lock()
                .await
                .retain(|key| !key.starts_with(&prefix));
            SEARCH_CACHE_BACKFILL_PROGRESS
                .lock()
                .await
                .retain(|key, _| !key.starts_with(&prefix));
            if let Some(entry) = CLIENTS.write().await.remove(&user_id) {
                entry.room_key_task.abort();
            }
        }
    }
    let report = serde_json::json!({
        "fixture": {"rooms": [1, 4], "history_events_per_room": 500, "matching_every": 5, "mock_network_delay_ms": 20, "repetitions": 3, "index": "encrypted local directory", "event_payloads": "plaintext fixtures; no real E2EE decryption timing", "cold": "history not cached/indexed; not an OS page-cache flush"},
        "samples": samples,
    });
    if let Ok(path) = std::env::var("MATTER_SEARCH_PERF_OUTPUT") {
        std::fs::write(path, serde_json::to_vec_pretty(&report).unwrap()).unwrap();
    }
    println!(
        "SEARCH_PERF_RESULT {}",
        serde_json::to_string(&report).unwrap()
    );
}
