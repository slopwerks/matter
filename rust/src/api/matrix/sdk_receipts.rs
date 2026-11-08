//! Sdk receipts adaptation.
use super::*;

/// Send the read receipts for the room's latest timeline position. Not a
/// read-modify-write (the Timeline guards against moving either marker
/// backwards), so callers may run it outside the mutation queue.
pub(in crate::api::matrix) async fn send_read_receipts(
    client: &Client,
    room: &Room,
) -> Result<(), String> {
    let timeline = get_or_create_timeline(client, room).await?;
    // Receipts are background housekeeping: auto-reads fire on every
    // message refresh while a chat is open. The pagination and receipt
    // HTTP calls run under the client's request config (~30s x 3 retries
    // each), which on a dead network would hold the client lease for the
    // whole 90s outer bound — and concurrent auto-reads would amplify
    // that, blocking logout/account switch. Bound the whole send at 15s:
    // on a healthy network it finishes in well under a second (the
    // window is normally already loaded), and a skipped receipt never
    // corrupts the marker — the Timeline guards backward moves, and the
    // next refresh re-sends.
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        ensure_initial_window(&timeline, 100).await?;
        mark_as_read(&timeline, room).await
    })
    .await
    .map_err(|_| "发送已读回执超时。".to_string())?
}

/// Clear `m.marked_unread` for the room when the local store has it set.
/// The room is being viewed by the user, so any flag that has synced locally
/// is cleared regardless of which device set it — being on screen is the
/// "handled now" signal. The flag is only written when one is actually set:
/// auto-reads fire on every incoming message while the chat is open, so
/// unconditionally writing the flag (and triggering its sync echo +
/// RoomListChanged refresh) would be a per-message write amplification.
/// Failures propagate: an explicit read action must not report success while
/// the server flag survives; the auto path merely logs at its caller.
/// Returns whether a clear was actually issued.
pub(in crate::api::matrix) async fn clear_marked_unread_if_set(
    room: &Room,
) -> Result<bool, String> {
    let raw = room
        .account_data_static::<matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent>()
        .await
        .map_err(|error| format!("读取未读标记失败: {error}"))?;
    let marked_unread = match raw {
        Some(raw) => {
            raw.deserialize()
                .map_err(|error| format!("解析未读标记失败: {error}"))?
                .content
                .unread
        }
        // No `m.marked_unread` account-data event: the flag is not set.
        None => false,
    };
    if marked_unread {
        clear_marked_unread(room).await?;
        Ok(true)
    } else {
        Ok(false)
    }
}

pub(in crate::api::matrix) async fn mark_as_read(
    timeline: &Timeline,
    room: &Room,
) -> Result<(), String> {
    // The Timeline guards against moving either marker backwards.
    match timeline.mark_as_read(ReceiptType::Read).await {
        Ok(sent) => {
            if sent {
                super::super::app_log(
                    "info",
                    "receipts",
                    format!("Sent explicit read receipt for room {}", room.room_id()),
                );
            }
            Ok(())
        }
        Err(error) => {
            let error = error.to_string();
            super::super::app_log(
                "warn",
                "receipts",
                format!(
                    "Failed to send explicit read receipt for room {}: {error}",
                    room.room_id()
                ),
            );
            Err(format!("标记房间已读失败（已读回执）: {error}"))
        }
    }?;
    // The fully-read marker is best-effort: the read receipt above carries
    // the user-visible read state, and a failed marker update must not turn
    // a successful read into an error — the auto-read path fires on every
    // message refresh while the room is open, so an error here would repeat
    // on every refresh for a marker the user never sees. Log and move on.
    if let Err(error) = timeline.mark_as_read(ReceiptType::FullyRead).await {
        super::super::app_log(
            "warn",
            "receipts",
            format!(
                "Failed to update fully-read marker for room {}: {error}",
                room.room_id()
            ),
        );
    }
    Ok(())
}

/// Drop the explicit `m.marked_unread` flag for an explicit read action.
pub(in crate::api::matrix) async fn clear_marked_unread(room: &Room) -> Result<(), String> {
    use matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent;

    room.set_account_data(MarkedUnreadEventContent::new(false))
        .await
        .map(|_| ())
        .map_err(|error| format!("清除未读标记失败: {error}"))
}
