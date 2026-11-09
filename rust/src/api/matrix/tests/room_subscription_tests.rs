use super::{
    lock_subscription_state, receipt_extension_for_subscribed_rooms, subscription_user_matches,
    RoomSubscriptionState,
};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};

fn state() -> RoomSubscriptionState {
    RoomSubscriptionState {
        desired: HashMap::new(),
        active: None,
        active_generation: None,
    }
}

#[test]
fn duplicate_routes_only_unsubscribe_after_the_last_owner() {
    let mut state = state();
    assert!(state.add_desired("!room:example.org", "first".to_owned()));
    assert!(!state.add_desired("!room:example.org", "second".to_owned()));
    assert!(!state.remove_desired("!room:example.org", "first"));
    assert!(state.desired.contains_key("!room:example.org"));
    assert!(state.remove_desired("!room:example.org", "second"));
    assert!(!state.desired.contains_key("!room:example.org"));
}

#[test]
fn stacked_rooms_are_tracked_independently() {
    let mut state = state();
    assert!(state.add_desired("!first:example.org", "first".to_owned()));
    assert!(state.add_desired("!second:example.org", "second".to_owned()));
    assert!(state.remove_desired("!second:example.org", "second"));
    assert!(state.desired.contains_key("!first:example.org"));
}

#[test]
fn receipt_extension_requests_all_subscribed_rooms() {
    assert_eq!(
        serde_json::to_value(receipt_extension_for_subscribed_rooms()).unwrap(),
        serde_json::json!({"enabled": true, "rooms": ["*"]}),
    );
}

#[test]
fn sync_restart_preserves_subscriptions_registered_before_start() {
    let mut state = state();
    state.add_desired("!room:example.org", "owner".to_owned());

    state.reset(true);

    assert!(state.desired.contains_key("!room:example.org"));
}

#[test]
fn account_change_clears_old_account_subscriptions() {
    let mut state = state();
    state.add_desired("!room:example.org", "old-owner".to_owned());

    state.reset(false);

    assert!(state.desired.is_empty());
}

#[test]
fn stale_owner_cannot_unsubscribe_a_new_account_route() {
    let mut state = state();
    state.add_desired("!room:example.org", "old-owner".to_owned());
    state.reset(false);
    state.add_desired("!room:example.org", "new-owner".to_owned());

    assert!(!state.remove_desired("!room:example.org", "old-owner"));
    assert!(state.desired.contains_key("!room:example.org"));
}

#[test]
fn stale_account_cannot_register_after_a_switch() {
    assert!(!subscription_user_matches(
        Some("@bob:example.org"),
        Some("@alice:example.org"),
    ));
    assert!(subscription_user_matches(
        Some("@bob:example.org"),
        Some("@bob:example.org"),
    ));
}

#[test]
fn stale_sync_cannot_clear_a_newer_published_generation() {
    let mut state = state();
    state.active_generation = Some(2);

    state.clear_active_for_generation(1);
    assert_eq!(state.active_generation, Some(2));

    state.clear_active_for_generation(2);
    assert_eq!(state.active_generation, None);
}

#[tokio::test]
async fn queued_account_writer_does_not_deadlock_subscription_registration() {
    let user = Arc::new(RwLock::new(Some("@alice:example.org".to_string())));
    let state = Arc::new(Mutex::new(()));
    let held_state = state.lock().await;

    let registration = {
        let user = user.clone();
        let state = state.clone();
        tokio::spawn(async move {
            let guards =
                lock_subscription_state(&user, &state, Some("@alice:example.org"), "inactive")
                    .await
                    .unwrap();
            drop(guards);
        })
    };
    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        while let Ok(guard) = user.try_write() {
            drop(guard);
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("registration must acquire the subscription-user read lock");

    let writer = {
        let user = user.clone();
        tokio::spawn(async move {
            *user.write().await = Some("@bob:example.org".to_string());
        })
    };
    tokio::task::yield_now().await;
    drop(held_state);

    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        registration.await.unwrap();
        writer.await.unwrap();
    })
    .await
    .expect("subscription registration and queued writer must complete");
}
