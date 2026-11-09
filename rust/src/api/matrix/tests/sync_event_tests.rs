use super::{
    failures_after_stream_end, lagged_sync_event, sync_retry_delay, sync_retry_status,
    ConnectionStatus, SyncEvent, DEGRADE_AFTER_FAILURES, SYNC_EVENT_GENERATION,
};

#[test]
fn lagged_receivers_request_a_full_refresh() {
    assert!(matches!(
        lagged_sync_event(),
        SyncEvent::FullRefreshRequired
    ));
}

#[test]
fn stream_end_without_updates_accumulates_failures_until_degrade() {
    let mut consecutive_failures = 0;
    for expected in 1..=DEGRADE_AFTER_FAILURES {
        consecutive_failures = failures_after_stream_end(consecutive_failures, false);
        assert_eq!(consecutive_failures, expected);
    }
    // After DEGRADE_AFTER_FAILURES dataless stream ends, the loop's
    // degrade check fires and hands over to traditional sync.
    assert!(consecutive_failures >= DEGRADE_AFTER_FAILURES);
}

#[test]
fn stream_end_after_updates_keeps_the_reset_counter() {
    // The Ok(summary) branch already reset the counter this round, so a
    // stream that delivered updates and then ended is not a failure.
    assert_eq!(failures_after_stream_end(0, true), 0);
}

#[tokio::test]
async fn sync_event_generation_is_bound_to_the_processing_future() {
    assert!(SYNC_EVENT_GENERATION.try_with(|_| ()).is_err());

    let generation = SYNC_EVENT_GENERATION
        .scope(42, async {
            SYNC_EVENT_GENERATION
                .try_with(|generation| *generation)
                .unwrap()
        })
        .await;

    assert_eq!(generation, 42);
    assert!(SYNC_EVENT_GENERATION.try_with(|_| ()).is_err());
}

#[test]
fn single_sync_failure_reports_reconnecting_not_offline() {
    // A fresh counter or the first failure is "reconnecting"…
    assert!(matches!(sync_retry_status(0), ConnectionStatus::Connecting));
    assert!(matches!(sync_retry_status(1), ConnectionStatus::Connecting));
    // …only repeated consecutive failures mean the connection is down.
    assert!(matches!(
        sync_retry_status(2),
        ConnectionStatus::Disconnected
    ));
    assert!(matches!(
        sync_retry_status(DEGRADE_AFTER_FAILURES),
        ConnectionStatus::Disconnected
    ));
}

#[test]
fn first_retry_is_quick_then_backs_off() {
    assert_eq!(sync_retry_delay(0), std::time::Duration::from_secs(1));
    assert_eq!(sync_retry_delay(1), std::time::Duration::from_secs(1));
    assert_eq!(sync_retry_delay(2), std::time::Duration::from_secs(5));
}
