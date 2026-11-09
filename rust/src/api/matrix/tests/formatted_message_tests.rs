use super::{build_text_content, text_message_parts, FormattedMessageInput};
use matrix_sdk::ruma::events::{
    room::message::{FormattedBody, RoomMessageEventContent},
    Mentions,
};

#[test]
fn outgoing_html_is_sanitized_and_mentions_are_serialized() {
    let content = build_text_content(FormattedMessageInput {
        body: "Hello Alice".to_string(),
        formatted_body: Some(r#"<strong>Hello</strong><script>bad()</script>"#.to_string()),
        mentioned_user_ids: vec!["@alice:example.org".to_string()],
        mentions_room: false,
    })
    .unwrap();
    let json = serde_json::to_value(&content).unwrap();

    assert_eq!(json["body"], "Hello Alice");
    assert_eq!(json["format"], "org.matrix.custom.html");
    assert!(json["formatted_body"]
        .as_str()
        .unwrap()
        .contains("<strong>"));
    assert!(!json["formatted_body"].as_str().unwrap().contains("<script"));
    assert_eq!(json["m.mentions"]["user_ids"][0], "@alice:example.org");
}

#[test]
fn matrix_links_survive_outgoing_and_incoming_sanitization() {
    let html = r#"<a href="matrix:u/alice:example.org">Alice</a>"#;
    let content = build_text_content(FormattedMessageInput {
        body: "Alice".to_string(),
        formatted_body: Some(html.to_string()),
        mentioned_user_ids: vec![],
        mentions_room: false,
    })
    .unwrap();
    let json = serde_json::to_value(&content).unwrap();
    assert!(json["formatted_body"]
        .as_str()
        .unwrap()
        .contains(r#"href="matrix:u/alice:example.org""#));

    let formatted = FormattedBody::html(html.to_string());
    let (_, incoming_html, _, _) = text_message_parts("Alice", Some(&formatted), None, false);
    assert!(incoming_html
        .as_deref()
        .unwrap()
        .contains(r#"href="matrix:u/alice:example.org""#));
}

#[test]
fn spoilers_survive_outgoing_sanitization() {
    let content = build_text_content(FormattedMessageInput {
        body: "[Spoiler for plot twist]".to_string(),
        formatted_body: Some(
            r#"<span data-mx-spoiler="plot twist" onclick="bad()">Alice wins</span>"#.to_string(),
        ),
        mentioned_user_ids: vec![],
        mentions_room: false,
    })
    .unwrap();
    let json = serde_json::to_value(&content).unwrap();
    let formatted = json["formatted_body"].as_str().unwrap();

    assert!(formatted.contains(r#"data-mx-spoiler="plot twist""#));
    assert!(formatted.contains("Alice wins"));
    assert!(!formatted.contains("onclick"));
}

#[test]
fn formatting_without_visible_content_falls_back_to_plain_text() {
    let content = build_text_content(FormattedMessageInput {
        body: "image".to_string(),
        formatted_body: Some(r#"<p><img src="https://example.org/cat.png"></p>"#.to_string()),
        mentioned_user_ids: vec![],
        mentions_room: false,
    })
    .unwrap();
    let json = serde_json::to_value(&content).unwrap();

    assert_eq!(json["body"], "image");
    assert!(json.get("formatted_body").is_none(), "{json}");
}

#[test]
fn mxc_images_remain_visible_formatted_content() {
    let content = build_text_content(FormattedMessageInput {
        body: "a cat".to_string(),
        formatted_body: Some(r#"<p><img src="mxc://example.org/cat" alt="a cat"></p>"#.to_string()),
        mentioned_user_ids: vec![],
        mentions_room: false,
    })
    .unwrap();
    let json = serde_json::to_value(&content).unwrap();

    assert_eq!(
        json["formatted_body"],
        r#"<p><img alt="a cat" src="mxc://example.org/cat"></p>"#
    );
}

#[test]
fn matrix_links_survive_reply_fallback_removal() {
    let formatted = FormattedBody::html(
            r#"<mx-reply><blockquote>Earlier</blockquote></mx-reply><a href="matrix:u/alice:example.org">Alice</a>"#
                .to_string(),
        );
    let (_, html, _, _) = text_message_parts("Alice", Some(&formatted), None, true);

    let html = html.unwrap();
    assert!(!html.contains("mx-reply"));
    assert!(html.contains(r#"href="matrix:u/alice:example.org""#));
}

#[test]
fn incoming_formatted_body_keeps_plain_fallback_separate() {
    let formatted = FormattedBody::html("<strong>Hello</strong>".to_string());
    let mentions =
        Mentions::with_user_ids(vec![
            matrix_sdk::ruma::UserId::parse("@alice:example.org").unwrap()
        ]);
    let (body, html, user_ids, room) =
        text_message_parts("Hello", Some(&formatted), Some(&mentions), false);

    assert_eq!(body, "Hello");
    assert_eq!(html.as_deref(), Some("<strong>Hello</strong>"));
    assert_eq!(user_ids, ["@alice:example.org"]);
    assert!(!room);
}

#[test]
fn empty_formatting_sends_plain_text_with_empty_mentions_object() {
    let content = build_text_content(FormattedMessageInput {
        body: "Hello".to_string(),
        formatted_body: None,
        mentioned_user_ids: vec![],
        mentions_room: false,
    })
    .unwrap();
    let json = serde_json::to_value(&content).unwrap();

    assert_eq!(json["body"], "Hello");
    assert!(json.get("formatted_body").is_none());
    assert_eq!(json["m.mentions"], serde_json::json!({}));
    assert!(matches!(
        content,
        RoomMessageEventContent {
            mentions: Some(_),
            ..
        }
    ));
}
