//! Polls implementation.

use super::*;

/// Build a validated unstable poll start event with a plain-text fallback.
pub(super) fn poll_start_content(
    question: &str,
    answers: Vec<String>,
    disclosed: bool,
    max_selections: usize,
) -> Result<matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent, String> {
    use matrix_sdk::ruma::events::poll::{
        start::PollKind,
        unstable_start::{
            NewUnstablePollStartEventContent, UnstablePollAnswer, UnstablePollAnswers,
            UnstablePollStartContentBlock,
        },
    };

    let question = question.trim();
    if question.is_empty() {
        return Err(api_err(
            "rooms",
            "A poll question cannot be empty.".to_string(),
        ));
    }

    let mut answer_list = Vec::with_capacity(answers.len());
    for label in answers {
        let label = label.trim();
        if label.is_empty() {
            continue;
        }
        answer_list.push(UnstablePollAnswer::new(
            answer_list.len().to_string(),
            label,
        ));
    }
    if !(2..=20).contains(&answer_list.len()) {
        return Err(api_err(
            "rooms",
            "A poll needs between 2 and 20 answers.".to_string(),
        ));
    }
    if !(1..=answer_list.len()).contains(&max_selections) {
        return Err(api_err(
            "rooms",
            "A poll's maximum selections must match its answers.".to_string(),
        ));
    }
    let mut fallback = question.to_owned();
    for (index, answer) in answer_list.iter().enumerate() {
        fallback.push_str(&format!("\n{}. {}", index + 1, answer.text));
    }
    let poll_answers = UnstablePollAnswers::try_from(answer_list).map_err(|_| {
        api_err(
            "rooms",
            "A poll needs between 2 and 20 answers.".to_string(),
        )
    })?;

    let mut poll_start = UnstablePollStartContentBlock::new(question, poll_answers);
    poll_start.kind = if disclosed {
        PollKind::Disclosed
    } else {
        PollKind::Undisclosed
    };
    poll_start.max_selections = matrix_sdk::ruma::UInt::from(max_selections as u32);
    Ok(NewUnstablePollStartEventContent::plain_text(fallback, poll_start).into())
}

pub(super) async fn send_poll(
    account_user_id: String,
    room_id: String,
    question: String,
    answers: Vec<String>,
    disclosed: bool,
    max_selections: i32,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let max_selections = usize::try_from(max_selections).map_err(|_| {
        api_err(
            "rooms",
            "A poll's maximum selections must be positive.".to_string(),
        )
    })?;
    let content = poll_start_content(&question, answers, disclosed, max_selections)?;

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send poll failed: {e}")))?;

    app_log("info", "rooms", format!("Poll message sent to {}", room_id));
    info!("Poll message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}

pub(super) fn validate_poll_answer_ids(answer_ids: &[String]) -> Result<(), String> {
    if answer_ids.is_empty()
        || answer_ids.len() > 20
        || answer_ids.iter().any(|answer_id| answer_id.is_empty())
        || answer_ids.iter().collect::<BTreeSet<_>>().len() != answer_ids.len()
    {
        return Err(api_err(
            "rooms",
            "A poll response needs 1 to 20 unique answer ids.".to_string(),
        ));
    }
    Ok(())
}

pub(super) async fn send_poll_response(
    room_id: String,
    poll_start_event_id: String,
    answer_ids: Vec<String>,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    use matrix_sdk::ruma::events::poll::unstable_response::UnstablePollResponseEventContent;

    validate_poll_answer_ids(&answer_ids)?;
    let event_id = matrix_sdk::ruma::EventId::parse(poll_start_event_id.as_str())
        .map_err(|e| api_err("rooms", format!("Invalid poll event id: {e}")))?;

    let content = UnstablePollResponseEventContent::new(answer_ids, event_id);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send poll response failed: {e}")))?;

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}

pub(super) async fn end_poll(room_id: String, poll_start_event_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    use matrix_sdk::ruma::events::poll::unstable_end::UnstablePollEndEventContent;

    let event_id = matrix_sdk::ruma::EventId::parse(poll_start_event_id.as_str())
        .map_err(|e| api_err("rooms", format!("Invalid poll event id: {e}")))?;

    let content = UnstablePollEndEventContent::new("结束投票", event_id);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("End poll failed: {e}")))?;

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}
