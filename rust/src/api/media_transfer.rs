//! Cancellable, file-backed playback transfers. No attachment bytes cross FFI.
use std::{
    io::{BufReader, Read, Write},
    path::Path,
    time::{Duration, Instant},
};

use flutter_rust_bridge::frb;
use futures_util::StreamExt;
use matrix_sdk::ruma::events::room::MediaSource;
use tempfile::NamedTempFile;
use tokio::{io::AsyncWriteExt, sync::watch};

use super::matrix::{
    get_client, media_client_identity, media_download_url, reacquire_media_client,
};

const TRANSFER_TIMEOUT: Duration = Duration::from_secs(30 * 60);
const COPY_BUFFER_SIZE: usize = 64 * 1024;

/// A cancellation handle, created before starting an asynchronous
/// transfer so disposal can cancel even before Rust begins the download.
#[frb(opaque)]
pub struct MediaTransfer {
    cancelled: watch::Sender<bool>,
}

impl MediaTransfer {
    #[frb(sync)]
    pub fn new() -> Self {
        Self {
            cancelled: watch::channel(false).0,
        }
    }

    #[frb(sync)]
    pub fn cancel(&self) {
        self.cancelled.send_replace(true);
    }
}

impl Default for MediaTransfer {
    fn default() -> Self {
        Self::new()
    }
}

fn check_cancelled(cancelled: &watch::Sender<bool>, deadline: Instant) -> Result<(), String> {
    if *cancelled.borrow() {
        return Err("Media transfer cancelled.".to_string());
    }
    if Instant::now() >= deadline {
        return Err("Media transfer timed out. Please retry.".to_string());
    }
    Ok(())
}

/// The SDK checks metadata, AES-CTR and the ciphertext SHA-256, including the
/// final EOF read. The output stays private and unnamed until all checks pass.
fn decrypt_file(
    encrypted: NamedTempFile,
    source: MediaSource,
    cancelled: watch::Sender<bool>,
    deadline: Instant,
) -> Result<NamedTempFile, String> {
    let mut reader =
        BufReader::with_capacity(COPY_BUFFER_SIZE, encrypted.reopen().map_err(io_error)?);
    let MediaSource::Encrypted(file) = source else {
        return Err("Expected encrypted media.".to_string());
    };
    let mut decryptor =
        matrix_sdk_base::crypto::AttachmentDecryptor::new(&mut reader, (*file).into())
            .map_err(|e| format!("Invalid encrypted media: {e}"))?;
    let mut output = NamedTempFile::new_in(encrypted.path().parent().unwrap()).map_err(io_error)?;
    let mut buffer = [0u8; COPY_BUFFER_SIZE];
    loop {
        check_cancelled(&cancelled, deadline)?;
        let length = decryptor
            .read(&mut buffer)
            .map_err(|e| format!("Media decryption failed: {e}"))?;
        if length == 0 {
            break;
        }
        output.write_all(&buffer[..length]).map_err(io_error)?;
    }
    output.flush().map_err(io_error)?;
    check_cancelled(&cancelled, deadline)?;
    Ok(output)
}

fn io_error(error: std::io::Error) -> String {
    format!("Media file operation failed: {error}")
}

/// Download to a private temporary file using the active account's SDK HTTP
/// client. The expected user and session instance must still match at publish.
/// `destination` is in a fresh application-owned directory, never a user path.
#[frb]
pub async fn download_media_source_to_file(
    transfer: &MediaTransfer,
    media_source_json: String,
    expected_user_id: String,
    destination: String,
) -> Result<(), String> {
    let deadline = Instant::now() + TRANSFER_TIMEOUT;
    check_cancelled(&transfer.cancelled, deadline)?;
    let source: MediaSource = serde_json::from_str(&media_source_json)
        .map_err(|e| format!("Invalid media source: {e}"))?;
    if !matches!(source, MediaSource::Encrypted(_)) {
        return Err("Expected encrypted media.".to_string());
    }
    let client = get_client().await.ok_or("No active account.")?;
    if client.user_id().map(|id| id.as_str()) != Some(expected_user_id.as_str()) {
        return Err("Media account changed.".to_string());
    }
    let identity = media_client_identity(&client).await?;
    let url = media_download_url(&client, &source)?;
    let session = client
        .matrix_auth()
        .session()
        .ok_or("No authenticated session.")?;
    let http_client = client.http_client().clone();
    drop(client); // Never keep a lifecycle lease across network I/O.
    let parent = Path::new(&destination)
        .parent()
        .ok_or("Missing media directory.")?;
    let encrypted = NamedTempFile::new_in(parent).map_err(io_error)?;
    let mut cancelled = transfer.cancelled.subscribe();
    let mut account_check = tokio::time::interval(Duration::from_millis(250));
    {
        let download = async {
            let response = http_client
                .get(url)
                // Android's shared client otherwise caps the full body at 30s.
                .timeout(TRANSFER_TIMEOUT)
                .bearer_auth(session.tokens.access_token)
                .send()
                .await
                .map_err(|e| format!("Media download failed: {e}"))?;
            // Refuse partial and empty-success responses as well as HTTP errors.
            if response.status().as_u16() != 200 {
                return Err(format!(
                    "Media download failed (HTTP {}).",
                    response.status()
                ));
            }
            let expected_length = response.content_length();
            let mut received = 0u64;
            let mut output = tokio::fs::File::from_std(encrypted.reopen().map_err(io_error)?);
            let mut stream = response.bytes_stream();
            while let Some(chunk) = stream.next().await {
                check_cancelled(&transfer.cancelled, deadline)?;
                let chunk = chunk.map_err(|e| format!("Media download failed: {e}"))?;
                received = received
                    .checked_add(chunk.len() as u64)
                    .ok_or("Media is too large.")?;
                output.write_all(&chunk).await.map_err(io_error)?;
            }
            output.flush().await.map_err(io_error)?;
            if expected_length.is_some_and(|expected| expected != received) {
                return Err("Incomplete media download.".to_string());
            }
            Ok::<_, String>(())
        };
        tokio::pin!(download);
        loop {
            tokio::select! {
                biased;
                _ = async {
                    // Drop watch::Ref before select runs another async branch.
                    let _ = cancelled.wait_for(|value| *value).await;
                } => return Err("Media transfer cancelled.".to_string()),
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)) => {
                    return Err("Media transfer timed out. Please retry.".to_string());
                }
                _ = account_check.tick() => { reacquire_media_client(&identity).await?; }
                result = &mut download => { result?; break; }
            }
        }
    }
    reacquire_media_client(&identity).await?;
    let cancellation = transfer.cancelled.clone();
    let output = tokio::task::spawn_blocking(move || {
        decrypt_file(encrypted, source, cancellation, deadline)
    })
    .await
    .map_err(|e| format!("Media decryption worker failed: {e}"))??;
    // Hold this lease only for the final publication, preventing account removal
    // between the identity check and returning the verified file to Flutter.
    let _client = reacquire_media_client(&identity).await?;
    check_cancelled(&transfer.cancelled, deadline)?;
    output
        .persist_noclobber(&destination)
        .map_err(|e| format!("Cannot publish media: {e}"))?;
    Ok(())
}

#[cfg(test)]
#[path = "../media_transfer_tests.rs"]
mod tests;
