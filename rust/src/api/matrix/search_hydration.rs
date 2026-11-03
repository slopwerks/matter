//! Request-scoped search hydration: cheap cache hits, bounded remote misses.

use std::{
    collections::{HashMap, HashSet},
    time::Instant,
};

use futures_util::{
    future::{BoxFuture, FutureExt, Shared},
    stream, StreamExt,
};
use matrix_sdk::{
    deserialized_responses::TimelineEvent,
    ruma::{OwnedEventId, UserId},
    Client, Room,
};
use tokio::sync::Mutex;

use super::{app_log, message_search_is_current, search_result_from_event, MessageSearchResult};

const CONCURRENCY: usize = 8;
pub(super) type HydratedResult = (MessageSearchResult, u64, String);

pub(super) struct SenderNames {
    names: Mutex<HashMap<String, Shared<BoxFuture<'static, String>>>>,
}

impl SenderNames {
    pub(super) fn new() -> Self {
        Self {
            names: Mutex::new(HashMap::new()),
        }
    }

    pub(super) async fn get(&self, room: &Room, sender: &UserId) -> String {
        let future = {
            let mut names = self.names.lock().await;
            names
                .entry(sender.to_string())
                .or_insert_with(|| {
                    let room = room.clone();
                    let sender = sender.to_owned();
                    async move {
                        room.get_member_no_sync(&sender)
                            .await
                            .ok()
                            .flatten()
                            .map(|member| member.name().to_owned())
                            .unwrap_or_else(|| sender.localpart().to_owned())
                    }
                    .boxed()
                    .shared()
                })
                .clone()
        };
        future.await
    }
}

pub(super) struct Candidate {
    pub(super) result: Option<HydratedResult>,
    pub(super) hydration_us: u64,
    pub(super) conversion_us: u64,
    pub(super) attempted: bool,
    pub(super) cache_hit: bool,
    pub(super) remote_fetch: bool,
}

impl Candidate {
    fn cancelled() -> Self {
        Self {
            result: None,
            hydration_us: 0,
            conversion_us: 0,
            attempted: false,
            cache_hit: false,
            remote_fetch: false,
        }
    }
}

pub(super) struct HydrationContext<'a> {
    pub(super) client: &'a Client,
    pub(super) room: &'a Room,
    pub(super) terms: &'a [String],
    pub(super) ignored: Option<&'a HashSet<String>>,
    pub(super) is_dm: bool,
    pub(super) sender_names: &'a SenderNames,
    pub(super) search_key: &'a str,
    pub(super) generation: u64,
}

impl HydrationContext<'_> {
    async fn current(&self) -> bool {
        message_search_is_current(self.search_key, self.generation).await
    }

    async fn convert(&self, event: TimelineEvent, hydration_us: u64, cached: bool) -> Candidate {
        let converting = Instant::now();
        let result = search_result_from_event(
            self.client,
            self.room,
            event,
            self.terms,
            self.ignored,
            self.is_dm,
            self.sender_names,
        )
        .await;
        Candidate {
            result,
            hydration_us,
            conversion_us: converting.elapsed().as_micros().min(u64::MAX as u128) as u64,
            attempted: true,
            cache_hit: cached,
            remote_fetch: !cached,
        }
    }

    pub(super) async fn hydrate(&self, ids: Vec<OwnedEventId>) -> Vec<Candidate> {
        let mut results = Vec::with_capacity(ids.len());
        let mut missing = Vec::new();
        if !self.current().await {
            return ids.iter().map(|_| Candidate::cancelled()).collect();
        }
        let cache_handle = self.room.event_cache().await.ok();
        let cache = cache_handle.as_ref().map(|(cache, _)| cache);
        for id in ids {
            if !self.current().await {
                results.push(Candidate::cancelled());
                continue;
            }
            let started = Instant::now();
            let cached = match cache {
                Some(cache) => cache.find_event(&id).await.map_err(matrix_sdk::Error::from),
                None => Ok(None),
            };
            let hydration_us = started.elapsed().as_micros().min(u64::MAX as u128) as u64;
            match cached {
                Ok(Some(event)) => results.push(self.convert(event, hydration_us, true).await),
                Ok(None) => missing.push((id, hydration_us)),
                Err(error) => {
                    app_log(
                        "warn",
                        "search",
                        format!("Skipping unavailable cached search result {id}: {error}"),
                    );
                    results.push(Candidate {
                        result: None,
                        hydration_us,
                        conversion_us: 0,
                        attempted: true,
                        cache_hit: false,
                        remote_fetch: false,
                    });
                }
            }
        }
        let fetched = stream::iter(missing)
            .map(|(id, cache_us)| async move {
                if !self.current().await {
                    return Candidate::cancelled();
                }
                let started = Instant::now();
                match self.room.event(&id, None).await {
                    Ok(event) => {
                        self.convert(
                            event,
                            cache_us + started.elapsed().as_micros().min(u64::MAX as u128) as u64,
                            false,
                        )
                        .await
                    }
                    Err(error) => {
                        app_log(
                            "warn",
                            "search",
                            format!("Skipping unavailable search result {id}: {error}"),
                        );
                        Candidate {
                            result: None,
                            hydration_us: cache_us
                                + started.elapsed().as_micros().min(u64::MAX as u128) as u64,
                            conversion_us: 0,
                            attempted: true,
                            cache_hit: false,
                            remote_fetch: true,
                        }
                    }
                }
            })
            .buffer_unordered(CONCURRENCY)
            .collect::<Vec<_>>()
            .await;
        // Remote fallbacks are deliberately not saved, matching the SDK's
        // load_or_fetch_event contract and avoiding EventCache lock cycles.
        results.extend(fetched);
        results
    }
}
