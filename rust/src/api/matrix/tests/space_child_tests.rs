use matrix_sdk::{
    deserialized_responses::SyncOrStrippedState, ruma::events::space::child::SpaceChildEventContent,
};

use super::space_child_room_id;

fn sync_child_event(content: serde_json::Value) -> SyncOrStrippedState<SpaceChildEventContent> {
    SyncOrStrippedState::Sync(
        serde_json::from_value(serde_json::json!({
            "type": "m.space.child",
            "state_key": "!child:example.org",
            "sender": "@admin:example.org",
            "event_id": "$event:example.org",
            "origin_server_ts": 1,
            "content": content,
        }))
        .unwrap(),
    )
}

fn stripped_child_event(content: serde_json::Value) -> SyncOrStrippedState<SpaceChildEventContent> {
    SyncOrStrippedState::Stripped(
        serde_json::from_value(serde_json::json!({
            "type": "m.space.child",
            "state_key": "!child:example.org",
            "sender": "@admin:example.org",
            "content": content,
        }))
        .unwrap(),
    )
}

#[test]
fn child_with_via_is_grouped() {
    let expected = matrix_sdk::ruma::RoomId::parse("!child:example.org").unwrap();
    assert_eq!(
        space_child_room_id(sync_child_event(
            serde_json::json!({ "via": ["example.org"] })
        )),
        Some(expected.clone())
    );
    assert_eq!(
        space_child_room_id(stripped_child_event(
            serde_json::json!({ "via": ["example.org"] })
        )),
        Some(expected)
    );
}

#[test]
fn child_without_via_stays_ungrouped() {
    // Empty or missing via: the room must NOT be treated as grouped, so it
    // remains visible in get_ungrouped_rooms (and out of get_space_children).
    assert_eq!(
        space_child_room_id(sync_child_event(serde_json::json!({ "via": [] }))),
        None
    );
    assert_eq!(
        space_child_room_id(stripped_child_event(serde_json::json!({ "via": [] }))),
        None
    );
    assert_eq!(
        space_child_room_id(stripped_child_event(serde_json::json!({}))),
        None
    );
}
