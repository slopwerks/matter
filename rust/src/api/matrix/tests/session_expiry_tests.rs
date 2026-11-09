use super::{classify_session_expiry, is_session_expired_error, SessionExpiry};
use matrix_sdk::{
    ruma::api::{
        client::uiaa::UiaaResponse,
        error::{ErrorBody, FromHttpResponseError},
    },
    HttpError, RefreshTokenError,
};
use std::sync::Arc;

fn http_error(code: &str, status: u16) -> HttpError {
    http_error_with_soft_logout(code, status, true)
}

fn http_error_with_soft_logout(code: &str, status: u16, soft_logout: bool) -> HttpError {
    let body = serde_json::from_value(serde_json::json!({
        "errcode": code, "error": "test error", "soft_logout": soft_logout,
    }))
    .unwrap();
    HttpError::Api(Box::new(FromHttpResponseError::Server(
        UiaaResponse::MatrixError(ErrorBody::Standard(body).into_error(status.try_into().unwrap())),
    )))
}

fn refresh_error(code: &str, status: u16) -> matrix_sdk::Error {
    matrix_sdk::Error::Http(Box::new(HttpError::RefreshToken(
        RefreshTokenError::MatrixAuth(Arc::new(http_error(code, status))),
    )))
}

#[test]
fn rejected_refresh_token_is_terminal_but_room_forbidden_is_not() {
    assert!(is_session_expired_error(&refresh_error("M_FORBIDDEN", 403)));
    assert!(is_session_expired_error(&refresh_error(
        "M_UNKNOWN_TOKEN",
        401
    )));
    assert!(is_session_expired_error(&matrix_sdk::Error::Http(
        Box::new(http_error("M_UNKNOWN_TOKEN", 401))
    )));
    assert!(!is_session_expired_error(&matrix_sdk::Error::Http(
        Box::new(http_error("M_FORBIDDEN", 403))
    )));
    assert!(!is_session_expired_error(&refresh_error(
        "M_LIMIT_EXCEEDED",
        429
    )));
    assert!(!is_session_expired_error(&refresh_error("M_UNKNOWN", 500)));
}

#[test]
fn missing_access_token_is_terminal_with_or_without_refresh() {
    assert!(is_session_expired_error(&matrix_sdk::Error::Http(
        Box::new(http_error("M_MISSING_TOKEN", 401))
    )));
    assert!(is_session_expired_error(&refresh_error(
        "M_MISSING_TOKEN",
        401
    )));
}

#[test]
fn only_explicit_soft_logout_allows_device_reuse() {
    for (soft_logout, expected) in [
        (true, SessionExpiry::SoftLogout),
        (false, SessionExpiry::HardLogout),
    ] {
        let error = matrix_sdk::Error::Http(Box::new(HttpError::Cached(Arc::new(
            http_error_with_soft_logout("M_UNKNOWN_TOKEN", 401, soft_logout),
        ))));
        assert_eq!(classify_session_expiry(&error), Some(expected));
    }
    assert_eq!(
        classify_session_expiry(&refresh_error("M_UNKNOWN_TOKEN", 401)),
        Some(SessionExpiry::SoftLogout)
    );
    assert_eq!(
        classify_session_expiry(&refresh_error("M_FORBIDDEN", 403)),
        Some(SessionExpiry::HardLogout)
    );
    assert_eq!(
        classify_session_expiry(&refresh_error("M_MISSING_TOKEN", 401)),
        Some(SessionExpiry::Unknown)
    );
}
