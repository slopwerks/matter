//! Location implementation.

use super::*;

/// Validate the RFC 5870 subset supported by the attachment composer.
pub(super) fn validated_geo_uri(value: &str) -> Result<String, String> {
    let value = value.trim();
    let uri = url::Url::parse(value)
        .map_err(|error| api_err("media", format!("Invalid geo URI: {error}")))?;
    if uri.scheme() != "geo" || uri.query().is_some() || uri.fragment().is_some() {
        return Err(api_err(
            "media",
            "Location must be a geo: URI without a query or fragment.".to_string(),
        ));
    }

    let coordinate_part = uri.path().split(';').next().unwrap_or_default();
    let coordinates = coordinate_part.split(',').collect::<Vec<_>>();
    if !(2..=3).contains(&coordinates.len()) {
        return Err(api_err(
            "media",
            "Location must contain latitude and longitude.".to_string(),
        ));
    }
    if coordinates
        .iter()
        .any(|coordinate| coordinate.contains(['e', 'E']))
    {
        return Err(api_err(
            "media",
            "Location coordinates must use decimal notation.".to_string(),
        ));
    }
    let latitude = coordinates[0]
        .parse::<f64>()
        .map_err(|_| api_err("media", "Invalid latitude.".to_string()))?;
    let longitude = coordinates[1]
        .parse::<f64>()
        .map_err(|_| api_err("media", "Invalid longitude.".to_string()))?;
    if !latitude.is_finite() || !(-90.0..=90.0).contains(&latitude) {
        return Err(api_err(
            "media",
            "Latitude must be between -90 and 90.".to_string(),
        ));
    }
    if !longitude.is_finite() || !(-180.0..=180.0).contains(&longitude) {
        return Err(api_err(
            "media",
            "Longitude must be between -180 and 180.".to_string(),
        ));
    }
    if coordinates.len() == 3
        && coordinates[2]
            .parse::<f64>()
            .ok()
            .filter(|altitude| altitude.is_finite())
            .is_none()
    {
        return Err(api_err("media", "Invalid altitude.".to_string()));
    }
    Ok(value.to_owned())
}

pub(super) fn location_message_content(
    body: &str,
    geo_uri: &str,
) -> Result<matrix_sdk::ruma::events::room::message::RoomMessageEventContent, String> {
    use matrix_sdk::ruma::events::room::message::{
        LocationMessageEventContent, MessageType, RoomMessageEventContent,
    };

    let geo_uri = validated_geo_uri(geo_uri)?;
    let body = body.trim();
    let label = if body.is_empty() {
        geo_uri.clone()
    } else {
        body.to_owned()
    };
    Ok(RoomMessageEventContent::new(MessageType::Location(
        LocationMessageEventContent::new(label, geo_uri),
    )))
}

pub(super) async fn send_location(
    account_user_id: String,
    room_id: String,
    body: String,
    geo_uri: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let content = location_message_content(&body, &geo_uri)?;

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send location failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Location message sent to {}", room_id),
    );
    info!("Location message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}
