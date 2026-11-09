use std::sync::Arc;
use tokio::sync::{oneshot, RwLock};

#[tokio::test]
async fn account_transition_drains_and_blocks_sync_admissions() {
    let lifecycle = Arc::new(RwLock::new(()));
    let running_sync = lifecycle.read().await;
    let transition_lifecycle = lifecycle.clone();
    let (transition_acquired_tx, transition_acquired_rx) = oneshot::channel();
    let (release_transition_tx, release_transition_rx) = oneshot::channel();

    let transition = tokio::spawn(async move {
        let _transition = transition_lifecycle.write().await;
        let _ = transition_acquired_tx.send(());
        let _ = release_transition_rx.await;
    });

    tokio::task::yield_now().await;
    drop(running_sync);
    transition_acquired_rx.await.unwrap();

    let waiting_sync_lifecycle = lifecycle.clone();
    let waiting_sync = tokio::spawn(async move {
        let _sync = waiting_sync_lifecycle.read().await;
    });
    tokio::task::yield_now().await;
    assert!(!waiting_sync.is_finished());

    let _ = release_transition_tx.send(());
    transition.await.unwrap();
    waiting_sync.await.unwrap();
}
