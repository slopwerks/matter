//! Media download implementation.

use super::*;

pub(super) fn mxc_to_thumbnail_http(
    client: &matrix_sdk::Client,
    mxc_url: &str,
    width: u32,
    height: u32,
) -> Option<String> {
    let url = url::Url::parse(mxc_url).ok()?;
    if url.scheme() != "mxc" {
        return None;
    }
    let mut server_name = url.host_str()?.to_owned();
    // Keep the port (e.g. media.example:8448): self-hosted media servers on
    // non-default ports would otherwise resolve to a URL that 404s.
    if let Some(port) = url.port() {
        server_name.push(':');
        server_name.push_str(&port.to_string());
    }
    let media_id = url.path().trim_start_matches('/');
    if server_name.is_empty() || media_id.is_empty() {
        return None;
    }
    let raw_base = client.homeserver().to_string();
    let base = raw_base.trim_end_matches('/');
    Some(format!(
        "{}/_matrix/client/v1/media/thumbnail/{}/{}?width={}&height={}&method=scale",
        base, server_name, media_id, width, height
    ))
}

pub(super) async fn mxc_to_http_avatar(mxc_url: String) -> Option<String> {
    let client = get_client().await?;
    let media_url = mxc_to_thumbnail_http(&client, &mxc_url, 96, 96)?;
    app_log(
        "info",
        "media",
        format!("Resolved avatar thumbnail for {}", mxc_url),
    );
    Some(media_url)
}

pub(super) async fn mxc_to_http_thumbnail(
    mxc_url: String,
    width: u32,
    height: u32,
) -> Option<String> {
    let client = get_client().await?;
    let media_url = mxc_to_thumbnail_http(&client, &mxc_url, width, height)?;
    app_log(
        "info",
        "media",
        format!(
            "Resolved media thumbnail for {} at {}x{}",
            mxc_url, width, height
        ),
    );
    Some(media_url)
}

pub(super) async fn mxc_to_http(mxc_url: String) -> Option<String> {
    mxc_to_http_thumbnail(mxc_url, 800, 600).await
}

pub(super) async fn mxc_to_http_full(mxc_url: String) -> Option<String> {
    let client = get_client().await?;
    let url = url::Url::parse(&mxc_url).ok()?;
    if url.scheme() != "mxc" {
        return None;
    }
    let mut server_name = url.host_str()?.to_owned();
    // Keep the port (e.g. media.example:8448): self-hosted media servers on
    // non-default ports would otherwise resolve to a URL that 404s.
    if let Some(port) = url.port() {
        server_name.push(':');
        server_name.push_str(&port.to_string());
    }
    let media_id = url.path().trim_start_matches('/');
    if server_name.is_empty() || media_id.is_empty() {
        return None;
    }
    let raw_base = client.homeserver().to_string();
    let base = raw_base.trim_end_matches('/');
    let media_url = format!(
        "{}/_matrix/client/v1/media/download/{}/{}",
        base, server_name, media_id
    );
    app_log(
        "info",
        "media",
        format!("Resolved full media URL for {}", mxc_url),
    );
    Some(media_url)
}

pub(in crate::api) async fn media_client_identity(
    client: &Client,
) -> Result<MediaClientIdentity, String> {
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("media", "No active user".to_string()))?
        .to_string();
    let instance_id = CLIENTS
        .read()
        .await
        .get(&user_id)
        .map(|entry| entry.instance_id)
        .ok_or_else(|| api_err("media", "Active account is no longer available".to_string()))?;
    Ok(MediaClientIdentity {
        user_id,
        instance_id,
    })
}

pub(in crate::api) async fn reacquire_media_client(
    identity: &MediaClientIdentity,
) -> Result<ClientLease, String> {
    let client = get_client().await.ok_or_else(|| {
        api_err(
            "media",
            "Media transfer completed, but the account is logged out.".to_string(),
        )
    })?;
    ensure_account_matches(&client, &identity.user_id).map_err(|_| {
        api_err(
            "media",
            "Media transfer completed, but the active account changed.".to_string(),
        )
    })?;
    let current_instance_id = CLIENTS
        .read()
        .await
        .get(&identity.user_id)
        .map(|entry| entry.instance_id);
    if current_instance_id != Some(identity.instance_id) {
        return Err(api_err(
            "media",
            "Media transfer completed, but the account session changed.".to_string(),
        ));
    }
    Ok(client)
}

