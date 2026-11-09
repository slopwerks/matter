//! Message send implementation.

use super::*;

pub(super) async fn get_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    // Bounded like the other P0 calls: the load holds the client lease
    // (blocking logout/account switch) and pagination can run several
    // network attempts.
    run_bounded(async move { sdk_timeline::get_messages(&client, &room).await }).await
}

pub(super) async fn get_sticker_packs(room_id: String) -> Result<Vec<StickerPack>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;

    let parsed_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| api_err("media", format!("无效的房间 ID: {e}")))?;
    let room = client
        .get_room(&parsed_room_id)
        .ok_or_else(|| api_err("media", format!("房间不存在: {room_id}")))?;

    sticker_packs::get_sticker_packs(&client, &room).await
}

pub(super) fn build_mentions(
    user_ids: &[String],
    room: bool,
) -> Result<matrix_sdk::ruma::events::Mentions, String> {
    let mut mentions = matrix_sdk::ruma::events::Mentions::new();
    mentions.room = room;
    for user_id in user_ids {
        mentions.user_ids.insert(
            matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| {
                api_err("rooms", format!("Invalid mentioned user ID {user_id}: {e}"))
            })?,
        );
    }
    Ok(mentions)
}

pub(super) fn sanitized_html_has_visible_content(html: &str) -> bool {
    fn node_has_visible_content(node: matrix_sdk::ruma::html::NodeRef) -> bool {
        match node.data() {
            matrix_sdk::ruma::html::NodeData::Text(text) if !text.borrow().trim().is_empty() => {
                return true;
            }
            matrix_sdk::ruma::html::NodeData::Element(element) => {
                let name = element.name.local.as_ref();
                let attrs = element.attrs.borrow();
                if name == "hr"
                    || (name == "img" && attrs.iter().any(|attr| attr.name.local.as_ref() == "src"))
                    || attrs.iter().any(|attr| {
                        attr.name.local.as_ref() == "data-mx-maths" && !attr.value.trim().is_empty()
                    })
                {
                    return true;
                }
            }
            _ => {}
        }
        node.children().any(node_has_visible_content)
    }

    matrix_sdk::ruma::html::Html::parse(html)
        .children()
        .any(node_has_visible_content)
}

pub(super) fn build_text_content(
    message: FormattedMessageInput,
) -> Result<matrix_sdk::ruma::events::room::message::RoomMessageEventContent, String> {
    let mentions = build_mentions(&message.mentioned_user_ids, message.mentions_room)?;
    let formatted_body = message
        .formatted_body
        .map(|html| {
            matrix_sdk::ruma::html::sanitize_html(
                &html,
                matrix_sdk::ruma::html::HtmlSanitizerMode::Compat,
                matrix_sdk::ruma::html::RemoveReplyFallback::No,
            )
        })
        .filter(|html| sanitized_html_has_visible_content(html));
    let mut content = if let Some(formatted_body) = formatted_body {
        matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_html(
            message.body,
            formatted_body,
        )
    } else {
        matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_plain(message.body)
    };
    // Always set m.mentions, including an empty object, to avoid legacy
    // implicit-mention push rules.
    content.mentions = Some(mentions);
    Ok(content)
}

pub(super) async fn send_message(
    account_user_id: String,
    room_id: String,
    message: FormattedMessageInput,
) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    let content = build_text_content(message)?;

    let response = room
        .send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send failed: {e}")))?;

    app_log("info", "rooms", format!("Message sent to {}", room_id));
    info!("Message sent to {}", room_id);
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(response.response.event_id.to_string())
}

pub(super) fn poll_start_for_forward(
    content: &matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent,
) -> Result<matrix_sdk::ruma::events::poll::unstable_start::NewUnstablePollStartEventContent, String>
{
    use matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent;

    let UnstablePollStartEventContent::New(content) = content else {
        return Err(api_err(
            "rooms",
            "无法将投票编辑事件作为新投票转发".to_string(),
        ));
    };
    let mut content = content.clone();
    content.relates_to = None;
    Ok(content)
}
