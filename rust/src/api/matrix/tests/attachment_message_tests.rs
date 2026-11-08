use super::{
    file_message_content, image_message_content, image_mime_type, location_message_content,
    poll_start_content, poll_start_for_forward, room_message_preview, unstable_poll_preview,
    validate_poll_answer_ids, video_message_content, video_mime_type,
};
use matrix_sdk::ruma::{
    events::{
        poll::{
            unstable_response::UnstablePollResponseEventContent,
            unstable_start::UnstablePollStartEventContent,
        },
        room::{
            message::{AudioMessageEventContent, MessageType, RoomMessageEventContent},
            MediaSource,
        },
        StaticEventContent,
    },
    OwnedMxcUri, UInt,
};

fn mxc_uri() -> OwnedMxcUri {
    OwnedMxcUri::from("mxc://example.org/media")
}

#[test]
fn media_mime_validation_is_case_insensitive_and_type_safe() {
    assert_eq!(
        image_mime_type("PHOTO.HEIC", None).unwrap().essence_str(),
        "image/heic"
    );
    assert!(image_mime_type("photo.jpg", Some("application/pdf".to_owned())).is_err());
    assert_eq!(
        video_mime_type("clip.MOV", None).unwrap().essence_str(),
        "video/quicktime"
    );
    assert_eq!(
        video_mime_type("clip.WebM", None).unwrap().essence_str(),
        "video/webm"
    );
    assert!(video_mime_type("clip.mp4", Some("image/jpeg".to_owned())).is_err());
}

#[test]
fn file_content_stays_m_file_even_for_audio_mime() {
    let content = file_message_content(
        "track.mp3".to_owned(),
        &"audio/mpeg".parse().unwrap(),
        UInt::new(3),
        MediaSource::Plain(mxc_uri()),
    );
    let json = serde_json::to_value(content).unwrap();

    assert_eq!(json["msgtype"], "m.file");
    assert_eq!(json["body"], "track.mp3");
    assert_eq!(json["url"], "mxc://example.org/media");
    assert_eq!(json["info"]["mimetype"], "audio/mpeg");
    assert_eq!(json["info"]["size"], 3);
}

#[test]
fn manually_built_image_and_video_content_preserves_attachment_metadata() {
    let image = image_message_content(
        "photo.jpg".to_owned(),
        &"image/jpeg".parse().unwrap(),
        UInt::new(12),
        UInt::new(640),
        UInt::new(480),
        MediaSource::Plain(mxc_uri()),
    );
    let image_json = serde_json::to_value(image).unwrap();
    assert_eq!(image_json["msgtype"], "m.image");
    assert_eq!(image_json["url"], "mxc://example.org/media");
    assert_eq!(image_json["info"]["mimetype"], "image/jpeg");
    assert_eq!(image_json["info"]["w"], 640);
    assert_eq!(image_json["info"]["h"], 480);

    let video = video_message_content(
        "clip.mp4".to_owned(),
        &"video/mp4".parse().unwrap(),
        UInt::new(34),
        UInt::new(1920),
        UInt::new(1080),
        Some(std::time::Duration::from_millis(1500)),
        MediaSource::Plain(mxc_uri()),
    );
    let video_json = serde_json::to_value(video).unwrap();
    assert_eq!(video_json["msgtype"], "m.video");
    assert_eq!(video_json["url"], "mxc://example.org/media");
    assert_eq!(video_json["info"]["mimetype"], "video/mp4");
    assert_eq!(video_json["info"]["duration"], 1500);
}

#[test]
fn location_content_uses_legacy_wire_format_and_validates_ranges() {
    let content = location_message_content("Office", "geo:39.9,116.4").unwrap();
    let json = serde_json::to_value(content).unwrap();

    assert_eq!(json["msgtype"], "m.location");
    assert_eq!(json["body"], "Office");
    assert_eq!(json["geo_uri"], "geo:39.9,116.4");
    assert!(location_message_content("", "geo:91,0").is_err());
    assert!(location_message_content("", "geo:1e1,20").is_err());
    assert!(location_message_content("", "https://example.org").is_err());
}

