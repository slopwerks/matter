use super::{take_typing_task_for_owner, TypingTask};

#[tokio::test]
async fn stale_unsubscribe_does_not_cancel_a_newer_owner() {
    let handle = tokio::spawn(std::future::pending());
    let mut task = Some(TypingTask {
        room_id: "!current:example.org".to_string(),
        subscription_id: "new-owner".to_string(),
        handle,
    });

    assert!(take_typing_task_for_owner(&mut task, "!current:example.org", "old-owner",).is_none());
    assert_eq!(task.as_ref().unwrap().room_id, "!current:example.org");
    assert_eq!(task.as_ref().unwrap().subscription_id, "new-owner",);

    task.take().unwrap().handle.abort();
}
