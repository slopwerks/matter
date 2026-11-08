//! Sync events implementation.

use super::*;

pub(super) fn notify_sync_event(event: SyncEvent) {
    let _ = SYNC_EVENT_TX.send(event);
}

/// Failure accounting for a Sliding Sync stream that ended on its own
/// (the server closed the connection without an error). A round that
/// delivered at least one update counts as a success — the Ok branch
/// already reset the counter — while a stream that ended without any
/// update counts as a failure, like the Err branch.
pub(super) fn failures_after_stream_end(consecutive_failures: u32, received_update: bool) -> u32 {
    if received_update {
        consecutive_failures
    } else {
        consecutive_failures + 1
    }
}

pub(super) fn lagged_sync_event() -> SyncEvent {
    SyncEvent::FullRefreshRequired
}

/// The connection status to report while the sync loop is between retries.
///
/// The first consecutive failure reports [`ConnectionStatus::Connecting`]
/// — the UI label reads it as "reconnecting" — and only repeated failures
/// mean the connection is actually down.
pub(super) fn sync_retry_status(consecutive_failures: u32) -> ConnectionStatus {
    if consecutive_failures >= SYNC_OFFLINE_AFTER_FAILURES {
        ConnectionStatus::Disconnected
    } else {
        ConnectionStatus::Connecting
    }
}

/// Back-off before the next retry: near-immediate on the first failure so a
/// transient drop recovers without a visible outage window, slower after.
pub(super) fn sync_retry_delay(consecutive_failures: u32) -> std::time::Duration {
    if consecutive_failures <= 1 {
        std::time::Duration::from_secs(1)
    } else {
        std::time::Duration::from_secs(5)
    }
}

pub(super) fn watch_sync_events(sink: crate::frb_generated::StreamSink<SyncEvent>) {
    let mut rx = SYNC_EVENT_TX.subscribe();
    std::thread::spawn(move || {
        loop {
            match rx.blocking_recv() {
                Ok(event) => {
                    if sink.add(event).is_err() {
                        break; // Dart side disconnected
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    // Dart can be paused while the app is backgrounded. A
                    // synthetic full refresh catches it up without killing
                    // the only Rust -> Dart update bridge.
                    if sink.add(lagged_sync_event()).is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}
