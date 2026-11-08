//! Session tokens implementation.

use super::*;

pub(super) fn install_session_token_callback(client: &Client) -> Result<(), String> {
    client
        .set_session_callbacks(
            Box::new(|client| {
                client
                    .session_tokens()
                    .ok_or_else(|| std::io::Error::other("Session tokens are unavailable").into())
            }),
            Box::new(|client| {
                let session = client
                    .matrix_auth()
                    .session()
                    .ok_or_else(|| std::io::Error::other("Session is unavailable"))?;
                let _ = SESSION_TOKEN_TX.send(SessionTokenUpdate {
                    user_id: session.meta.user_id.to_string(),
                    access_token: session.tokens.access_token,
                    refresh_token: session.tokens.refresh_token,
                });
                Ok(())
            }),
        )
        .map_err(|error| {
            api_err(
                "auth",
                format!("Failed to install session token callback: {error}"),
            )
        })
}

pub(super) fn watch_session_token_updates(
    sink: crate::frb_generated::StreamSink<SessionTokenUpdate>,
) {
    let mut rx = SESSION_TOKEN_TX.subscribe();
    std::thread::spawn(move || loop {
        match rx.blocking_recv() {
            Ok(update) => {
                if sink.add(update).is_err() {
                    break;
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    });
}
