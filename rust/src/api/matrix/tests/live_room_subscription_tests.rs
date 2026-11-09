use super::live_room_subscription;
use matrix_sdk::ruma::events::StateEventType;

#[test]
fn requests_pinned_event_state() {
    let subscription = live_room_subscription();

    assert_eq!(
        subscription.required_state,
        vec![(StateEventType::RoomPinnedEvents, String::new())]
    );
}