#[test]
fn poll_content_uses_unstable_wire_format_with_fallback() {
    let content = poll_start_content(
        " Lunch? ",
        vec![" Noodles ".to_owned(), String::new(), "Rice".to_owned()],
        true,
        2,
    )
    .unwrap();
    let json = serde_json::to_value(&content).unwrap();
    let poll = &json["org.matrix.msc3381.poll.start"];

    assert_eq!(
        <UnstablePollStartEventContent as StaticEventContent>::TYPE,
        "org.matrix.msc3381.poll.start"
    );
    assert_eq!(
        json["org.matrix.msc1767.text"],
        "Lunch?\n1. Noodles\n2. Rice"
    );
    assert_eq!(poll["question"]["org.matrix.msc1767.text"], "Lunch?");
    assert_eq!(poll["answers"].as_array().unwrap().len(), 2);
    assert_eq!(poll["answers"][0]["id"], "0");
    assert_eq!(poll["answers"][1]["id"], "1");
    assert_eq!(poll["max_selections"], 2);
    assert!(poll_start_content("", vec!["yes".to_owned()], false, 1).is_err());
    assert!(poll_start_content("Question", vec!["yes".to_owned()], false, 1).is_err());
    assert!(poll_start_content(
        "Question",
        vec!["yes".to_owned(), "no".to_owned()],
        false,
        0,
    )
    .is_err());
    assert!(poll_start_content(
        "Question",
        vec!["yes".to_owned(), "no".to_owned()],
        false,
        3,
    )
    .is_err());
}

#[test]
fn previews_cover_audio_location_and_poll() {
    let audio = RoomMessageEventContent::new(MessageType::Audio(AudioMessageEventContent::plain(
        "clip.mp3".to_owned(),
        mxc_uri(),
    )));
    let location = location_message_content("", "geo:39.9,116.4").unwrap();
    let poll = poll_start_content(
        "Lunch?",
        vec!["Rice".to_owned(), "Noodles".to_owned()],
        false,
        1,
    )
    .unwrap();

    assert_eq!(
        room_message_preview(&audio).as_deref(),
        Some("[音频] clip.mp3")
    );
    assert_eq!(
        room_message_preview(&location).as_deref(),
        Some("[位置] geo:39.9,116.4")
    );
    assert_eq!(
        unstable_poll_preview(&poll).as_deref(),
        Some("[投票] Lunch?")
    );
}

#[test]
fn forwarded_poll_is_a_new_start_without_relation() {
    let poll = poll_start_content(
        "Lunch?",
        vec!["Rice".to_owned(), "Noodles".to_owned()],
        false,
        1,
    )
    .unwrap();
    let forwarded = poll_start_for_forward(&poll).unwrap();

    assert!(forwarded.relates_to.is_none());
    assert_eq!(forwarded.poll_start.question.text, "Lunch?");
}

#[test]
fn poll_response_ids_must_be_nonempty_and_unique() {
    assert!(validate_poll_answer_ids(&["0".to_owned()]).is_ok());
    assert!(validate_poll_answer_ids(&[]).is_err());
    assert!(validate_poll_answer_ids(&["0".to_owned(), "0".to_owned()]).is_err());
    assert!(validate_poll_answer_ids(&[String::new()]).is_err());
}

#[test]
fn poll_response_uses_the_poll_start_as_its_reference() {
    let event_id = matrix_sdk::ruma::EventId::parse("$poll:example.org").unwrap();
    let content =
        UnstablePollResponseEventContent::new(vec!["0".to_owned(), "1".to_owned()], event_id);
    let json = serde_json::to_value(content).unwrap();

    assert_eq!(
        json["org.matrix.msc3381.poll.response"]["answers"],
        serde_json::json!(["0", "1"]),
    );
    assert_eq!(json["m.relates_to"]["event_id"], "$poll:example.org");
    assert_eq!(json["m.relates_to"]["rel_type"], "m.reference");
}
