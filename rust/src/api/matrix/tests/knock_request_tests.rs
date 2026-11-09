use super::knock_member_events_request;
use matrix_sdk::ruma::{events::room::member::MembershipState, room_id};

#[test]
fn knock_member_query_is_filtered_authoritatively() {
    let request = knock_member_events_request(room_id!("!room:example.org").to_owned());

    assert_eq!(request.membership, Some(MembershipState::Knock));
}
