//! Message content implementation.

use super::*;

/// Strip the Matrix reply fallback prefix from a message body.
/// Matrix replies include a fallback like:
///   > <@user:server> Original message
///
///   Actual reply
/// We strip the leading `> <...>` line and the blank separator line.
pub(super) fn strip_reply_fallback(body: &str) -> String {
    if let Some(rest) = body.strip_prefix("> <") {
        if let Some(line_end) = rest.find('\n') {
            let after_first_line = &rest[line_end + 1..];
            if let Some(rest) = after_first_line.strip_prefix('\n') {
                return rest.to_string();
            }
            if let Some(after_crlf) = after_first_line.strip_prefix("\r\n") {
                if let Some(rest) = after_crlf.strip_prefix('\n') {
                    return rest.to_string();
                }
                if let Some(rest) = after_crlf.strip_prefix("\r\n") {
                    return rest.to_string();
                }
            }
        }
    }
    body.to_string()
}

pub(super) fn sanitized_formatted_body(
    formatted: Option<&matrix_sdk::ruma::events::room::message::FormattedBody>,
) -> Option<String> {
    let formatted = formatted?;
    if !matches!(
        &formatted.format,
        matrix_sdk::ruma::events::room::message::MessageFormat::Html
    ) {
        return None;
    }
    let html = matrix_sdk::ruma::html::sanitize_html(
        &formatted.body,
        matrix_sdk::ruma::html::HtmlSanitizerMode::Compat,
        matrix_sdk::ruma::html::RemoveReplyFallback::No,
    );
    (!html.trim().is_empty()).then_some(html)
}

pub(super) fn sanitized_reply_formatted_body(
    formatted: Option<&matrix_sdk::ruma::events::room::message::FormattedBody>,
) -> Option<String> {
    let formatted = formatted?;
    if !matches!(
        &formatted.format,
        matrix_sdk::ruma::events::room::message::MessageFormat::Html
    ) {
        return None;
    }
    let html = matrix_sdk::ruma::html::sanitize_html(
        &formatted.body,
        matrix_sdk::ruma::html::HtmlSanitizerMode::Compat,
        matrix_sdk::ruma::html::RemoveReplyFallback::Yes,
    );
    (!html.trim().is_empty()).then_some(html)
}

pub(super) fn media_caption_parts(
    formatted: Option<&matrix_sdk::ruma::events::room::message::FormattedBody>,
    fallback: Option<&str>,
) -> (Option<String>, Option<String>) {
    let caption = fallback
        .map(str::trim)
        .filter(|caption| !caption.is_empty())
        .map(ToString::to_string);
    (caption, sanitized_formatted_body(formatted))
}

pub(super) fn mentions_parts(
    mentions: Option<&matrix_sdk::ruma::events::Mentions>,
) -> (Vec<String>, bool) {
    let Some(mentions) = mentions else {
        return (Vec::new(), false);
    };
    (
        mentions.user_ids.iter().map(ToString::to_string).collect(),
        mentions.room,
    )
}

pub(super) fn text_message_parts(
    body: &str,
    formatted: Option<&matrix_sdk::ruma::events::room::message::FormattedBody>,
    mentions: Option<&matrix_sdk::ruma::events::Mentions>,
    is_reply: bool,
) -> (String, Option<String>, Vec<String>, bool) {
    let body = if is_reply {
        strip_reply_fallback(body)
    } else {
        body.to_string()
    };
    let formatted_body = if is_reply {
        sanitized_reply_formatted_body(formatted)
    } else {
        sanitized_formatted_body(formatted)
    };
    let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
    (body, formatted_body, mentioned_user_ids, mentions_room)
}

pub(super) fn extract_edit_content(
    new_content: &matrix_sdk::ruma::events::room::message::RoomMessageEventContentWithoutRelation,
) -> Option<EditedTextContent> {
    let body = match &new_content.msgtype {
        matrix_sdk::ruma::events::room::message::MessageType::Text(t) => Some(t.body.clone()),
        matrix_sdk::ruma::events::room::message::MessageType::Notice(t) => Some(t.body.clone()),
        _ => None,
    }?;
    Some(EditedTextContent { body })
}

pub(super) fn unable_to_decrypt_message(
    id: String,
    sender_id: String,
    sender_name: String,
    timestamp: String,
    is_me: bool,
) -> ChatMessage {
    ChatMessage {
        id,
        sender_id,
        sender_name,
        content: "无法解密此消息（缺少会话密钥）".to_string(),
        formatted_body: None,
        caption: None,
        caption_formatted_body: None,
        shared_caption: None,
        image_metadata: None,
        mentioned_user_ids: Vec::new(),
        mentions_room: false,
        timestamp,
        is_me,
        msg_type: MessageType::Text,
        image_url: None,
        media_source_json: None,
        image_width: None,
        image_height: None,
        filename: None,
        file_size: None,
        mime_type: None,
        duration_ms: None,
        geo_uri: None,
        poll: None,
        in_reply_to: None,
        is_edited: false,
        edit_history: Vec::new(),
        reactions: Vec::new(),
        readers: Vec::new(),
        total_members: 0,
    }
}