pub(super) async fn download_media_bytes(mxc_url: String) -> Option<Vec<u8>> {
    let client = get_client().await?;
    let source = matrix_sdk::ruma::events::room::MediaSource::Plain(
        matrix_sdk::ruma::OwnedMxcUri::try_from(mxc_url.as_str()).ok()?,
    );
    let url = media_download_url(&client, &source).ok()?;
    let identity = media_client_identity(&client).await.ok()?;
    let session = client.matrix_auth().session()?;
    let http_client = client.http_client().clone();
    let mut diagnostics = RequestDiagnostics::new(url.clone());
    drop(client);

    match tokio::time::timeout(MEDIA_DOWNLOAD_TOTAL_TIMEOUT, async {
        let response = http_client
            .get(url)
            .bearer_auth(session.tokens.access_token)
            .send()
            .await?;
        diagnostics.status = Some(response.status().as_u16());
        diagnostics.stage = "http_status";
        let response = response.error_for_status()?;
        diagnostics.stage = "response_body";
        response.bytes().await
    })
    .await
    {
        Ok(Ok(response)) => {
            reacquire_media_client(&identity).await.ok()?;
            app_log(
                "info",
                "media",
                format!(
                    "download_media_bytes: {} bytes for {}",
                    response.len(),
                    mxc_url
                ),
            );
            Some(response.to_vec())
        }
        Ok(Err(e)) => {
            app_log(
                "error",
                "media",
                format!("download_media_bytes failed: {}", diagnostics.failure(&e)),
            );
            None
        }
        Err(_) => {
            app_log(
                "error",
                "media",
                format!(
                    "download_media_bytes timed out: {} timeout_ms={}",
                    diagnostics.context(),
                    MEDIA_DOWNLOAD_TOTAL_TIMEOUT.as_millis(),
                ),
            );
            None
        }
    }
}

pub(super) fn media_download_limit(max_size_bytes: i32) -> Result<usize, String> {
    usize::try_from(max_size_bytes)
        .ok()
        .filter(|limit| *limit > 0)
        .ok_or_else(|| {
            api_err(
                "media",
                "Media download limit must be positive.".to_string(),
            )
        })
}

pub(super) fn ensure_media_content_length(
    content_length: Option<u64>,
    limit: usize,
) -> Result<(), String> {
    if content_length.is_some_and(|length| length > limit as u64) {
        return Err(api_err(
            "media",
            format!("Media exceeds the {limit}-byte download limit."),
        ));
    }
    Ok(())
}

pub(super) fn append_media_chunk(
    content: &mut Vec<u8>,
    chunk: &[u8],
    limit: usize,
) -> Result<(), String> {
    let next_length = content
        .len()
        .checked_add(chunk.len())
        .ok_or_else(|| api_err("media", "Media download is too large.".to_string()))?;
    if next_length > limit {
        return Err(api_err(
            "media",
            format!("Media exceeds the {limit}-byte download limit."),
        ));
    }
    content.extend_from_slice(chunk);
    Ok(())
}

pub(in crate::api) fn media_download_url(
    client: &Client,
    source: &matrix_sdk::ruma::events::room::MediaSource,
) -> Result<url::Url, String> {
    let mxc_url = match source {
        matrix_sdk::ruma::events::room::MediaSource::Plain(uri) => uri.to_string(),
        matrix_sdk::ruma::events::room::MediaSource::Encrypted(file) => file.url.to_string(),
    };
    let mxc_url = url::Url::parse(&mxc_url)
        .map_err(|e| api_err("media", format!("Invalid media URL: {e}")))?;
    if mxc_url.scheme() != "mxc" {
        return Err(api_err(
            "media",
            "Media URL must use the mxc scheme.".to_string(),
        ));
    }
    let server_name = mxc_url
        .host_str()
        .filter(|server_name| !server_name.is_empty())
        .ok_or_else(|| api_err("media", "Media URL is missing a server name.".to_string()))?;
    let server_name = match mxc_url.port() {
        Some(port) => format!("{server_name}:{port}"),
        None => server_name.to_string(),
    };
    let media_id = mxc_url.path().trim_start_matches('/');
    if media_id.is_empty() {
        return Err(api_err(
            "media",
            "Media URL is missing a media ID.".to_string(),
        ));
    }

    let mut url = client.homeserver();
    url.set_query(None);
    url.set_fragment(None);
    let mut segments = url.path_segments_mut().map_err(|_| {
        api_err(
            "media",
            "Homeserver URL cannot contain path segments.".to_string(),
        )
    })?;
    segments.pop_if_empty();
    segments.extend([
        "_matrix",
        "client",
        "v1",
        "media",
        "download",
        &server_name,
        media_id,
    ]);
    drop(segments);
    Ok(url)
}

