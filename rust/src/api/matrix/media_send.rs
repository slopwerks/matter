//! Media send implementation.

use super::*;

pub(super) async fn get_image_album_caption(
    account_user_id: String,
    room_id: String,
    root_event_id: String,
) -> Result<Option<String>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_owned()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    let root = matrix_sdk::ruma::EventId::parse(root_event_id)
        .map_err(|error| api_err("media", format!("Invalid album root: {error}")))?;
    tokio::time::timeout(
        MEDIA_EVENT_SEND_TIMEOUT,
        image_caption::album_caption(&room, &root),
    )
    .await
    .map_err(|_| api_err("media", "Album caption lookup timed out.".to_owned()))?
    .map_err(|error| api_err("media", error))
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn send_image_message(
    account_user_id: String,
    room_id: String,
    image_data: Vec<u8>,
    filename: String,
    mime_type: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
    caption: Option<String>,
    shared_caption: Option<String>,
    metadata: Option<ImageMessageMetadata>,
) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    let mime_type = image_mime_type(&filename, mime_type)?;
    let identity = media_client_identity(&client).await?;
    let encrypted = room
        .latest_encryption_state()
        .await
        .map_err(|error| api_err("media", format!("Check room encryption failed: {error}")))?
        .is_encrypted();
    let upload_client = client.client.clone();
    drop(room);
    drop(client);

    app_log(
        "info",
        "media",
        format!(
            "Uploading image: {} ({} bytes, mime: {})",
            filename,
            image_data.len(),
            mime_type
        ),
    );

    let image_size = matrix_sdk::ruma::UInt::new(image_data.len() as u64);
    let image_width = width
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64));
    let image_height = height
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64));
    let source =
        upload_media_source(upload_client, encrypted, mime_type.clone(), image_data).await?;
    let client = reacquire_media_client(&identity).await.map_err(|error| {
        api_err(
            "media",
            format!("Image uploaded, but the message was not sent: {error}"),
        )
    })?;
    let room = get_room_by_id(&client, &room_id).map_err(|error| {
        api_err(
            "media",
            format!("Image uploaded, but the room is unavailable: {error}"),
        )
    })?;
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let content = image_message_content(
        filename,
        &mime_type,
        image_size,
        image_width,
        image_height,
        source,
    );
    let content =
        image_caption::with_captions(content, caption.as_deref(), shared_caption.as_deref())?;
    let content = image_caption::with_metadata(content, metadata.as_ref())?;
    let response = tokio::time::timeout(
        MEDIA_EVENT_SEND_TIMEOUT,
        room.send_raw("m.room.message", content),
    )
    .await
    .map_err(|_| {
        api_err(
            "media",
            "Image uploaded, but sending the message timed out.".to_string(),
        )
    })?
    .map_err(|e| api_err("media", format!("Send image message failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Image message sent to {}", room_id),
    );
    info!("Image message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(response.response.event_id.to_string())
}

pub(super) async fn send_file_message(
    account_user_id: String,
    room_id: String,
    file_data: Vec<u8>,
    filename: String,
    mime_type: Option<String>,
    size: Option<i32>,
) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    let mime_type = parse_supplied_mime_type(mime_type)?.unwrap_or(mime::APPLICATION_OCTET_STREAM);
    let file_size = size
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64))
        .or_else(|| matrix_sdk::ruma::UInt::new(file_data.len() as u64));
    let identity = media_client_identity(&client).await?;
    let encrypted = room
        .latest_encryption_state()
        .await
        .map_err(|error| api_err("media", format!("Check room encryption failed: {error}")))?
        .is_encrypted();
    let upload_client = client.client.clone();
    drop(room);
    drop(client);

    app_log(
        "info",
        "media",
        format!(
            "Uploading file: {} ({} bytes, mime: {})",
            filename,
            file_data.len(),
            mime_type
        ),
    );

    let source =
        upload_media_source(upload_client, encrypted, mime_type.clone(), file_data).await?;
    let client = reacquire_media_client(&identity).await.map_err(|error| {
        api_err(
            "media",
            format!("File uploaded, but the message was not sent: {error}"),
        )
    })?;
    let room = get_room_by_id(&client, &room_id).map_err(|error| {
        api_err(
            "media",
            format!("File uploaded, but the room is unavailable: {error}"),
        )
    })?;
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let content = file_message_content(filename, &mime_type, file_size, source);
    tokio::time::timeout(MEDIA_EVENT_SEND_TIMEOUT, room.send(content))
        .await
        .map_err(|_| {
            api_err(
                "media",
                "File uploaded, but sending the message timed out.".to_string(),
            )
        })?
        .map_err(|e| api_err("media", format!("Send file message failed: {e}")))?;

    app_log("info", "rooms", format!("File message sent to {}", room_id));
    info!("File message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn send_video_message(
    account_user_id: String,
    room_id: String,
    video_data: Vec<u8>,
    filename: String,
    mime_type: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
    duration_ms: Option<i32>,
    size: Option<i32>,
) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    let mime_type = video_mime_type(&filename, mime_type)?;
    let identity = media_client_identity(&client).await?;
    let encrypted = room
        .latest_encryption_state()
        .await
        .map_err(|error| api_err("media", format!("Check room encryption failed: {error}")))?
        .is_encrypted();
    let upload_client = client.client.clone();
    drop(room);
    drop(client);

    app_log(
        "info",
        "media",
        format!(
            "Uploading video: {} ({} bytes, mime: {})",
            filename,
            video_data.len(),
            mime_type
        ),
    );

    let video_width = width
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64));
    let video_height = height
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64));
    let video_duration = duration_ms
        .filter(|value| *value > 0)
        .map(|value| matrix_sdk::ruma::time::Duration::from_millis(value as u64));
    let video_size = size
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64))
        .or_else(|| matrix_sdk::ruma::UInt::new(video_data.len() as u64));
    let source =
        upload_media_source(upload_client, encrypted, mime_type.clone(), video_data).await?;
    let client = reacquire_media_client(&identity).await.map_err(|error| {
        api_err(
            "media",
            format!("Video uploaded, but the message was not sent: {error}"),
        )
    })?;
    let room = get_room_by_id(&client, &room_id).map_err(|error| {
        api_err(
            "media",
            format!("Video uploaded, but the room is unavailable: {error}"),
        )
    })?;
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let content = video_message_content(
        filename,
        &mime_type,
        video_size,
        video_width,
        video_height,
        video_duration,
        source,
    );
    tokio::time::timeout(MEDIA_EVENT_SEND_TIMEOUT, room.send(content))
        .await
        .map_err(|_| {
            api_err(
                "media",
                "Video uploaded, but sending the message timed out.".to_string(),
            )
        })?
        .map_err(|e| api_err("media", format!("Send video message failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Video message sent to {}", room_id),
    );
    info!("Video message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}
