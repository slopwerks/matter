//! Connection implementation.

use super::*;

pub(super) fn set_connection_status(status: ConnectionStatus) {
    if let Ok(mut guard) = CONNECTION_STATE.write() {
        // Only a session/account transition may clear terminal authentication
        // failure; an in-flight sync response cannot restore revoked tokens.
        if !matches!(*guard, ConnectionStatus::SessionExpired) {
            *guard = status;
        }
    }
}

pub(super) fn reset_connection_status() {
    let _publication = sync_publication_lock();
    *SESSION_EXPIRY.write().unwrap_or_else(|e| e.into_inner()) = None;
    if let Ok(mut guard) = CONNECTION_STATE.write() {
        *guard = ConnectionStatus::Disconnected;
    }
}

pub(super) fn record_session_expiry(expiry: SessionExpiry) {
    let mut current = SESSION_EXPIRY.write().unwrap_or_else(|e| e.into_inner());
    // A generic missing-token error must not overwrite a known soft logout;
    // an explicit revocation must never be downgraded by a late response.
    *current = Some(current.map_or(expiry, |previous| previous.max(expiry)));
    set_connection_status(ConnectionStatus::SessionExpired);
}

pub(super) fn report_session_error(error: &matrix_sdk::Error) {
    if let Some(expiry) = classify_session_expiry(error) {
        let _publication = sync_publication_lock();
        record_session_expiry(expiry);
    }
}

pub(super) fn report_session_error_for_generation(
    generation: u64,
    error: &matrix_sdk::Error,
) -> bool {
    let Some(expiry) = classify_session_expiry(error) else {
        return false;
    };
    let _publication = sync_publication_lock();
    if SYNC_GENERATION.load(Ordering::SeqCst) == generation {
        record_session_expiry(expiry);
    }
    true
}

pub(super) fn classify_session_expiry(error: &matrix_sdk::Error) -> Option<SessionExpiry> {
    fn http_expiry(error: &matrix_sdk::HttpError, refreshing: bool) -> Option<SessionExpiry> {
        use matrix_sdk::{ruma::api::error::ErrorKind, HttpError, RefreshTokenError};
        match error {
            HttpError::RefreshToken(RefreshTokenError::MatrixAuth(error)) => {
                http_expiry(error, true)
            }
            HttpError::RefreshToken(RefreshTokenError::RefreshTokenRequired) => {
                Some(SessionExpiry::Unknown)
            }
            HttpError::Cached(error) => http_expiry(error, refreshing),
            _ => match error.client_api_error_kind() {
                Some(ErrorKind::UnknownToken(data)) => Some(if data.soft_logout {
                    SessionExpiry::SoftLogout
                } else {
                    SessionExpiry::HardLogout
                }),
                Some(ErrorKind::Forbidden) if refreshing => Some(SessionExpiry::HardLogout),
                Some(ErrorKind::MissingToken) => Some(SessionExpiry::Unknown),
                _ => None,
            },
        }
    }
    match error {
        matrix_sdk::Error::Http(error) => http_expiry(error, false),
        matrix_sdk::Error::AuthenticationRequired => Some(SessionExpiry::Unknown),
        _ => None,
    }
}

#[cfg(test)]
pub(super) fn is_session_expired_error(error: &matrix_sdk::Error) -> bool {
    classify_session_expiry(error).is_some()
}

pub(super) fn advance_sync_generation() -> u64 {
    let _publication = sync_publication_lock();
    SYNC_GENERATION.fetch_add(1, Ordering::SeqCst) + 1
}

pub(super) fn set_connection_status_for_generation(generation: u64, status: ConnectionStatus) {
    let _publication = sync_publication_lock();
    if SYNC_GENERATION.load(Ordering::SeqCst) == generation {
        set_connection_status(status);
    }
}

pub(super) fn notify_sync_event_for_generation(generation: u64, event: SyncEvent) {
    let _publication = sync_publication_lock();
    if SYNC_GENERATION.load(Ordering::SeqCst) == generation {
        notify_sync_event(event);
    }
}

/// Lock the sync-publication mutex, recovering from a poisoned lock so a
/// panic in the (tiny, atomic-only) critical section can never wedge all
/// sync state publication forever.
pub(super) fn sync_publication_lock() -> std::sync::MutexGuard<'static, ()> {
    SYNC_PUBLICATION_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}
