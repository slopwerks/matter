//! Search operation regressions for the vendor fast path, through public APIs.

use matrix_sdk::ruma::{event_id, room_id, user_id};
use matrix_sdk_search::index::{builder::RoomIndexBuilder, IndexableEvent, RoomIndexOperation};

fn original() -> IndexableEvent {
    IndexableEvent::new(
        event_id!("$original").to_owned(),
        event_id!("$original").to_owned(),
        user_id!("@alice:localhost").to_owned(),
        None,
        "alpha original".to_owned(),
    )
}

fn edited() -> IndexableEvent {
    IndexableEvent::new(
        event_id!("$edit").to_owned(),
        event_id!("$original").to_owned(),
        user_id!("@alice:localhost").to_owned(),
        None,
        "beta replacement".to_owned(),
    )
}

#[test]
fn message_search_index_duplicate_batches_remain_immediately_visible() {
    let mut index = RoomIndexBuilder::new_in_memory(room_id!("!duplicate:localhost")).build();
    index.bulk_execute(Vec::new()).unwrap();
    index.execute(RoomIndexOperation::Noop).unwrap();
    index
        .bulk_execute(vec![
            RoomIndexOperation::Add(original()),
            RoomIndexOperation::Add(original()),
        ])
        .unwrap();
    assert_eq!(index.search("alpha", 100, None).unwrap().len(), 1);
    for _ in 0..4 {
        index
            .bulk_execute(vec![
                RoomIndexOperation::Noop,
                RoomIndexOperation::Add(original()),
            ])
            .unwrap();
        assert_eq!(index.search("alpha", 100, None).unwrap().len(), 1);
    }
}

#[test]
fn message_search_index_fast_path_preserves_edit_remove_readd_order() {
    let mut index = RoomIndexBuilder::new_in_memory(room_id!("!mutations:localhost")).build();
    index
        .bulk_execute(vec![
            RoomIndexOperation::Add(original()),
            RoomIndexOperation::Edit(event_id!("$original").to_owned(), edited()),
        ])
        .unwrap();
    assert!(index.search("alpha", 100, None).unwrap().is_empty());
    assert_eq!(index.search("beta", 100, None).unwrap().len(), 1);
    index
        .bulk_execute(vec![
            RoomIndexOperation::Add(edited()),
            RoomIndexOperation::Noop,
        ])
        .unwrap();
    assert_eq!(index.search("beta", 100, None).unwrap().len(), 1);
    index
        .bulk_execute(vec![
            RoomIndexOperation::Remove(event_id!("$original").to_owned()),
            RoomIndexOperation::Add(original()),
        ])
        .unwrap();
    assert!(index.search("beta", 100, None).unwrap().is_empty());
    assert_eq!(index.search("alpha", 100, None).unwrap().len(), 1);
    index
        .execute(RoomIndexOperation::Remove(
            event_id!("$original").to_owned(),
        ))
        .unwrap();
    assert!(index.search("alpha", 100, None).unwrap().is_empty());
}
