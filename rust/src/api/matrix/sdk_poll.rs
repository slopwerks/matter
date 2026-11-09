//! Sdk poll adaptation.
use super::*;

/// Build a [ChatMessage] from a poll timeline item. Polls use the unstable
/// `org.matrix.msc3381.*` event type, surfaced as [MsgLikeKind::Poll].
#[allow(clippy::too_many_arguments)]
pub(in crate::api::matrix) fn poll_message(
    event_id: String,
    sender_id: String,
    sender_name: String,
    timestamp: String,
    is_me: bool,
    in_reply_to: Option<String>,
    state: &matrix_sdk_ui::timeline::PollState,
    my_user_id: Option<&str>,
) -> Option<ChatMessage> {
    let result = state.results();

    let answers = result
        .answers
        .into_iter()
        .map(|answer| PollAnswerInfo {
            id: answer.id,
            text: answer.text,
        })
        .collect::<Vec<_>>();
    if answers.is_empty() {
        return None;
    }

    let disclosed = result.kind == matrix_sdk::ruma::events::poll::start::PollKind::Disclosed;
    let ended = result.end_time.is_some();
    // Aggregate per-answer tallies and detect the current user's selections.
    let mut my_answer_ids = Vec::new();
    let mut tally: HashMap<&str, i32> = HashMap::new();
    let mut voters: HashMap<&str, ()> = HashMap::new();
    for (answer_id, voters_for_answer) in &result.votes {
        let count = i32::try_from(voters_for_answer.len()).unwrap_or(i32::MAX);
        tally.insert(answer_id.as_str(), count);
        for voter in voters_for_answer {
            voters.insert(voter.as_str(), ());
            if Some(voter.as_str()) == my_user_id {
                my_answer_ids.push(answer_id.clone());
            }
        }
    }

    let results = answers
        .iter()
        .map(|answer| PollAnswerResult {
            answer_id: answer.id.clone(),
            count: *tally.get(answer.id.as_str()).unwrap_or(&0),
            is_mine: my_answer_ids.iter().any(|id| id == &answer.id),
        })
        .collect::<Vec<_>>();

    let mut message = base_message(
        &event_id,
        &sender_id,
        &sender_name,
        &timestamp,
        is_me,
        result.question.clone(),
        None,
        Vec::new(),
        false,
        MessageType::Poll,
        in_reply_to,
    );
    message.poll = Some(PollInfo {
        question: result.question,
        answers,
        disclosed,
        max_selections: i32::try_from(result.max_selections).unwrap_or(i32::MAX),
        my_answer_ids,
        results,
        total_voters: i32::try_from(voters.len()).unwrap_or(i32::MAX),
        ended,
    });
    Some(message)
}
