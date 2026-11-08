//! Account store implementation.

use super::*;

pub(super) fn sanitize_for_path(s: &str) -> String {
    s.replace('@', "_at_")
        .replace(':', "_colon_")
        .replace('/', "_slash_")
        .replace('\\', "_backslash_")
}

/// Build per-user directory: `{base}/accounts/{sanitized_user_id}/`
/// or the pending directory: `{base}/_pending/`
pub(super) fn build_sdk_data_dir(base: &str, user_id: Option<&str>) -> std::path::PathBuf {
    match user_id {
        Some(uid) => std::path::PathBuf::from(base)
            .join("accounts")
            .join(sanitize_for_path(uid)),
        None => std::path::PathBuf::from(base).join("_pending"),
    }
}

/// Rename a directory, retrying with exponential backoff when Windows reports
/// `AccessDenied` (os error 5). This happens when the source directory still
/// has open file handles (e.g. SQLite stores held by a recently-dropped
/// `matrix-sdk::Client` whose internal `deadpool` connections have not yet
/// been returned to the pool or closed). The retry window is bounded so the
/// login flow is not blocked indefinitely.
pub(super) async fn rename_with_retry(
    from: &Path,
    to: &Path,
    max_attempts: u32,
    base_backoff: std::time::Duration,
) -> std::io::Result<()> {
    let mut attempt = 0u32;
    let mut backoff = base_backoff;
    loop {
        match tokio::fs::rename(from, to).await {
            Ok(()) => {
                if attempt > 0 {
                    app_log(
                        "info",
                        "auth",
                        format!(
                            "rename {} -> {} succeeded after {} retries",
                            from.display(),
                            to.display(),
                            attempt
                        ),
                    );
                }
                return Ok(());
            }
            Err(error) if attempt + 1 < max_attempts && is_access_denied(&error) => {
                warn!(
                    "rename {} -> {} hit {} (attempt {}/{}); retrying after {:?}",
                    from.display(),
                    to.display(),
                    error,
                    attempt + 1,
                    max_attempts,
                    backoff
                );
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(std::time::Duration::from_millis(800));
                attempt += 1;
            }
            Err(error) => return Err(error),
        }
    }
}

/// Returns true for the Windows `AccessDenied` / sharing-violation errors we
/// see when a SQLite store is briefly held open after the owning `Client` is
/// dropped. On non-Windows targets this only matches the rare `PermissionDenied`
/// (EACCES) case, which we let fall through; on POSIX the rename usually just
/// succeeds, so the retry path is rarely exercised there.
pub(super) fn is_access_denied(error: &std::io::Error) -> bool {
    if error.kind() == std::io::ErrorKind::PermissionDenied {
        return true;
    }
    // Match on numeric OS error codes only. The string form of
    // `std::io::Error` is the localized message from the OS message table
    // (e.g. "拒绝访问。" on zh-CN Windows), so substring matching is not
    // portable across system locales.
    #[cfg(windows)]
    {
        if let Some(code) = error.raw_os_error() {
            // 5 = ERROR_ACCESS_DENIED, 32 = ERROR_SHARING_VIOLATION.
            return code == 5 || code == 32;
        }
    }
    false
}

pub(super) async fn remove_legacy_plaintext_search_index(sdk_dir: &Path) -> Result<(), String> {
    let index_dir = sdk_dir.join("search_index");
    match tokio::fs::remove_dir_all(&index_dir).await {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => {
            let message = format!(
                "Refusing to continue because the legacy plaintext search index could not be removed from {}: {error}",
                index_dir.display()
            );
            warn!("{message}");
            Err(api_err("auth", message))
        }
    }
}

pub(super) async fn prepare_encrypted_search_index(
    sdk_dir: &Path,
    reset_encrypted_index: bool,
) -> Result<std::path::PathBuf, String> {
    let index_dir = sdk_dir.join("search_index");
    let marker = index_dir.join(ENCRYPTED_SEARCH_INDEX_MARKER);
    let marker_exists = match tokio::fs::metadata(&marker).await {
        Ok(_) => true,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => {
            return Err(api_err(
                "auth",
                format!(
                    "Failed to inspect encrypted search index marker at {}: {error}",
                    marker.display()
                ),
            ));
        }
    };

    if reset_encrypted_index {
        remove_legacy_plaintext_search_index(sdk_dir).await?;
    } else if !marker_exists {
        // The marker can be lost in a crash while the encrypted index and its
        // key file remain. Deleting the directory would destroy recoverable
        // data, so refuse and let the caller decide.
        let key_file = index_dir.join("seshat-index.key");
        if key_file.exists() {
            return Err(api_err(
                "auth",
                format!(
                    "Encrypted search index marker is missing at {} but the key file {} still exists; refusing to delete a potentially recoverable index",
                    marker.display(),
                    key_file.display()
                ),
            ));
        }
        remove_legacy_plaintext_search_index(sdk_dir).await?;
    }
    tokio::fs::create_dir_all(&index_dir)
        .await
        .map_err(|error| {
            api_err(
                "auth",
                format!(
                    "Failed to create encrypted search index directory at {}: {error}",
                    index_dir.display()
                ),
            )
        })?;
    tokio::fs::write(&marker, b"encrypted\n")
        .await
        .map_err(|error| {
            api_err(
                "auth",
                format!(
                    "Failed to mark encrypted search index at {}: {error}",
                    marker.display()
                ),
            )
        })?;
    Ok(index_dir)
}

pub(super) async fn delete_account_sdk_store(data_dir: &str, user_id: &str) -> Result<(), String> {
    let sdk_dir = build_sdk_data_dir(data_dir, Some(user_id));
    if !sdk_dir.exists() {
        return Ok(());
    }
    app_log(
        "info",
        "auth",
        format!("Deleting SDK store for {user_id}: {}", sdk_dir.display()),
    );
    info!("Deleting SDK store for {user_id}: {}", sdk_dir.display());

    // Give Windows time to release file handles between attempts. The caller
    // already sleeps once after dropping the client; the retries here absorb
    // the remaining lag on slower systems.
    let mut delay = std::time::Duration::from_millis(100);
    let mut last_error = None;
    for attempt in 0..3 {
        if attempt > 0 {
            tokio::time::sleep(delay).await;
            delay *= 2;
        }
        match remove_dir_all_if_exists(&sdk_dir).await {
            Ok(_) => return Ok(()),
            Err(error) => {
                warn!(
                    "Failed to delete SDK store for {user_id} (attempt {}): {error}",
                    attempt + 1
                );
                last_error = Some(error);
            }
        }
    }
    Err(api_err(
        "auth",
        format!(
            "Failed to delete SDK store for {user_id}: {}",
            last_error.unwrap_or_default()
        ),
    ))
}

pub(super) async fn cleanup_removed_account_store(
    user_id: String,
    data_dir: String,
) -> Result<(), String> {
    delete_account_sdk_store(&data_dir, &user_id).await
}

pub(super) async fn remove_dir_all_if_exists(path: &Path) -> Result<bool, String> {
    match tokio::fs::remove_dir_all(path).await {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.to_string()),
    }
}