pub(super) fn decrypt_media_bytes(
    encrypted: Vec<u8>,
    file: matrix_sdk::ruma::events::room::EncryptedFile,
    limit: usize,
) -> Result<Vec<u8>, String> {
    let capacity = encrypted.len();
    let mut cursor = Cursor::new(encrypted);
    let mut decryptor = matrix_sdk_base::crypto::AttachmentDecryptor::new(&mut cursor, file.into())
        .map_err(|e| api_err("media", format!("Invalid encrypted media: {e}")))?;
    let mut decrypted = Vec::with_capacity(capacity);
    decryptor
        .by_ref()
        .take(limit as u64 + 1)
        .read_to_end(&mut decrypted)
        .map_err(|e| api_err("media", format!("Media decryption failed: {e}")))?;
    if decrypted.len() > limit {
        return Err(api_err(
            "media",
            format!("Media exceeds the {limit}-byte download limit."),
        ));
    }
    Ok(decrypted)
}

pub(super) async fn download_media_source_bytes(
    media_source_json: String,
    max_size_bytes: i32,
) -> Result<Vec<u8>, String> {
    use futures_util::StreamExt;

    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    let source: matrix_sdk::ruma::events::room::MediaSource =
        serde_json::from_str(&media_source_json)
            .map_err(|e| api_err("media", format!("Invalid media source: {e}")))?;
    let limit = media_download_limit(max_size_bytes)?;
    let url = media_download_url(&client, &source)?;
    let identity = media_client_identity(&client).await?;
    let session = client
        .matrix_auth()
        .session()
        .ok_or_else(|| api_err("media", "No authenticated session.".to_string()))?;
    let http_client = client.http_client().clone();
    let mut diagnostics = RequestDiagnostics::new(url.clone());
    drop(client);
    let content = tokio::time::timeout(MEDIA_DOWNLOAD_TOTAL_TIMEOUT, async {
        let response = http_client
            .get(url)
            .bearer_auth(session.tokens.access_token)
            .send()
            .await
            .map_err(|e| {
                api_err(
                    "media",
                    format!("Media download failed: {}", diagnostics.failure(&e)),
                )
            })?;
        diagnostics.status = Some(response.status().as_u16());
        diagnostics.stage = "http_status";
        let response = response.error_for_status().map_err(|e| {
            api_err(
                "media",
                format!("Media download failed: {}", diagnostics.failure(&e)),
            )
        })?;
        diagnostics.stage = "response_body";
        ensure_media_content_length(response.content_length(), limit)?;

        let mut encrypted = Vec::new();
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| {
                api_err(
                    "media",
                    format!("Media download failed: {}", diagnostics.failure(&e)),
                )
            })?;
            append_media_chunk(&mut encrypted, &chunk, limit)?;
        }

        match source {
            matrix_sdk::ruma::events::room::MediaSource::Encrypted(file) => {
                decrypt_media_bytes(encrypted, *file, limit)
            }
            matrix_sdk::ruma::events::room::MediaSource::Plain(_) => Ok(encrypted),
        }
    })
    .await
    .map_err(|_| {
        api_err(
            "media",
            format!(
                "Media download timed out. Please retry. {} timeout_ms={}",
                diagnostics.context(),
                MEDIA_DOWNLOAD_TOTAL_TIMEOUT.as_millis(),
            ),
        )
    })??;
    reacquire_media_client(&identity).await?;
    app_log(
        "info",
        "media",
        format!("download_media_source_bytes: {} bytes", content.len()),
    );
    Ok(content)
}
