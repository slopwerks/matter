//! Media upload implementation.

use super::*;

pub(super) fn parse_supplied_mime_type(
    value: Option<String>,
) -> Result<Option<mime::Mime>, String> {
    let Some(value) = value.map(|value| value.trim().to_owned()) else {
        return Ok(None);
    };
    if value.is_empty() {
        return Ok(None);
    }
    value
        .parse::<mime::Mime>()
        .map(Some)
        .map_err(|error| api_err("media", format!("Invalid MIME type: {error}")))
}

pub(super) fn image_mime_type(
    filename: &str,
    supplied: Option<String>,
) -> Result<mime::Mime, String> {
    let mime_type = if let Some(mime_type) = parse_supplied_mime_type(supplied)? {
        mime_type
    } else {
        let extension = filename
            .rsplit_once('.')
            .map(|(_, extension)| extension.to_ascii_lowercase());
        match extension.as_deref() {
            Some("png") => mime::IMAGE_PNG,
            Some("gif") => mime::IMAGE_GIF,
            Some("webp") => "image/webp".parse().expect("valid static MIME type"),
            Some("avif") => "image/avif".parse().expect("valid static MIME type"),
            Some("heic") => "image/heic".parse().expect("valid static MIME type"),
            Some("heif") => "image/heif".parse().expect("valid static MIME type"),
            Some("tif" | "tiff") => "image/tiff".parse().expect("valid static MIME type"),
            Some("bmp") => "image/bmp".parse().expect("valid static MIME type"),
            _ => mime::IMAGE_JPEG,
        }
    };
    if mime_type.type_() != mime::IMAGE {
        return Err(api_err(
            "media",
            format!("Expected an image MIME type, got {mime_type}"),
        ));
    }
    Ok(mime_type)
}

pub(super) fn video_mime_type(
    filename: &str,
    supplied: Option<String>,
) -> Result<mime::Mime, String> {
    let mime_type = if let Some(mime_type) = parse_supplied_mime_type(supplied)? {
        mime_type
    } else {
        let extension = filename
            .rsplit_once('.')
            .map(|(_, extension)| extension.to_ascii_lowercase());
        let fallback = match extension.as_deref() {
            Some("mov") => "video/quicktime",
            Some("webm") => "video/webm",
            Some("mkv") => "video/x-matroska",
            Some("3gp") => "video/3gpp",
            Some("3g2") => "video/3gpp2",
            Some("avi") => "video/x-msvideo",
            Some("mpg" | "mpeg") => "video/mpeg",
            Some("ogv") => "video/ogg",
            _ => "video/mp4",
        };
        fallback.parse().expect("valid static MIME type")
    };
    if mime_type.type_() != mime::VIDEO {
        return Err(api_err(
            "media",
            format!("Expected a video MIME type, got {mime_type}"),
        ));
    }
    Ok(mime_type)
}

pub(super) fn file_message_content(
    filename: String,
    mime_type: &mime::Mime,
    size: Option<matrix_sdk::ruma::UInt>,
    source: matrix_sdk::ruma::events::room::MediaSource,
) -> matrix_sdk::ruma::events::room::message::RoomMessageEventContent {
    use matrix_sdk::ruma::events::room::message::{
        FileInfo, FileMessageEventContent, MessageType, RoomMessageEventContent,
    };

    let mut info = FileInfo::new();
    info.mimetype = Some(mime_type.to_string());
    info.size = size;
    RoomMessageEventContent::new(MessageType::File(
        FileMessageEventContent::new(filename, source).info(Box::new(info)),
    ))
}

pub(super) async fn upload_media_source(
    client: Client,
    encrypted: bool,
    mime_type: mime::Mime,
    data: Vec<u8>,
) -> Result<matrix_sdk::ruma::events::room::MediaSource, String> {
    use matrix_sdk::ruma::events::room::MediaSource;

    tokio::time::timeout(MEDIA_SEND_TOTAL_TIMEOUT, async move {
        if encrypted {
            let mut reader = Cursor::new(data.as_slice());
            let encrypted_file =
                client
                    .upload_encrypted_file(&mut reader)
                    .await
                    .map_err(|error| {
                        api_err("media", format!("Encrypted media upload failed: {error}"))
                    })?;
            Ok(MediaSource::Encrypted(Box::new(encrypted_file)))
        } else {
            let upload = client
                .media()
                .upload(&mime_type, data, None)
                .await
                .map_err(|error| api_err("media", format!("Media upload failed: {error}")))?;
            Ok(MediaSource::Plain(upload.content_uri))
        }
    })
    .await
    .map_err(|_| api_err("media", "Media upload timed out. Please retry.".to_string()))?
}

pub(super) fn image_message_content(
    filename: String,
    mime_type: &mime::Mime,
    size: Option<matrix_sdk::ruma::UInt>,
    width: Option<matrix_sdk::ruma::UInt>,
    height: Option<matrix_sdk::ruma::UInt>,
    source: matrix_sdk::ruma::events::room::MediaSource,
) -> matrix_sdk::ruma::events::room::message::RoomMessageEventContent {
    use matrix_sdk::ruma::events::room::{
        message::{ImageMessageEventContent, MessageType, RoomMessageEventContent},
        ImageInfo,
    };

    let mut info = ImageInfo::new();
    info.mimetype = Some(mime_type.to_string());
    info.size = size;
    info.width = width;
    info.height = height;
    RoomMessageEventContent::new(MessageType::Image(
        ImageMessageEventContent::new(filename, source).info(Box::new(info)),
    ))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn video_message_content(
    filename: String,
    mime_type: &mime::Mime,
    size: Option<matrix_sdk::ruma::UInt>,
    width: Option<matrix_sdk::ruma::UInt>,
    height: Option<matrix_sdk::ruma::UInt>,
    duration: Option<matrix_sdk::ruma::time::Duration>,
    source: matrix_sdk::ruma::events::room::MediaSource,
) -> matrix_sdk::ruma::events::room::message::RoomMessageEventContent {
    use matrix_sdk::ruma::events::room::message::{
        MessageType, RoomMessageEventContent, VideoInfo, VideoMessageEventContent,
    };

    let mut info = VideoInfo::new();
    info.mimetype = Some(mime_type.to_string());
    info.size = size;
    info.width = width;
    info.height = height;
    info.duration = duration;
    RoomMessageEventContent::new(MessageType::Video(
        VideoMessageEventContent::new(filename, source).info(Box::new(info)),
    ))
}
