use super::live_room_subscription;
use matrix_sdk::ruma::events::StateEventType;

#[test]
fn requests_pins_and_all_pack_state_keys() {
    let subscription = live_room_subscription();

    assert_eq!(
        subscription.required_state,
        vec![
            (StateEventType::RoomPinnedEvents, String::new()),
            ("m.room.image_pack".into(), "*".to_owned()),
            ("im.ponies.room_emotes".into(), "*".to_owned())
        ]
    );
}
