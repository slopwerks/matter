use flutter_rust_bridge::frb;
use log::{info, warn};
use matrix_sdk::{
    authentication::matrix::MatrixSession,
    encryption::{
        recovery::RecoveryState,
        verification::{Verification, VerificationRequestState},
        BackupDownloadStrategy, EncryptionSettings, VerificationState as OwnVerificationState,
    },
    ruma::api::client::{
        account::register::v3::Request as RegistrationRequest,
        uiaa::{AuthData, Dummy, RegistrationToken, UiaaInfo},
    },
    ruma::events::{
        key::verification::{request::ToDeviceKeyVerificationRequestEvent, VerificationMethod},
        receipt::SyncReceiptEvent,
        room::message::OriginalSyncRoomMessageEvent,
    },
    store::RoomLoadSettings,
    Client, Room, SessionMeta, SessionTokens,
};
use once_cell::sync::Lazy;
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::io::{Cursor, Read};
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;
use tokio::sync::{Mutex, RwLock};
use tokio::task::JoinHandle;

mod sdk_timeline;

// ── App-wide log system ─────────────────────────────────────────────

/// A single log entry visible to the user.
#[frb]
#[derive(Clone, Debug)]
pub struct AppLogEntry {
    /// Milliseconds since Unix epoch
    pub timestamp: i64,
    /// log / warn / error
    pub level: String,
    /// What subsystem: sync, auth, rooms, media, etc.
    pub tag: String,
    /// The actual message
    pub message: String,
}

static APP_LOG_TX: Lazy<tokio::sync::broadcast::Sender<AppLogEntry>> =
    Lazy::new(|| tokio::sync::broadcast::channel(LOG_RING_CAP).0);

/// Ring buffer that keeps the last 5,000 log entries so late-joining
/// subscribers (Dart) can retrieve them via `get_recent_logs()`.
static LOG_RING: Lazy<std::sync::Mutex<VecDeque<AppLogEntry>>> =
    Lazy::new(|| std::sync::Mutex::new(VecDeque::new()));
const LOG_RING_CAP: usize = 5_000;

/// Directory where logs are persisted (`{data_dir}/logs`), set once the first
/// client is created or restored.
static LOG_DIR: Lazy<std::sync::RwLock<Option<std::path::PathBuf>>> =
    Lazy::new(|| std::sync::RwLock::new(None));

/// Open handle to the current log file plus its size so writes can trigger
/// rotation. Writes are appended and flushed per entry so a crash loses at
/// most the line being written.
struct ActiveLogFile {
    file: std::fs::File,
    written: u64,
}

static LOG_FILE: Lazy<std::sync::Mutex<Option<ActiveLogFile>>> =
    Lazy::new(|| std::sync::Mutex::new(None));

/// Rotate `matter.log` to a single `matter.log.1` backup past this size.
const LOG_FILE_MAX_BYTES: u64 = 10 * 1024 * 1024;

/// Point log persistence at `{data_dir}/logs`, rotating an oversized log.
/// Called when a client is created or restored; safe to call repeatedly.
fn init_log_store(data_dir: &str) {
    let log_dir = std::path::Path::new(data_dir).join("logs");
    if let Err(e) = std::fs::create_dir_all(&log_dir) {
        warn!("Failed to create log dir {}: {e}", log_dir.display());
        return;
    }
    let path = log_dir.join("matter.log");
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() > LOG_FILE_MAX_BYTES {
            let _ = std::fs::rename(&path, log_dir.join("matter.log.1"));
        }
    }
    let written = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        Ok(file) => {
            if let Ok(mut dir) = LOG_DIR.write() {
                *dir = Some(log_dir);
            }
            if let Ok(mut guard) = LOG_FILE.lock() {
                *guard = Some(ActiveLogFile { file, written });
            }
        }
        Err(e) => warn!("Failed to open log file {}: {e}", path.display()),
    }
}

/// Format epoch milliseconds as `YYYY-MM-DDTHH:MM:SSZ` (UTC) without pulling
/// in a date library.
fn format_utc(millis: i64) -> String {
    let secs = millis.div_euclid(1000);
    let day_secs = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(secs.div_euclid(86_400));
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        day_secs / 3600,
        (day_secs % 3600) / 60,
        day_secs % 60
    )
}

/// Howard Hinnant's civil-from-days algorithm: days since Unix epoch →
/// (year, month, day).
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn app_log(level: &str, tag: &str, message: String) {
    let ts = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let entry = AppLogEntry {
        timestamp: ts,
        level: level.to_string(),
        tag: tag.to_string(),
        message,
    };
    // Also print to Android logcat
    match level {
        "error" => log::error!("[{}] {}", tag, entry.message),
        "warn" => log::warn!("[{}] {}", tag, entry.message),
        _ => log::info!("[{}] {}", tag, entry.message),
    }
    // Push to broadcast (live listeners)
    let _ = APP_LOG_TX.send(entry.clone());
    // Persist to the log file (survives restarts, not limited by the ring cap)
    if let Ok(mut guard) = LOG_FILE.lock() {
        if let Some(active) = guard.as_mut() {
            use std::io::Write as _;
            let line = format!(
                "{} [{}] [{}] {}\n",
                format_utc(ts),
                level.to_uppercase(),
                tag,
                entry.message.replace('\n', "\n    ")
            );
            let _ = active.file.write_all(line.as_bytes());
            let _ = active.file.flush();
            active.written += line.len() as u64;
            if active.written > LOG_FILE_MAX_BYTES {
                // Close the handle before renaming (required on Windows).
                guard.take();
                if let Some(dir) = LOG_DIR.read().ok().and_then(|d| d.clone()) {
                    let path = dir.join("matter.log");
                    let _ = std::fs::rename(&path, dir.join("matter.log.1"));
                    if let Ok(file) = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&path)
                    {
                        *guard = Some(ActiveLogFile { file, written: 0 });
                    }
                }
            }
        }
    }
    // Push to ring buffer (for get_recent_logs)
    if let Ok(mut ring) = LOG_RING.lock() {
        if ring.len() >= LOG_RING_CAP {
            ring.pop_front();
        }
        ring.push_back(entry);
    }
}

/// Stream app log entries from Rust → Dart (live).
#[frb]
pub fn watch_app_logs(sink: crate::frb_generated::StreamSink<AppLogEntry>) {
    let mut rx = APP_LOG_TX.subscribe();
    std::thread::spawn(move || {
        loop {
            match rx.blocking_recv() {
                Ok(entry) => {
                    if sink.add(entry).is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    // Continue listening; the ring buffer remains available for export.
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}

/// Retrieve all buffered logs (up to 5,000 entries).
/// Call this once after connecting the stream to show historical logs.
#[frb(sync)]
pub fn get_recent_logs() -> Vec<AppLogEntry> {
    if let Ok(ring) = LOG_RING.lock() {
        ring.iter().cloned().collect()
    } else {
        vec![]
    }
}

/// Clear the buffered diagnostic logs.
#[frb(sync)]
pub fn clear_app_logs() {
    if let Ok(mut ring) = LOG_RING.lock() {
        ring.clear();
    }
}

/// A persisted log file's name and contents.
pub struct LogFileContent {
    pub name: String,
    pub content: String,
}

/// Read the persisted app logs (`matter.log` and its rotated backup), oldest
/// first, for the log bundle export. Unlike `get_recent_logs`, these are not
/// limited to the 5,000-entry ring buffer.
#[frb]
pub async fn read_log_files() -> Vec<LogFileContent> {
    let dir = LOG_DIR.read().ok().and_then(|d| d.clone());
    let Some(dir) = dir else { return vec![] };
    let mut files = Vec::new();
    for name in ["matter.log.1", "matter.log"] {
        if let Ok(content) = tokio::fs::read_to_string(dir.join(name)).await {
            files.push(LogFileContent {
                name: name.to_string(),
                content,
            });
        }
    }
    files
}

// ── Connection state tracking ──────────────────────────────────────

static CONNECTION_STATE: Lazy<std::sync::RwLock<ConnectionStatus>> =
    Lazy::new(|| std::sync::RwLock::new(ConnectionStatus::Disconnected));

fn set_connection_status(status: ConnectionStatus) {
    if let Ok(mut guard) = CONNECTION_STATE.write() {
        *guard = status;
    }
}

// ── Event bus for real-time updates ─────────────────────────────────

/// Events pushed from Rust → Dart when something changes.
#[derive(Clone, Debug)]
pub enum SyncEvent {
    /// A sync cycle completed (rooms may have new messages).
    SyncCompleted,
    /// A message was sent (room list should refresh).
    MessageSent { room_id: String },
}

static SYNC_EVENT_TX: Lazy<tokio::sync::broadcast::Sender<SyncEvent>> = Lazy::new(|| {
    let (tx, _rx) = tokio::sync::broadcast::channel(64);
    tx
});

#[frb]
#[derive(Clone, Debug)]
pub struct SessionTokenUpdate {
    pub user_id: String,
    pub access_token: String,
    pub refresh_token: Option<String>,
}

static SESSION_TOKEN_TX: Lazy<tokio::sync::broadcast::Sender<SessionTokenUpdate>> =
    Lazy::new(|| tokio::sync::broadcast::channel(16).0);

fn notify_sync_event(event: SyncEvent) {
    let _ = SYNC_EVENT_TX.send(event);
}

fn install_session_token_callback(client: &Client) -> Result<(), String> {
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
        .map_err(|error| format!("Failed to install session token callback: {error}"))
}

#[frb]
pub fn watch_session_token_updates(sink: crate::frb_generated::StreamSink<SessionTokenUpdate>) {
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

async fn clear_timeline_cache() {
    sdk_timeline::clear_all().await;
}

// ── Multi-account store ──────────────────────────────────────────────

struct ClientEntry {
    client: Client,
    data_dir: String,
}

struct PendingEntry {
    client: Client,
    data_dir: String,
    homeserver_url: String,
}

/// All logged-in accounts, keyed by user_id.
static CLIENTS: Lazy<Arc<RwLock<HashMap<String, ClientEntry>>>> =
    Lazy::new(|| Arc::new(RwLock::new(HashMap::new())));

/// Currently active account.
static ACTIVE_USER: Lazy<Arc<RwLock<Option<String>>>> = Lazy::new(|| Arc::new(RwLock::new(None)));

struct SyncTask {
    user_id: String,
    handle: JoinHandle<()>,
}

/// Exactly one account owns the app-wide background sync task at a time.
static SYNC_TASK: Lazy<Mutex<Option<SyncTask>>> = Lazy::new(|| Mutex::new(None));

/// Runtime Sliding Sync subscription state for mounted room screens.
///
/// Both the live `SlidingSync` handle and the rooms the Dart side wants
/// subscribed live behind a single lock, so route lifetimes and the sync
/// loop's (re)build/replay observe one consistent set. Without an explicit
/// subscription, a room with no
/// recent timeline activity may be absent from sync responses, so its
/// read-receipt deltas get dropped by the receipts extension (which only
/// processes rooms present in the response). Subscribing the active room keeps
/// it in every sync roundtrip — critical on homeservers (e.g. Tuwunel) whose
/// Sliding Sync receipt extension only emits per-room receipts when the room
/// is part of the response.
struct RoomSubscriptionState {
    /// Mounted chat screens by room. Counts distinguish overlapping routes for
    /// the same room so disposing an older route cannot cancel a newer one.
    desired: HashMap<String, usize>,
    /// The live Sliding Sync instance, present once the sync loop has built
    /// one (and reset to `None` when it's stopped).
    active: Option<matrix_sdk::sliding_sync::SlidingSync>,
}

static ROOM_SUBSCRIPTION: Lazy<tokio::sync::Mutex<RoomSubscriptionState>> = Lazy::new(|| {
    tokio::sync::Mutex::new(RoomSubscriptionState {
        desired: HashMap::new(),
        active: None,
    })
});

impl RoomSubscriptionState {
    fn add_desired(&mut self, room_id: &str) -> bool {
        let count = self.desired.entry(room_id.to_owned()).or_default();
        *count += 1;
        *count == 1
    }

    fn remove_desired(&mut self, room_id: &str) -> bool {
        let Some(count) = self.desired.get_mut(room_id) else {
            return false;
        };
        *count -= 1;
        if *count > 0 {
            return false;
        }
        self.desired.remove(room_id);
        true
    }
}

fn receipt_extension_for_subscribed_rooms(
) -> matrix_sdk::ruma::api::client::sync::sync_events::v5::request::Receipts {
    use matrix_sdk::ruma::api::client::sync::sync_events::v5::request::{
        ExtensionRoomConfig, Receipts,
    };

    let mut receipts = Receipts::default();
    receipts.enabled = Some(true);
    receipts.rooms = Some(vec![ExtensionRoomConfig::AllSubscribed]);
    receipts
}

#[cfg(test)]
mod room_subscription_tests {
    use super::{receipt_extension_for_subscribed_rooms, RoomSubscriptionState};
    use std::collections::HashMap;

    fn state() -> RoomSubscriptionState {
        RoomSubscriptionState {
            desired: HashMap::new(),
            active: None,
        }
    }

    #[test]
    fn duplicate_routes_only_unsubscribe_after_the_last_owner() {
        let mut state = state();
        assert!(state.add_desired("!room:example.org"));
        assert!(!state.add_desired("!room:example.org"));
        assert!(!state.remove_desired("!room:example.org"));
        assert!(state.desired.contains_key("!room:example.org"));
        assert!(state.remove_desired("!room:example.org"));
        assert!(!state.desired.contains_key("!room:example.org"));
    }

    #[test]
    fn stacked_rooms_are_tracked_independently() {
        let mut state = state();
        assert!(state.add_desired("!first:example.org"));
        assert!(state.add_desired("!second:example.org"));
        assert!(state.remove_desired("!second:example.org"));
        assert!(state.desired.contains_key("!first:example.org"));
    }

    #[test]
    fn receipt_extension_requests_all_subscribed_rooms() {
        assert_eq!(
            serde_json::to_value(receipt_extension_for_subscribed_rooms()).unwrap(),
            serde_json::json!({"enabled": true, "rooms": ["*"]}),
        );
    }
}

async fn stop_sync_task(user_id: Option<&str>) {
    let mut task = SYNC_TASK.lock().await;
    let should_stop = task
        .as_ref()
        .is_some_and(|running| user_id.is_none_or(|id| running.user_id == id));
    if should_stop {
        if let Some(running) = task.take() {
            running.handle.abort();
            app_log(
                "info",
                "sync",
                format!("Stopped sync loop for user {}", running.user_id),
            );
        }
        // Drop the published Sliding Sync handle and the desired room so
        // stale subscribers can't route room subscriptions to a dead
        // instance, and a later session doesn't replay an old room.
        let mut sub = ROOM_SUBSCRIPTION.lock().await;
        sub.active = None;
        sub.desired.clear();
    }
}

/// Temporary client during login (before we know the user_id for a per-user dir).
static PENDING: Lazy<Arc<RwLock<Option<PendingEntry>>>> = Lazy::new(|| Arc::new(RwLock::new(None)));

#[derive(Clone, Debug)]
struct VerificationSession {
    user_id: String,
    device_id: String,
    flow_id: String,
    incoming: bool,
    accepted: bool,
}

static VERIFICATION_SESSION: Lazy<Arc<RwLock<Option<VerificationSession>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

fn install_verification_event_handler(client: &Client) {
    client.add_event_handler(
        |event: ToDeviceKeyVerificationRequestEvent, client: Client| async move {
            let Some(own_user_id) = client.user_id() else {
                return;
            };
            if event.sender != own_user_id {
                return;
            }

            let session = VerificationSession {
                user_id: event.sender.to_string(),
                device_id: event.content.from_device.to_string(),
                flow_id: event.content.transaction_id.to_string(),
                incoming: true,
                accepted: false,
            };
            *VERIFICATION_SESSION.write().await = Some(session);
            app_log(
                "info",
                "encryption",
                "Received a device verification request".to_string(),
            );
        },
    );
}

fn install_live_update_event_handlers(client: &Client) {
    client.add_event_handler(
        |_event: OriginalSyncRoomMessageEvent, room: Room| async move {
            notify_sync_event(SyncEvent::MessageSent {
                room_id: room.room_id().to_string(),
            });
        },
    );

    client.add_event_handler(|event: SyncReceiptEvent, room: Room| async move {
        let room_id = room.room_id().to_string();
        let public_receipt_count = event
            .content
            .values()
            .filter_map(|receipts| {
                receipts.get(&matrix_sdk::ruma::events::receipt::ReceiptType::Read)
            })
            .map(|receipts| receipts.len())
            .sum::<usize>();
        app_log(
            "info",
            "receipts",
            format!(
                "Received explicit receipt event for room {room_id}: {} public receipt(s)",
                public_receipt_count
            ),
        );
        notify_sync_event(SyncEvent::MessageSent { room_id });
    });
}

fn encryption_settings() -> EncryptionSettings {
    EncryptionSettings {
        backup_download_strategy: BackupDownloadStrategy::AfterDecryptionFailure,
        ..Default::default()
    }
}

async fn wait_for_e2ee_initialization(client: &Client, context: &str) {
    client
        .encryption()
        .wait_for_e2ee_initialization_tasks()
        .await;
    app_log(
        "info",
        "encryption",
        format!("E2EE initialization completed after {context}"),
    );
}

fn install_room_key_event_handler(client: &Client) {
    let client = client.clone();
    tokio::spawn(async move {
        let Some(mut stream) = client.encryption().room_keys_received_stream().await else {
            app_log(
                "warn",
                "encryption",
                "Room-key stream unavailable; encrypted history may need a restart to refresh"
                    .to_string(),
            );
            return;
        };

        use futures_util::StreamExt;
        while let Some(update) = stream.next().await {
            match update {
                Ok(keys) => {
                    if keys.is_empty() {
                        continue;
                    }
                    let rooms = keys
                        .iter()
                        .map(|key| key.room_id.to_string())
                        .collect::<BTreeSet<_>>();
                    app_log(
                        "info",
                        "encryption",
                        format!(
                            "Received {} room keys for {} rooms; refreshing affected timelines",
                            keys.len(),
                            rooms.len()
                        ),
                    );
                    for room_id in rooms {
                        notify_sync_event(SyncEvent::MessageSent { room_id });
                    }
                }
                Err(error) => {
                    app_log(
                        "warn",
                        "encryption",
                        format!(
                            "Room-key stream lagged ({error}); refreshing visible encrypted timelines"
                        ),
                    );
                    notify_sync_event(SyncEvent::SyncCompleted);
                }
            }
        }
    });
}

fn sanitize_for_path(s: &str) -> String {
    s.replace('@', "_at_")
        .replace(':', "_colon_")
        .replace('/', "_slash_")
        .replace('\\', "_backslash_")
}

/// Build per-user directory: `{base}/accounts/{sanitized_user_id}/`
/// or the pending directory: `{base}/_pending/`
fn build_sdk_data_dir(base: &str, user_id: Option<&str>) -> std::path::PathBuf {
    match user_id {
        Some(uid) => std::path::PathBuf::from(base)
            .join("accounts")
            .join(sanitize_for_path(uid)),
        None => std::path::PathBuf::from(base).join("_pending"),
    }
}

/// Return the currently active client, or the pending one if no account is active yet.
async fn get_client() -> Option<Client> {
    let active = ACTIVE_USER.read().await;
    if let Some(user_id) = active.as_ref() {
        let clients = CLIENTS.read().await;
        clients.get(user_id).map(|e| e.client.clone())
    } else {
        PENDING.read().await.as_ref().map(|p| p.client.clone())
    }
}

/// After a successful auth on the pending client, migrate it to a per-user store.
async fn finalize_pending() -> Result<String, String> {
    let (pending_client, data_dir, homeserver_url) = {
        let pending = PENDING.read().await;
        let p = pending.as_ref().ok_or("No pending client to finalize")?;
        (
            p.client.clone(),
            p.data_dir.clone(),
            p.homeserver_url.clone(),
        )
    };

    let auth = pending_client.matrix_auth();
    if !auth.logged_in() {
        return Err("Pending client is not logged in".into());
    }
    let session = auth.session().ok_or("No session in pending client")?;
    let user_id = session.meta.user_id.to_string();
    let matrix_session = MatrixSession {
        meta: SessionMeta {
            user_id: session.meta.user_id.clone(),
            device_id: session.meta.device_id.clone(),
        },
        tokens: SessionTokens {
            access_token: session.tokens.access_token.clone(),
            refresh_token: session.tokens.refresh_token.clone(),
        },
    };
    drop(auth);

    app_log(
        "info",
        "auth",
        format!("finalize_pending: starting for user {}", user_id),
    );
    info!("finalize_pending: starting for user {}", user_id);

    // Build per-user directory
    let sdk_dir = build_sdk_data_dir(&data_dir, Some(&user_id));

    // A password login creates the crypto identity in the pending store. Keep
    // that exact store: rebuilding an empty store with the same Matrix device
    // ID discards the Olm account and makes encrypted messages undecryptable.
    stop_sync_task(Some(&user_id)).await;
    {
        let mut clients = CLIENTS.write().await;
        clients.remove(&user_id);
    }

    // Release every reference before moving SQLite files (required on Windows
    // and avoids moving a database while WAL writes are still in flight).
    {
        let mut pending = PENDING.write().await;
        *pending = None;
    }
    drop(pending_client);
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    let temp_dir = build_sdk_data_dir(&data_dir, None);
    let accounts_dir = sdk_dir
        .parent()
        .ok_or_else(|| "Invalid account store path".to_string())?;
    tokio::fs::create_dir_all(accounts_dir)
        .await
        .map_err(|e| format!("Failed to create accounts directory: {e}"))?;
    let previous_dir = sdk_dir.with_extension("previous");
    remove_dir_all_if_exists(&previous_dir)
        .await
        .map_err(|e| format!("Failed to remove stale account store backup: {e}"))?;
    let had_previous_store = sdk_dir.exists();
    if had_previous_store {
        tokio::fs::rename(&sdk_dir, &previous_dir)
            .await
            .map_err(|e| format!("Failed to preserve existing account store: {e}"))?;
    }
    if let Err(error) = tokio::fs::rename(&temp_dir, &sdk_dir).await {
        if had_previous_store {
            let _ = tokio::fs::rename(&previous_dir, &sdk_dir).await;
        }
        return Err(format!("Failed to migrate encryption store: {error}"));
    }

    // Create a new client in the per-user directory
    let url = url::Url::parse(&homeserver_url).map_err(|e| format!("Invalid URL: {e}"))?;
    app_log(
        "info",
        "auth",
        format!("finalize_pending: creating client in {}", sdk_dir.display()),
    );
    info!("finalize_pending: creating client in {}", sdk_dir.display());
    let new_client = match Client::builder()
        .handle_refresh_tokens()
        .homeserver_url(url)
        .with_encryption_settings(encryption_settings())
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
    {
        Ok(client) => client,
        Err(error) => {
            let _ = remove_dir_all_if_exists(&sdk_dir).await;
            if had_previous_store {
                let _ = tokio::fs::rename(&previous_dir, &sdk_dir).await;
            }
            return Err(format!("Failed to create per-user client: {error}"));
        }
    };
    install_session_token_callback(&new_client)?;

    app_log(
        "info",
        "auth",
        format!("finalize_pending: restoring session for {}", user_id),
    );
    info!("finalize_pending: restoring session for {}", user_id);
    if let Err(error) = new_client
        .matrix_auth()
        .restore_session(matrix_session, RoomLoadSettings::default())
        .await
    {
        drop(new_client);
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        let _ = remove_dir_all_if_exists(&sdk_dir).await;
        if had_previous_store {
            let _ = tokio::fs::rename(&previous_dir, &sdk_dir).await;
        }
        return Err(format!("Restore session in per-user store: {error}"));
    }
    if had_previous_store {
        if let Err(error) = remove_dir_all_if_exists(&previous_dir).await {
            warn!("Failed to remove previous account store: {error}");
        }
    }
    wait_for_e2ee_initialization(&new_client, "login finalization").await;
    app_log(
        "info",
        "auth",
        format!("finalize_pending: session restored for {}", user_id),
    );
    info!("finalize_pending: session restored for {}", user_id);
    install_verification_event_handler(&new_client);
    install_live_update_event_handlers(&new_client);
    install_room_key_event_handler(&new_client);

    // Store in the multi-account map
    {
        let mut clients = CLIENTS.write().await;
        clients.insert(
            user_id.clone(),
            ClientEntry {
                client: new_client,
                data_dir: data_dir.clone(),
            },
        );
    }

    // Set as active
    {
        let mut active = ACTIVE_USER.write().await;
        *active = Some(user_id.clone());
    }

    app_log("info", "auth", format!("Account finalized: {}", user_id));
    info!("Account finalized: {}", user_id);
    Ok(user_id)
}

// ── FRB data types ───────────────────────────────────────────────────

#[frb]
#[derive(Clone, Debug)]
pub enum ConnectionStatus {
    Connected,
    Connecting,
    Updating,
    Disconnected,
}

#[frb]
#[derive(Clone, Debug)]
pub struct ChatRoom {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
    pub last_message: String,
    pub last_message_sender: Option<String>,
    pub last_message_time: String,
    pub unread_count: i32,
    /// "dm", "group", or "space"
    pub room_type: String,
    pub is_encrypted: bool,
    /// "joined", "invited", "knocked", "left", or "banned"
    pub room_state: String,
}

#[frb]
#[derive(Clone, Debug)]
pub struct StickerPack {
    pub id: String,
    pub title: String,
    pub avatar_url: Option<String>,
    /// "room" or "user"
    pub source: String,
    pub stickers: Vec<Sticker>,
}

#[frb]
#[derive(Clone, Debug)]
pub struct Sticker {
    pub id: String,
    pub shortcode: String,
    pub body: String,
    pub image_url: String,
    pub thumbnail_url: Option<String>,
    pub mime_type: Option<String>,
    pub width: Option<i32>,
    pub height: Option<i32>,
}

#[frb]
#[derive(Clone, Debug)]
pub struct Space {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
}

#[frb]
#[derive(Clone, Debug)]
pub struct SpaceDetails {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
    pub topic: Option<String>,
}

#[frb]
#[derive(Clone, Debug)]
pub struct Contact {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
    pub status: String,
}

async fn room_to_chat_room(room: &matrix_sdk::Room) -> ChatRoom {
    let room_id = room.room_id().to_string();
    let mut name = room.name().filter(|n| !n.is_empty()).unwrap_or_default();
    if name.is_empty() {
        name = room
            .cached_display_name()
            .map(|dn| dn.to_string())
            .unwrap_or_default();
    }
    name = name.trim().to_string();
    if name.is_empty() {
        name = room_id.clone();
    }

    let avatar_url = room.avatar_url().map(|u| u.to_string());
    let unread_count = room.unread_notification_counts().notification_count as i32;
    let (last_message, last_message_sender_id, last_message_time) = get_last_message_info(room);
    let last_message_sender = if let Some(sender_id) = last_message_sender_id {
        let is_me = room
            .client()
            .user_id()
            .is_some_and(|user_id| user_id.as_str() == sender_id);
        if is_me {
            Some("我".to_string())
        } else {
            let fallback = sender_id
                .split(':')
                .next()
                .unwrap_or(&sender_id)
                .trim_start_matches('@')
                .to_string();
            match matrix_sdk::ruma::UserId::parse(&sender_id) {
                Ok(user_id) => room
                    .get_member_no_sync(&user_id)
                    .await
                    .ok()
                    .flatten()
                    .map(|member| member.name().to_string())
                    .or(Some(fallback)),
                Err(_) => Some(fallback),
            }
        }
    } else {
        None
    };
    let room_type = if room.is_space() {
        "space".to_string()
    } else {
        "group".to_string()
    };
    let is_encrypted = room
        .latest_encryption_state()
        .await
        .map(|state| state.is_encrypted())
        .unwrap_or(true);

    ChatRoom {
        id: room_id,
        name,
        avatar_url,
        last_message,
        last_message_sender,
        last_message_time,
        unread_count,
        room_type,
        is_encrypted,
        room_state: room_state_label(room.state()).to_string(),
    }
}

fn room_state_label(state: matrix_sdk::RoomState) -> &'static str {
    match state {
        matrix_sdk::RoomState::Joined => "joined",
        matrix_sdk::RoomState::Invited => "invited",
        matrix_sdk::RoomState::Knocked => "knocked",
        matrix_sdk::RoomState::Left => "left",
        matrix_sdk::RoomState::Banned => "banned",
    }
}

fn room_display_name(room: &matrix_sdk::Room) -> String {
    let room_id = room.room_id().to_string();
    let mut name = room.name().filter(|n| !n.is_empty()).unwrap_or_default();
    if name.is_empty() {
        name = room
            .cached_display_name()
            .map(|dn| dn.to_string())
            .unwrap_or_default();
    }
    name = name.trim().to_string();
    if name.is_empty() {
        room_id
    } else {
        name
    }
}

fn usage_allows_sticker(usage: &BTreeSet<ruma::events::image_pack::PackUsage>) -> bool {
    usage.is_empty() || usage.contains(&ruma::events::image_pack::PackUsage::Sticker)
}

fn uint_to_i32(value: Option<matrix_sdk::ruma::UInt>) -> Option<i32> {
    value.map(|value| i32::try_from(u64::from(value)).unwrap_or(i32::MAX))
}

fn image_info_dimensions(
    info: Option<&Box<matrix_sdk::ruma::events::room::ImageInfo>>,
) -> (Option<i32>, Option<i32>) {
    info.map(|info| (uint_to_i32(info.width), uint_to_i32(info.height)))
        .unwrap_or((None, None))
}

fn sticker_info_dimensions(
    info: &matrix_sdk::ruma::events::room::ImageInfo,
) -> (Option<i32>, Option<i32>) {
    (uint_to_i32(info.width), uint_to_i32(info.height))
}

fn pack_image_to_sticker(
    shortcode: String,
    image: ruma::events::image_pack::PackImage,
    pack_allows_sticker: bool,
) -> Option<Sticker> {
    let image_allows_sticker = if image.usage.is_empty() {
        pack_allows_sticker
    } else {
        usage_allows_sticker(&image.usage)
    };
    if !image_allows_sticker {
        return None;
    }

    let body = image
        .body
        .as_deref()
        .map(str::trim)
        .filter(|body| !body.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| shortcode.clone());
    let image_url = image.url.to_string();
    let thumbnail_url = None;
    let mime_type = image.info.as_ref().and_then(|info| info.mimetype.clone());
    let width = image.info.as_ref().and_then(|info| uint_to_i32(info.width));
    let height = image
        .info
        .as_ref()
        .and_then(|info| uint_to_i32(info.height));

    Some(Sticker {
        id: shortcode.clone(),
        shortcode,
        body,
        image_url,
        thumbnail_url,
        mime_type,
        width,
        height,
    })
}

fn room_image_pack_to_sticker_pack(
    room: &matrix_sdk::Room,
    state_key: String,
    content: ruma::events::image_pack::RoomImagePackEventContent,
) -> Option<StickerPack> {
    let pack_allows_sticker = content
        .pack
        .as_ref()
        .is_none_or(|pack| usage_allows_sticker(&pack.usage));
    let mut stickers = content
        .images
        .into_iter()
        .filter_map(|(shortcode, image)| {
            pack_image_to_sticker(shortcode, image, pack_allows_sticker)
        })
        .collect::<Vec<_>>();
    if stickers.is_empty() {
        return None;
    }
    stickers.sort_by_key(|a| a.body.to_lowercase());

    let title = content
        .pack
        .as_ref()
        .and_then(|pack| pack.display_name.as_deref())
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| {
            let trimmed = state_key.trim();
            if trimmed.is_empty() {
                room_display_name(room)
            } else {
                trimmed.to_string()
            }
        });
    let avatar_url = content
        .pack
        .as_ref()
        .and_then(|pack| pack.avatar_url.as_ref().map(ToString::to_string))
        .or_else(|| room.avatar_url().map(|url| url.to_string()));
    let normalized_state_key = if state_key.trim().is_empty() {
        "default".to_string()
    } else {
        state_key
    };

    Some(StickerPack {
        id: format!("room:{}:{normalized_state_key}", room.room_id()),
        title,
        avatar_url,
        source: "room".to_string(),
        stickers,
    })
}

async fn load_room_sticker_packs(
    room: &matrix_sdk::Room,
    enabled_state_keys: Option<&std::collections::HashSet<String>>,
) -> Result<Vec<StickerPack>, String> {
    let room_pack_events = room
        .get_state_events_static::<ruma::events::image_pack::RoomImagePackEventContent>()
        .await
        .map_err(|e| {
            format!(
                "Failed to load sticker packs for room {}: {e}",
                room.room_id()
            )
        })?;

    let mut packs = Vec::new();
    for raw_pack in room_pack_events {
        let Ok(pack_event) = raw_pack.deserialize() else {
            continue;
        };
        let (state_key, content) = match pack_event {
            matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
                matrix_sdk::ruma::events::SyncStateEvent::Original(event),
            ) => (event.state_key, event.content),
            _ => continue,
        };

        if let Some(enabled_state_keys) = enabled_state_keys {
            if !enabled_state_keys.contains(state_key.as_str()) {
                continue;
            }
        }

        if let Some(pack) = room_image_pack_to_sticker_pack(room, state_key, content) {
            packs.push(pack);
        }
    }

    Ok(packs)
}

fn account_image_pack_to_sticker_pack(
    content: ruma::events::image_pack::AccountImagePackEventContent,
) -> Option<StickerPack> {
    let pack_allows_sticker = content
        .pack
        .as_ref()
        .is_none_or(|pack| usage_allows_sticker(&pack.usage));
    let mut stickers = content
        .images
        .into_iter()
        .filter_map(|(shortcode, image)| {
            pack_image_to_sticker(shortcode, image, pack_allows_sticker)
        })
        .collect::<Vec<_>>();
    if stickers.is_empty() {
        return None;
    }
    stickers.sort_by_key(|a| a.body.to_lowercase());

    let title = content
        .pack
        .as_ref()
        .and_then(|pack| pack.display_name.as_deref())
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| "我的贴纸".to_string());
    let avatar_url = content
        .pack
        .as_ref()
        .and_then(|pack| pack.avatar_url.as_ref().map(ToString::to_string));

    Some(StickerPack {
        id: "user:default".to_string(),
        title,
        avatar_url,
        source: "user".to_string(),
        stickers,
    })
}

#[frb]
#[derive(Clone, Debug)]
pub struct VerificationDevice {
    pub device_id: String,
    pub display_name: String,
    pub is_current: bool,
    pub is_verified: bool,
}

#[frb]
#[derive(Clone, Debug)]
pub struct VerificationEmoji {
    pub symbol: String,
    pub description: String,
}

#[frb]
#[derive(Clone, Debug)]
pub struct DeviceVerificationStatus {
    pub phase: String,
    pub device_id: String,
    pub flow_id: String,
    pub incoming: bool,
    pub emojis: Vec<VerificationEmoji>,
    pub message: String,
}

#[frb]
#[derive(Clone, Debug)]
pub struct EncryptionRecoveryInfo {
    pub state: String,
    pub device_verified: bool,
}

#[frb]
#[derive(Clone, Debug)]
pub enum MessageType {
    Text,
    Image,
    Sticker,
    Video,
    /// A generic document / file attachment (m.file, or m.audio rendered as
    /// a downloadable file).
    File,
    /// An m.poll.start (unstable org.matrix.msc3381) poll.
    Poll,
    /// A legacy m.location message.
    Location,
    /// State/member change event (join, leave, etc.)
    Event,
}

/// One selectable answer of a poll.
#[frb]
#[derive(Clone, Debug)]
pub struct PollAnswerInfo {
    pub id: String,
    pub text: String,
}

/// Per-answer tally for a poll.
#[frb]
#[derive(Clone, Debug)]
pub struct PollAnswerResult {
    pub answer_id: String,
    /// Number of users who selected this answer.
    pub count: i32,
    /// Whether the current user selected this answer.
    pub is_mine: bool,
}

/// Poll data carried by a `MessageType::Poll` message.
#[frb]
#[derive(Clone, Debug)]
pub struct PollInfo {
    pub question: String,
    pub answers: Vec<PollAnswerInfo>,
    /// Whether results are revealed while voting is open.
    pub disclosed: bool,
    /// Max selections allowed per voter.
    pub max_selections: i32,
    /// Answer ids the current user has already selected.
    pub my_answer_ids: Vec<String>,
    /// Per-answer tallies (only meaningful when disclosed or ended).
    pub results: Vec<PollAnswerResult>,
    /// Total distinct users who have voted.
    pub total_voters: i32,
    /// Whether the poll has been closed.
    pub ended: bool,
}

/// A single emoji reaction aggregated on a message.
#[frb]
#[derive(Clone, Debug)]
pub struct Reaction {
    /// The reaction key, e.g. "👍".
    pub key: String,
    /// User IDs that sent this reaction (excluding duplicates).
    pub senders: Vec<String>,
    /// Event id of the reaction event the current user sent for this key, if
    /// any. Used to toggle (redact) the user's own reaction.
    pub my_event_id: Option<String>,
}

/// A single member's read receipt on a message.
#[frb]
#[derive(Clone, Debug)]
pub struct MessageReader {
    pub user_id: String,
    /// Display name, falling back to the user id localpart.
    pub display_name: String,
    /// mxc:// avatar URL, if any.
    pub avatar_url: Option<String>,
}

/// A Matrix text message compiled by the Flutter authoring layer.
///
/// `body` is always the readable plain-text fallback. `formatted_body`, when
/// present, is Matrix HTML and is sanitized again in Rust before sending.
#[frb]
#[derive(Clone, Debug)]
pub struct FormattedMessageInput {
    pub body: String,
    pub formatted_body: Option<String>,
    pub mentioned_user_ids: Vec<String>,
    pub mentions_room: bool,
}

#[frb]
#[derive(Clone, Debug)]
pub struct ChatMessage {
    pub id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub content: String,
    /// Sanitized Matrix HTML for text-like messages.
    pub formatted_body: Option<String>,
    pub caption: Option<String>,
    /// Sanitized Matrix HTML for media captions.
    pub caption_formatted_body: Option<String>,
    /// Intentional mentions carried by `m.mentions`.
    pub mentioned_user_ids: Vec<String>,
    pub mentions_room: bool,
    pub timestamp: String,
    pub is_me: bool,
    pub msg_type: MessageType,
    pub image_url: Option<String>,
    /// Serialized Matrix MediaSource. Required to download encrypted media.
    pub media_source_json: Option<String>,
    pub image_width: Option<i32>,
    pub image_height: Option<i32>,
    /// Original filename for file/audio attachments.
    pub filename: Option<String>,
    /// Declared file size in bytes for file/audio attachments.
    pub file_size: Option<i32>,
    /// RFC 5870 geo URI for location messages (e.g. `geo:lat,lng`).
    pub geo_uri: Option<String>,
    /// Poll data when `msg_type == Poll`.
    pub poll: Option<PollInfo>,
    /// Event ID this message is replying to, if any.
    pub in_reply_to: Option<String>,
    /// Whether this message has been edited.
    pub is_edited: bool,
    /// History of edits (previous versions), oldest first.
    pub edit_history: Vec<String>,
    /// Emoji reactions on this message, one entry per distinct key.
    pub reactions: Vec<Reaction>,
    /// Members who have read up to this message (only populated for the
    /// current user's own messages; empty otherwise).
    pub readers: Vec<MessageReader>,
    /// Total joined member count of the room (including the current user).
    pub total_members: i32,
}

/// Result of a registration or login attempt
#[frb]
#[derive(Clone, Debug)]
pub struct AuthResult {
    pub success: bool,
    pub user_id: Option<String>,
    pub device_id: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub error: Option<String>,
    /// If true, UIAA is needed — caller should call register_account again with token + session
    pub needs_uiaa: bool,
    pub session: Option<String>,
    /// Available UIAA flows (JSON)
    pub flows: Option<String>,
}

/// The current user's profile, fetched from the homeserver for the editor.
#[frb]
#[derive(Clone, Debug)]
pub struct UserProfile {
    pub user_id: String,
    pub display_name: String,
    /// `mxc://` avatar URI, if set.
    pub avatar_url: Option<String>,
}

/// Info about a logged-in account (for listing / switching).
#[frb]
#[derive(Clone, Debug)]
pub struct AccountInfo {
    pub user_id: String,
    pub device_id: String,
    pub homeserver_url: String,
}

// ── Internal helpers ─────────────────────────────────────────────────

/// Try to extract UIAA info from a register error via structured SDK APIs.
fn try_extract_uiaa(err: &matrix_sdk::Error) -> Option<AuthResult> {
    if let Some(uiaa_info) = err.as_uiaa_response() {
        info!("UIAA extracted via err.as_uiaa_response()");
        return Some(uiaa_to_auth_result(uiaa_info));
    }

    if let matrix_sdk::Error::Http(http_err) = err {
        if let Some(uiaa_info) = http_err.as_uiaa_response() {
            info!("UIAA extracted via http_err.as_uiaa_response()");
            return Some(uiaa_to_auth_result(uiaa_info));
        }
    }

    None
}

fn try_parse_uiaa_from_string(err_str: &str) -> Option<AuthResult> {
    let json_start = err_str
        .find("[401]")
        .and_then(|pos| err_str[pos + 5..].find('{').map(|p| pos + 5 + p))?;
    let json_str = &err_str[json_start..];

    let val: serde_json::Value = serde_json::from_str(json_str).ok()?;

    let has_reg_token = val
        .get("flows")
        .and_then(|f| f.as_array())
        .is_some_and(|flows| {
            flows.iter().any(|flow| {
                flow.get("stages")
                    .and_then(|s| s.as_array())
                    .is_some_and(|stages| {
                        stages
                            .iter()
                            .any(|s| s.as_str() == Some("m.login.registration_token"))
                    })
            })
        });

    if !has_reg_token {
        return None;
    }

    let session = val
        .get("session")
        .and_then(|s| s.as_str())
        .map(|s| s.to_string());

    if session.is_some() {
        info!("UIAA parsed from error string JSON, session found");
        Some(AuthResult {
            success: false,
            user_id: None,
            device_id: None,
            access_token: None,
            refresh_token: None,
            error: None,
            needs_uiaa: true,
            session,
            flows: Some("m.login.registration_token".to_string()),
        })
    } else {
        warn!(
            "UIAA JSON found but no session: {}",
            &err_str[..err_str.len().min(500)]
        );
        None
    }
}

fn uiaa_to_auth_result(uiaa_info: &UiaaInfo) -> AuthResult {
    let session = uiaa_info.session.clone();
    let flows_json = serde_json::to_string(&uiaa_info.flows).ok();

    AuthResult {
        success: false,
        user_id: None,
        device_id: None,
        access_token: None,
        refresh_token: None,
        error: None,
        needs_uiaa: true,
        session,
        flows: flows_json,
    }
}

fn get_room_by_id(client: &Client, room_id: &str) -> Result<Room, String> {
    let parsed_room_id =
        matrix_sdk::ruma::RoomId::parse(room_id).map_err(|e| format!("Invalid room ID: {e}"))?;
    client
        .get_room(parsed_room_id.as_ref())
        .ok_or_else(|| format!("Room not found: {room_id}"))
}

async fn remove_dir_all_if_exists(path: &Path) -> Result<bool, String> {
    match tokio::fs::remove_dir_all(path).await {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.to_string()),
    }
}

fn friendly_auth_error(raw: &str, fallback: &str) -> String {
    let text = raw.to_lowercase();

    if text.contains("timed out") || text.contains("timeout") {
        return "连接超时，请检查网络或服务器地址".to_string();
    }

    if text.contains("network")
        || text.contains("socket")
        || text.contains("dns")
        || text.contains("connection refused")
        || text.contains("tls")
    {
        return "无法连接到服务器，请检查网络或 Homeserver 地址".to_string();
    }

    if text.contains("401")
        || text.contains("403")
        || text.contains("forbidden")
        || text.contains("unauthorized")
        || text.contains("invalid password")
        || text.contains("unknown token")
        || text.contains("access denied")
        || text.contains("m_forbidden")
    {
        return "认证失败，请检查账号、密码或 Token".to_string();
    }

    if text.contains("registration token")
        || text.contains("m.login.registration_token")
        || text.contains("missing token")
        || text.contains("invalid token")
    {
        return "注册需要有效的注册 Token".to_string();
    }

    if text.contains("user id") && text.contains("invalid") {
        return "用户 ID 格式无效".to_string();
    }

    if text.contains("no client created") {
        return "客户端初始化失败，请重试".to_string();
    }

    fallback.to_string()
}

// ── Auth functions ───────────────────────────────────────────────────

/// Create a Matrix client for the given homeserver URL.
/// Must be called before any registration / login attempt.
/// The client is stored as "pending" until a login succeeds,
/// after which it is automatically migrated to a per-user store.
#[frb]
pub async fn create_client(homeserver_url: String, data_dir: String) -> Result<(), String> {
    init_log_store(&data_dir);
    app_log(
        "info",
        "auth",
        format!("create_client: homeserver={}", homeserver_url),
    );
    let url = url::Url::parse(&homeserver_url).map_err(|e| {
        let msg = format!("Invalid URL: {e}");
        app_log("error", "auth", msg.clone());
        msg
    })?;
    let sdk_dir = build_sdk_data_dir(&data_dir, None);

    // Clean up any stale pending directory
    if sdk_dir.exists() {
        info!("Removing stale pending dir: {}", sdk_dir.display());
        if let Err(e) = remove_dir_all_if_exists(&sdk_dir).await {
            warn!("Failed to clean pending dir: {e}");
        }
    }

    let client = Client::builder()
        .handle_refresh_tokens()
        .homeserver_url(url)
        .with_encryption_settings(encryption_settings())
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
        .map_err(|e| {
            let msg = format!("Failed to create client: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;
    install_session_token_callback(&client)?;

    app_log(
        "info",
        "auth",
        format!("Client created for {}", homeserver_url),
    );

    let mut pending = PENDING.write().await;
    *pending = Some(PendingEntry {
        client,
        data_dir,
        homeserver_url,
    });
    Ok(())
}

/// Step 1 of registration: discover UIAA flows.
#[frb]
pub async fn register_get_uiaa_session(
    username: String,
    password: String,
) -> Result<AuthResult, String> {
    app_log(
        "info",
        "auth",
        format!("register_get_uiaa_session: user={}", username),
    );
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    let mut request = RegistrationRequest::new();
    request.username = Some(username);
    request.password = Some(password);
    request.initial_device_display_name = Some("Matter".to_owned());
    request.refresh_token = true;
    request.auth = Some(AuthData::Dummy(Dummy::new()));

    match client.matrix_auth().register(request).await {
        Ok(response) => Ok(AuthResult {
            success: true,
            user_id: Some(response.user_id.to_string()),
            device_id: response.device_id.map(|d| d.to_string()),
            access_token: response.access_token,
            refresh_token: response.refresh_token,
            error: None,
            needs_uiaa: false,
            session: None,
            flows: None,
        }),
        Err(err) => {
            let err_str = format!("{err}");
            info!(
                "register_get_uiaa_session error: {}",
                &err_str[..err_str.len().min(300)]
            );

            if let Some(result) = try_extract_uiaa(&err) {
                return Ok(result);
            }

            if let Some(result) = try_parse_uiaa_from_string(&err_str) {
                return Ok(result);
            }

            warn!("No UIAA info extracted from get_uiaa_session");
            Ok(AuthResult {
                success: false,
                user_id: None,
                device_id: None,
                access_token: None,
                refresh_token: None,
                error: Some(friendly_auth_error(&err_str, "注册失败，请稍后重试")),
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
    }
}

/// Step 2 of registration: complete with token + session.
#[frb]
pub async fn register_complete_uiaa(
    username: String,
    password: String,
    registration_token: String,
    session: String,
) -> Result<AuthResult, String> {
    app_log(
        "info",
        "auth",
        format!("register_complete_uiaa: user={}", username),
    );
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    let mut request = RegistrationRequest::new();
    request.username = Some(username);
    request.password = Some(password);
    request.initial_device_display_name = Some("Matter".to_owned());
    request.refresh_token = true;

    let mut reg_token = RegistrationToken::new(registration_token);
    reg_token.session = Some(session);
    request.auth = Some(AuthData::RegistrationToken(reg_token));

    match client.matrix_auth().register(request).await {
        Ok(response) => {
            // Auto-finalize: migrate pending client to per-user store
            drop(client);
            let finalized = finalize_pending()
                .await
                .map_err(|e| format!("Finalization failed: {e}"))?;
            info!("Account finalized after registration: {}", finalized);
            Ok(AuthResult {
                success: true,
                user_id: Some(response.user_id.to_string()),
                device_id: response.device_id.map(|d| d.to_string()),
                access_token: response.access_token,
                refresh_token: response.refresh_token,
                error: None,
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
        Err(err) => {
            let err_str = format!("{err}");
            info!(
                "register_complete_uiaa error: {}",
                &err_str[..err_str.len().min(300)]
            );

            if let Some(result) = try_extract_uiaa(&err) {
                return Ok(result);
            }

            if let Some(result) = try_parse_uiaa_from_string(&err_str) {
                return Ok(result);
            }

            Ok(AuthResult {
                success: false,
                user_id: None,
                device_id: None,
                access_token: None,
                refresh_token: None,
                error: Some(friendly_auth_error(&err_str, "注册失败，请稍后重试")),
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
    }
}

/// Login with username and password.
#[frb]
pub async fn login_with_password(username: String, password: String) -> Result<AuthResult, String> {
    app_log(
        "info",
        "auth",
        format!("login_with_password: user={}", username),
    );
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    match client
        .matrix_auth()
        .login_username(&username, &password)
        .request_refresh_token()
        .initial_device_display_name("Matter")
        .await
    {
        Ok(response) => {
            // Auto-finalize: migrate pending client to per-user store
            drop(client);
            let finalized = finalize_pending()
                .await
                .map_err(|e| format!("Finalization failed: {e}"))?;
            app_log(
                "info",
                "auth",
                format!("Account finalized after password login: {}", finalized),
            );
            info!("Account finalized after password login: {}", finalized);
            Ok(AuthResult {
                success: true,
                user_id: Some(response.user_id.to_string()),
                device_id: Some(response.device_id.to_string()),
                access_token: Some(response.access_token),
                refresh_token: response.refresh_token,
                error: None,
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
        Err(e) => Ok(AuthResult {
            success: false,
            user_id: None,
            device_id: None,
            access_token: None,
            refresh_token: None,
            error: Some(friendly_auth_error(&format!("{e}"), "登录失败，请稍后重试")),
            needs_uiaa: false,
            session: None,
            flows: None,
        }),
    }
}

/// Login with an existing access token (restore session).
#[frb]
pub async fn login_with_token(
    access_token: String,
    user_id: String,
    device_id: String,
    refresh_token: Option<String>,
) -> Result<AuthResult, String> {
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    let parsed_user_id = matrix_sdk::ruma::UserId::parse(&user_id)
        .map_err(|e| friendly_auth_error(&format!("Invalid user ID: {e}"), "用户 ID 格式无效"))?;
    let parsed_device_id = matrix_sdk::ruma::OwnedDeviceId::from(device_id);

    let session = MatrixSession {
        meta: SessionMeta {
            user_id: parsed_user_id,
            device_id: parsed_device_id,
        },
        tokens: SessionTokens {
            access_token,
            refresh_token,
        },
    };

    client
        .matrix_auth()
        .restore_session(session, RoomLoadSettings::default())
        .await
        .map_err(|e| {
            friendly_auth_error(
                &format!("Restore session failed: {e}"),
                "Token 登录失败，请检查输入信息",
            )
        })?;

    drop(client);
    let finalized_user = finalize_pending().await.map_err(|e| {
        let raw = format!("Finalization failed after token login: {e}");
        app_log("error", "auth", raw.clone());
        friendly_auth_error(&raw, "Token 登录失败，请稍后重试")
    })?;
    app_log(
        "info",
        "auth",
        format!("Account finalized after token login: {}", finalized_user),
    );
    info!("Account finalized after token login: {}", finalized_user);

    let final_client = get_client()
        .await
        .ok_or_else(|| "Token 登录成功，但无法获取最终会话".to_string())?;

    Ok(AuthResult {
        success: true,
        user_id: final_client.user_id().map(|u| u.to_string()),
        device_id: final_client.device_id().map(|d| d.to_string()),
        access_token: None,
        refresh_token: final_client
            .matrix_auth()
            .session()
            .and_then(|session| session.tokens.refresh_token),
        error: None,
        needs_uiaa: false,
        session: None,
        flows: None,
    })
}

/// Check if the client is currently logged in.
#[frb]
pub async fn is_logged_in() -> bool {
    if let Some(client) = get_client().await {
        client.matrix_auth().logged_in()
    } else {
        false
    }
}

/// Get the current user ID if logged in.
#[frb]
pub async fn get_current_user_id() -> Option<String> {
    if let Some(client) = get_client().await {
        client.user_id().map(|u| u.to_string())
    } else {
        None
    }
}

/// Get the currently active user ID (the account being used).
#[frb]
pub async fn get_active_user_id() -> Option<String> {
    let active = ACTIVE_USER.read().await;
    active.clone()
}

/// Fetch the current user's profile (display name + avatar mxc URL) from the
/// homeserver. Used to populate the profile editor with current values.
#[frb]
pub async fn get_profile() -> Result<UserProfile, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let user_id = client.user_id().ok_or("Not logged in.")?;

    let account = client.account();
    let display_name = account
        .get_display_name()
        .await
        .map_err(|e| format!("Failed to fetch display name: {e}"))?
        .unwrap_or_default();
    let avatar_url = account
        .get_avatar_url()
        .await
        .map_err(|e| format!("Failed to fetch avatar: {e}"))?
        .map(|u| u.to_string());

    Ok(UserProfile {
        user_id: user_id.to_string(),
        display_name,
        avatar_url,
    })
}

/// Update the current user's display name. Empty string clears it.
#[frb]
pub async fn set_display_name(name: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let account = client.account();
    let trimmed = name.trim();
    account
        .set_display_name(if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        })
        .await
        .map_err(|e| format!("Failed to set display name: {e}"))?;
    Ok(())
}

/// Update the current user's avatar. `mxc` is an `mxc://` URI obtained from
/// `upload_avatar`. Pass an empty string to remove the avatar.
#[frb]
pub async fn set_avatar_url(mxc: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let account = client.account();
    let trimmed = mxc.trim();
    if trimmed.is_empty() {
        account
            .set_avatar_url(None)
            .await
            .map_err(|e| format!("Failed to remove avatar: {e}"))?;
    } else {
        use std::convert::TryFrom;
        let mxc_uri = matrix_sdk::ruma::OwnedMxcUri::try_from(trimmed)
            .map_err(|e| format!("Invalid mxc URI: {e}"))?;
        account
            .set_avatar_url(Some(&mxc_uri))
            .await
            .map_err(|e| format!("Failed to set avatar: {e}"))?;
    }
    Ok(())
}

/// Upload raw image bytes as avatar media and return the resulting `mxc://`
/// URI. Call `set_avatar_url` afterwards to actually apply it. Split into two
/// steps so the UI can show progress if needed and a failed upload won't leave
/// a half-set profile.
#[frb]
pub async fn upload_avatar(content_type: String, data: Vec<u8>) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let account = client.account();
    let mime: mime::Mime = content_type
        .parse()
        .map_err(|e| format!("Invalid content type '{content_type}': {e}"))?;
    let mxc = account
        .upload_avatar(&mime, data)
        .await
        .map_err(|e| format!("Failed to upload avatar: {e}"))?;
    Ok(mxc.to_string())
}

/// List all logged-in accounts.
#[frb]
pub async fn list_accounts() -> Vec<AccountInfo> {
    let clients = CLIENTS.read().await;
    clients
        .iter()
        .map(|(user_id, entry)| AccountInfo {
            user_id: user_id.clone(),
            device_id: entry
                .client
                .device_id()
                .map(|d| d.to_string())
                .unwrap_or_default(),
            homeserver_url: entry.client.homeserver().to_string(),
        })
        .collect()
}

/// Switch the active account. Returns true if the account exists and was activated.
#[frb]
pub async fn switch_account(user_id: String) -> bool {
    let clients = CLIENTS.read().await;
    if clients.contains_key(&user_id) {
        drop(clients);
        let mut sync_task = SYNC_TASK.lock().await;
        if let Some(running) = sync_task.take() {
            running.handle.abort();
            app_log(
                "info",
                "sync",
                format!("Stopped sync loop for user {}", running.user_id),
            );
        }
        let mut active = ACTIVE_USER.write().await;
        *active = Some(user_id.clone());
        drop(active);
        drop(sync_task);
        clear_verification_session().await;
        clear_timeline_cache().await;
        app_log("info", "auth", format!("Switched to account: {}", user_id));
        info!("Switched to account: {}", user_id);
        true
    } else {
        app_log(
            "warn",
            "auth",
            format!("switch_account: account {} not found", user_id),
        );
        false
    }
}

/// Logout the active user and remove its data.
#[frb]
pub async fn logout() -> Result<(), String> {
    let active_user = {
        let active = ACTIVE_USER.read().await;
        active.clone()
    };

    let user_id = active_user.ok_or("No active account to logout")?;
    clear_verification_session().await;
    stop_sync_task(Some(&user_id)).await;
    clear_timeline_cache().await;

    let (client, data_dir) = {
        let clients = CLIENTS.read().await;
        let entry = clients
            .get(&user_id)
            .ok_or("Active account missing from store")?;
        (entry.client.clone(), entry.data_dir.clone())
    };

    if client.matrix_auth().logged_in() {
        if let Err(e) = client.matrix_auth().logout().await {
            app_log(
                "warn",
                "auth",
                format!("Remote logout failed for {}: {e}", user_id),
            );
            warn!("Remote logout failed for {}: {e}", user_id);
        }
    }

    {
        let mut clients = CLIENTS.write().await;
        clients.remove(&user_id);
    }

    // Delete the per-user SDK data directory after the client has been removed.
    let sdk_dir = build_sdk_data_dir(&data_dir, Some(&user_id));
    if sdk_dir.exists() {
        app_log(
            "info",
            "auth",
            format!("Deleting SDK store for {}: {}", user_id, sdk_dir.display()),
        );
        info!("Deleting SDK store for {}: {}", user_id, sdk_dir.display());
        if let Err(e) = remove_dir_all_if_exists(&sdk_dir).await {
            warn!("Failed to delete SDK store: {e}");
        }
    }

    // Update active user to another available account, or None
    let clients = CLIENTS.write().await;
    let mut active = ACTIVE_USER.write().await;
    if let Some((next_id, _)) = clients.iter().next() {
        *active = Some(next_id.clone());
        app_log(
            "info",
            "auth",
            format!("Switched active account to: {}", next_id),
        );
        info!("Switched active account to: {}", next_id);
    } else {
        *active = None;
        app_log(
            "info",
            "auth",
            "No more accounts, active cleared".to_string(),
        );
        info!("No more accounts, active cleared");
    }

    Ok(())
}

/// Remove a specific account by user_id (logout + delete data).
#[frb]
pub async fn remove_account(user_id: String) -> Result<(), String> {
    let removing_active = ACTIVE_USER.read().await.as_ref() == Some(&user_id);
    if removing_active {
        clear_verification_session().await;
        clear_timeline_cache().await;
    }
    stop_sync_task(Some(&user_id)).await;

    let (client, data_dir) = {
        let clients = CLIENTS.read().await;
        let entry = clients.get(&user_id).ok_or("Account not found")?;
        (entry.client.clone(), entry.data_dir.clone())
    };

    if client.matrix_auth().logged_in() {
        if let Err(e) = client.matrix_auth().logout().await {
            app_log(
                "warn",
                "auth",
                format!("Remote logout failed while removing {}: {e}", user_id),
            );
            warn!("Remote logout failed while removing {}: {e}", user_id);
        }
    }

    {
        let mut clients = CLIENTS.write().await;
        clients.remove(&user_id);
    }

    // Delete the per-user SDK data directory
    let sdk_dir = build_sdk_data_dir(&data_dir, Some(&user_id));
    if sdk_dir.exists() {
        app_log(
            "info",
            "auth",
            format!("Deleting SDK store for {}: {}", user_id, sdk_dir.display()),
        );
        info!("Deleting SDK store for {}: {}", user_id, sdk_dir.display());
        if let Err(e) = remove_dir_all_if_exists(&sdk_dir).await {
            warn!("Failed to delete SDK store: {e}");
        }
    }

    // If this was the active account, switch to another or clear
    let mut active = ACTIVE_USER.write().await;
    if active.as_ref() == Some(&user_id) {
        let clients = CLIENTS.read().await;
        *active = clients.iter().next().map(|(id, _)| id.clone());
    }

    Ok(())
}

// ── Session persistence ──────────────────────────────────────────────

/// Session data to persist across app restarts.
#[frb]
#[derive(Clone, Debug)]
pub struct StoredSession {
    pub homeserver_url: String,
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub user_id: String,
    pub device_id: String,
}

/// Get the current session if logged in, for persisting to disk.
#[frb]
pub async fn get_session() -> Option<StoredSession> {
    let client = get_client().await?;
    let auth = client.matrix_auth();
    if !auth.logged_in() {
        return None;
    }
    let session = auth.session()?;
    Some(StoredSession {
        homeserver_url: client.homeserver().to_string(),
        access_token: session.tokens.access_token,
        refresh_token: session.tokens.refresh_token,
        user_id: session.meta.user_id.to_string(),
        device_id: session.meta.device_id.to_string(),
    })
}

/// Restore a previously saved session (used on app startup).
/// Uses a per-user store directory so multiple accounts coexist.
#[frb]
pub async fn restore_session(session: StoredSession, data_dir: String) -> Result<(), String> {
    init_log_store(&data_dir);
    app_log(
        "info",
        "auth",
        format!(
            "restore_session: user={}, homeserver={}",
            session.user_id, session.homeserver_url
        ),
    );
    let url = url::Url::parse(&session.homeserver_url).map_err(|e| {
        let msg = format!("Invalid URL: {e}");
        app_log("error", "auth", msg.clone());
        msg
    })?;
    let sdk_dir = build_sdk_data_dir(&data_dir, Some(&session.user_id));

    app_log(
        "info",
        "auth",
        format!("restore_session: SDK dir = {}", sdk_dir.display()),
    );

    let client = Client::builder()
        .handle_refresh_tokens()
        .homeserver_url(url)
        .with_encryption_settings(encryption_settings())
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
        .map_err(|e| {
            let msg = format!("Client build failed: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;
    install_session_token_callback(&client)?;

    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id).map_err(|e| {
        let msg = format!("Invalid user ID: {e}");
        app_log("error", "auth", msg.clone());
        msg
    })?;
    let device_id = matrix_sdk::ruma::OwnedDeviceId::from(session.device_id);

    let matrix_session = MatrixSession {
        meta: SessionMeta { user_id, device_id },
        tokens: SessionTokens {
            access_token: session.access_token,
            refresh_token: session.refresh_token,
        },
    };

    client
        .matrix_auth()
        .restore_session(matrix_session, RoomLoadSettings::default())
        .await
        .map_err(|e| {
            let msg = format!("Restore failed: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;
    wait_for_e2ee_initialization(&client, "session restore").await;
    install_verification_event_handler(&client);
    install_live_update_event_handlers(&client);
    install_room_key_event_handler(&client);

    // Add to multi-account store
    {
        let mut clients = CLIENTS.write().await;
        clients.insert(
            session.user_id.clone(),
            ClientEntry {
                client,
                data_dir: data_dir.clone(),
            },
        );
    }

    // Set as active
    {
        let mut active = ACTIVE_USER.write().await;
        *active = Some(session.user_id.clone());
    }

    app_log(
        "info",
        "auth",
        format!("Session restored for {}", session.user_id),
    );
    Ok(())
}

// ── Device verification & encryption recovery ─────────────────────

fn active_session_meta(client: &Client) -> Result<(String, String), String> {
    let session = client
        .matrix_auth()
        .session()
        .ok_or("No active Matrix session")?;
    Ok((
        session.meta.user_id.to_string(),
        session.meta.device_id.to_string(),
    ))
}

async fn current_verification_session() -> Result<(Client, VerificationSession), String> {
    let client = get_client().await.ok_or("No active client")?;
    let session = VERIFICATION_SESSION
        .read()
        .await
        .clone()
        .ok_or("No active verification")?;
    Ok((client, session))
}

async fn clear_verification_session() {
    *VERIFICATION_SESSION.write().await = None;
}

async fn clear_verification_session_if(flow_id: &str) {
    let mut active = VERIFICATION_SESSION.write().await;
    if active
        .as_ref()
        .is_some_and(|session| session.flow_id == flow_id)
    {
        *active = None;
    }
}

#[frb]
pub async fn list_own_devices() -> Result<Vec<VerificationDevice>, String> {
    let client = get_client().await.ok_or("No active client")?;
    let (user_id, current_device_id) = active_session_meta(&client)?;
    let user_id =
        matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| format!("Invalid user ID: {e}"))?;

    // Refresh the identity first so the device list isn't limited to stale local data.
    client
        .encryption()
        .request_user_identity(&user_id)
        .await
        .map_err(|e| format!("Failed to refresh encryption identity: {e}"))?;
    let devices = client
        .encryption()
        .get_user_devices(&user_id)
        .await
        .map_err(|e| format!("Failed to load devices: {e}"))?;

    let mut result = devices
        .devices()
        .map(|device| VerificationDevice {
            device_id: device.device_id().to_string(),
            display_name: device.display_name().unwrap_or("未命名设备").to_string(),
            is_current: device.device_id().as_str() == current_device_id,
            is_verified: device.is_verified(),
        })
        .collect::<Vec<_>>();
    result.sort_by_key(|device| (!device.is_current, device.display_name.to_lowercase()));
    Ok(result)
}

#[frb]
pub async fn start_device_verification(device_id: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No active client")?;
    let (user_id, current_device_id) = active_session_meta(&client)?;
    if device_id == current_device_id {
        return Err("Cannot verify the current device with itself".into());
    }
    let user_id =
        matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| format!("Invalid user ID: {e}"))?;
    let device_id = matrix_sdk::ruma::OwnedDeviceId::from(device_id);
    let device = client
        .encryption()
        .get_device(&user_id, &device_id)
        .await
        .map_err(|e| format!("Failed to load device: {e}"))?
        .ok_or("Device is no longer available")?;
    let request = device
        .request_verification_with_methods(vec![VerificationMethod::SasV1])
        .await
        .map_err(|e| format!("Failed to request verification: {e}"))?;

    *VERIFICATION_SESSION.write().await = Some(VerificationSession {
        user_id: user_id.to_string(),
        device_id: device_id.to_string(),
        flow_id: request.flow_id().to_string(),
        incoming: false,
        accepted: true,
    });
    Ok(())
}

#[frb]
pub async fn accept_device_verification() -> Result<(), String> {
    let (client, session) = current_verification_session().await?;
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;
    let request = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await
        .ok_or("Verification request is no longer available")?;
    request
        .accept_with_methods(vec![VerificationMethod::SasV1])
        .await
        .map_err(|e| format!("Failed to accept verification: {e}"))?;
    if let Some(active) = VERIFICATION_SESSION.write().await.as_mut() {
        active.accepted = true;
    }
    Ok(())
}

#[frb]
pub async fn get_device_verification_status() -> Result<Option<DeviceVerificationStatus>, String> {
    let client = get_client().await.ok_or("No active client")?;
    let Some(session) = VERIFICATION_SESSION.read().await.clone() else {
        return Ok(None);
    };
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;

    let request = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await;

    if session.accepted {
        if let Some(request) = request.as_ref() {
            if request.is_ready() && request.we_started() {
                request
                    .start_sas()
                    .await
                    .map_err(|e| format!("Failed to start emoji verification: {e}"))?;
            }
        }
    }

    let verification = client
        .encryption()
        .get_verification(&user_id, &session.flow_id)
        .await;

    if let Some(Verification::SasV1(sas)) = verification {
        if session.accepted
            && !sas.can_be_presented()
            && !sas.is_done()
            && sas.cancel_info().is_none()
        {
            sas.accept()
                .await
                .map_err(|e| format!("Failed to accept emoji verification: {e}"))?;
        }
        if sas.is_done() {
            return Ok(Some(DeviceVerificationStatus {
                phase: "done".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: vec![],
                message: "Verification completed".into(),
            }));
        }
        if let Some(cancel) = sas.cancel_info() {
            clear_verification_session_if(&session.flow_id).await;
            return Ok(Some(DeviceVerificationStatus {
                phase: "cancelled".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: vec![],
                message: cancel.reason().to_string(),
            }));
        }
        if let Some(emojis) = sas.emoji() {
            return Ok(Some(DeviceVerificationStatus {
                phase: "comparing".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: emojis
                    .into_iter()
                    .map(|emoji| VerificationEmoji {
                        symbol: emoji.symbol.to_string(),
                        description: emoji.description.to_string(),
                    })
                    .collect(),
                message: "Compare the emoji on both devices".into(),
            }));
        }
    }

    let (phase, message) = match request.map(|request| request.state()) {
        Some(VerificationRequestState::Requested { .. }) if !session.accepted => {
            ("requested", "A device wants to verify this device")
        }
        Some(VerificationRequestState::Created { .. }) => {
            ("waiting", "Waiting for the other device")
        }
        Some(VerificationRequestState::Ready { .. }) => ("starting", "Starting emoji verification"),
        Some(VerificationRequestState::Transitioned { .. }) => {
            ("starting", "Preparing emoji comparison")
        }
        Some(VerificationRequestState::Done) => {
            return Ok(Some(DeviceVerificationStatus {
                phase: "done".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: vec![],
                message: "Verification completed".into(),
            }));
        }
        Some(VerificationRequestState::Cancelled(cancel)) => {
            clear_verification_session_if(&session.flow_id).await;
            return Ok(Some(DeviceVerificationStatus {
                phase: "cancelled".into(),
                device_id: session.device_id,
                flow_id: session.flow_id,
                incoming: session.incoming,
                emojis: vec![],
                message: cancel.reason().to_string(),
            }));
        }
        None => {
            // The SDK no longer knows this flow. Keeping the local session here
            // creates a permanent ghost verification that cannot be cancelled.
            clear_verification_session_if(&session.flow_id).await;
            return Ok(None);
        }
        _ => ("waiting", "Waiting for verification events"),
    };

    Ok(Some(DeviceVerificationStatus {
        phase: phase.into(),
        device_id: session.device_id,
        flow_id: session.flow_id,
        incoming: session.incoming,
        emojis: vec![],
        message: message.into(),
    }))
}

#[frb]
pub async fn confirm_device_verification() -> Result<(), String> {
    let (client, session) = current_verification_session().await?;
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;
    let sas = client
        .encryption()
        .get_verification(&user_id, &session.flow_id)
        .await
        .and_then(Verification::sas)
        .ok_or("Emoji verification is not ready")?;
    sas.confirm()
        .await
        .map_err(|e| format!("Failed to confirm verification: {e}"))?;

    // Confirmation is sent before the other device's MAC/done event arrives.
    // Wait briefly so callers can refresh the verified-device state immediately.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(8);
    while !sas.is_done() && sas.cancel_info().is_none() {
        if tokio::time::Instant::now() >= deadline {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    Ok(())
}

#[frb]
pub async fn cancel_device_verification(mismatch: bool) -> Result<(), String> {
    let (client, session) = current_verification_session().await?;
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;
    if let Some(sas) = client
        .encryption()
        .get_verification(&user_id, &session.flow_id)
        .await
        .and_then(Verification::sas)
    {
        if mismatch {
            sas.mismatch().await
        } else {
            sas.cancel().await
        }
        .map_err(|e| format!("Failed to cancel verification: {e}"))?;
    } else if let Some(request) = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await
    {
        request
            .cancel()
            .await
            .map_err(|e| format!("Failed to cancel verification: {e}"))?;
    }
    clear_verification_session_if(&session.flow_id).await;
    Ok(())
}

#[frb]
pub async fn get_encryption_recovery_info() -> Result<EncryptionRecoveryInfo, String> {
    let client = get_client().await.ok_or("No active client")?;
    let state = match client.encryption().recovery().state() {
        RecoveryState::Unknown => "unknown",
        RecoveryState::Enabled => "enabled",
        RecoveryState::Disabled => "disabled",
        RecoveryState::Incomplete => "incomplete",
    };
    let device_verified = matches!(
        client.encryption().verification_state().get(),
        OwnVerificationState::Verified
    );
    Ok(EncryptionRecoveryInfo {
        state: state.into(),
        device_verified,
    })
}

#[frb]
pub async fn recover_encryption(recovery_key_or_passphrase: String) -> Result<(), String> {
    let value = recovery_key_or_passphrase.trim();
    if value.is_empty() {
        return Err("Recovery key or passphrase is empty".into());
    }
    let client = get_client().await.ok_or("No active client")?;
    client
        .encryption()
        .recovery()
        .recover(value)
        .await
        .map_err(|e| format!("Failed to recover encryption data: {e}"))?;
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn enable_encryption_recovery(passphrase: Option<String>) -> Result<String, String> {
    let client = get_client().await.ok_or("No active client")?;
    let recovery = client.encryption().recovery();
    let passphrase = passphrase
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let result = if let Some(passphrase) = passphrase.as_deref() {
        recovery
            .enable()
            .wait_for_backups_to_upload()
            .with_passphrase(passphrase)
            .await
    } else {
        recovery.enable().wait_for_backups_to_upload().await
    };
    result.map_err(|e| format!("Failed to enable encryption recovery: {e}"))
}

// ── Sync & real-time ─────────────────────────────────────────────────

/// A notification sent from Rust to Dart when new events arrive.
#[frb]
#[derive(Clone, Debug)]
pub struct SyncNotification {
    /// Which room got a new event (empty if just a state sync)
    pub room_id: String,
    /// Number of rooms with new messages
    pub rooms_updated: i32,
}

/// Perform an initial sync with a 10-second timeout.
/// Uses traditional /sync for the initial load (Sliding Sync needs
/// this data in the state store first).
#[frb]
pub async fn sync_once() -> Result<(), String> {
    let client = get_client().await.ok_or_else(|| {
        app_log("error", "sync", "sync_once: no client created".to_string());
        "No client created.".to_string()
    })?;
    let user_id = client.user_id().map(|u| u.to_string()).unwrap_or_default();
    let hs = client.homeserver().to_string();
    app_log(
        "info",
        "sync",
        format!(
            "sync_once: starting for user {} (homeserver: {hs})",
            user_id
        ),
    );
    set_connection_status(ConnectionStatus::Connecting);

    client
        .event_cache()
        .subscribe()
        .map_err(|e| format!("Failed to subscribe to the event cache: {e}"))?;

    let result = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        client.sync_once(matrix_sdk::config::SyncSettings::default()),
    )
    .await;

    match result {
        Ok(Ok(_)) => {
            app_log(
                "info",
                "sync",
                format!("sync_once: completed for user {}", user_id),
            );
            set_connection_status(ConnectionStatus::Connected);
            notify_sync_event(SyncEvent::SyncCompleted);
            Ok(())
        }
        Ok(Err(e)) => {
            let msg = format!("sync_once: failed for user {}: {e}", user_id);
            app_log("error", "sync", msg.clone());
            set_connection_status(ConnectionStatus::Disconnected);
            Err(format!("Sync failed: {e}"))
        }
        Err(_) => {
            let msg = format!(
                "sync_once: timed out after 10s for user {} (homeserver: {hs})",
                user_id
            );
            app_log("error", "sync", msg.clone());
            set_connection_status(ConnectionStatus::Disconnected);
            Err("Sync timed out after 10 seconds. Check your network connection and homeserver URL.".to_string())
        }
    }
}

/// Start a Sliding Sync loop for real-time updates.
/// Falls back to traditional sync_once loop if Sliding Sync is unavailable.
#[frb]
pub async fn start_sync() -> Result<(), String> {
    let client = get_client().await.ok_or_else(|| {
        app_log("error", "sync", "start_sync: no client created".to_string());
        set_connection_status(ConnectionStatus::Disconnected);
        "No client created.".to_string()
    })?;
    let user_id = client.user_id().map(|u| u.to_string()).unwrap_or_default();
    let hs = client.homeserver().to_string();
    app_log(
        "info",
        "sync",
        format!(
            "start_sync: beginning for user {} (homeserver: {hs})",
            user_id
        ),
    );

    client.event_cache().subscribe().map_err(|e| {
        set_connection_status(ConnectionStatus::Disconnected);
        format!("Failed to subscribe to the event cache: {e}")
    })?;

    stop_sync_task(None).await;

    // Try Sliding Sync first
    let handle = match try_start_sliding_sync(client.clone()).await {
        Ok(handle) => {
            app_log(
                "info",
                "sync",
                format!("start_sync: Sliding Sync started for user {}", user_id),
            );
            handle
        }
        Err(e) => {
            app_log(
                "warn",
                "sync",
                format!(
                    "start_sync: Sliding Sync failed ({}), falling back to traditional sync loop",
                    e
                ),
            );
            // Fallback: traditional sync loop
            let loop_user_id = user_id.clone();
            tokio::spawn(async move {
                app_log(
                    "info",
                    "sync",
                    format!("Traditional sync loop started for user {}", loop_user_id),
                );
                loop {
                    set_connection_status(ConnectionStatus::Updating);
                    match client
                        .sync_once(matrix_sdk::config::SyncSettings::default())
                        .await
                    {
                        Ok(_) => {
                            app_log("info", "sync", "Traditional sync completed".to_string());
                            set_connection_status(ConnectionStatus::Connected);
                            notify_sync_event(SyncEvent::SyncCompleted);
                        }
                        Err(e) => {
                            app_log("error", "sync", format!("Traditional sync error: {e}"));
                            set_connection_status(ConnectionStatus::Disconnected);
                            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                        }
                    }
                }
            })
        }
    };

    let mut current_task = SYNC_TASK.lock().await;
    let active_user = ACTIVE_USER.read().await.clone();
    if active_user.as_deref() != Some(&user_id) {
        handle.abort();
        set_connection_status(ConnectionStatus::Disconnected);
        return Err("Active account changed while starting sync.".to_string());
    }

    if let Some(running) = current_task.take() {
        running.handle.abort();
    }
    *current_task = Some(SyncTask { user_id, handle });
    Ok(())
}

/// Try to set up Sliding Sync with the SDK's built-in support.
async fn try_start_sliding_sync(client: Client) -> Result<JoinHandle<()>, String> {
    use futures_util::StreamExt;
    use matrix_sdk::ruma::events::StateEventType as RoomStateType;
    use matrix_sdk::sliding_sync::{SlidingSync, SlidingSyncList, SlidingSyncMode, Version};

    async fn build_sliding_sync(client: &Client) -> Result<SlidingSync, String> {
        client
            .sliding_sync("main")
            .map_err(|e| format!("Failed to create Sliding Sync: {e}"))?
            .version(Version::Native)
            .with_all_extensions()
            .with_receipt_extension(receipt_extension_for_subscribed_rooms())
            .add_list(
                SlidingSyncList::builder("all_rooms")
                    .sync_mode(SlidingSyncMode::Growing {
                        batch_size: 50,
                        maximum_number_of_rooms_to_fetch: Some(500),
                    })
                    .required_state(vec![
                        (RoomStateType::RoomName, "".to_owned()),
                        (RoomStateType::RoomAvatar, "".to_owned()),
                        (RoomStateType::RoomCanonicalAlias, "".to_owned()),
                        (RoomStateType::RoomMember, "".to_owned()),
                        (RoomStateType::RoomTopic, "".to_owned()),
                        // Space membership: without these, get_space_children and
                        // get_ungrouped_rooms see no parent/child relationships and
                        // every grouped room appears "ungrouped".
                        (RoomStateType::SpaceChild, "".to_owned()),
                        (RoomStateType::SpaceParent, "".to_owned()),
                        // Room type (m.room.create) so is_space() resolves reliably
                        // without a second round-trip.
                        (RoomStateType::RoomCreate, "".to_owned()),
                    ])
                    .timeline_limit(10u32),
            )
            .build()
            .await
            .map_err(|e| format!("Failed to build Sliding Sync: {e}"))
    }

    build_sliding_sync(&client).await?;

    // Spawn the sync loop
    let handle = tokio::spawn(async move {
        app_log("info", "sync", "Sliding Sync loop started".to_string());
        loop {
            let sliding_sync = match build_sliding_sync(&client).await {
                Ok(sync) => sync,
                Err(e) => {
                    app_log("error", "sync", format!("Sliding Sync rebuild failed: {e}"));
                    set_connection_status(ConnectionStatus::Disconnected);
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    continue;
                }
            };
            // Atomically publish the live instance and replay mounted rooms'
            // subscriptions onto it. The old instance (and its sticky
            // subscriptions) is gone after a reconnect, so without replay the
            // mounted rooms would stop receiving receipt deltas until re-entry.
            // subscribe_to_rooms is synchronous, so we do it
            // under the same lock to keep desired/active consistent.
            let mut sub_state = ROOM_SUBSCRIPTION.lock().await;
            sub_state.active = Some(sliding_sync.clone());
            for room_id in sub_state.desired.keys() {
                if let Ok(parsed) = matrix_sdk::ruma::RoomId::parse(room_id.as_str()) {
                    use matrix_sdk::ruma::api::client::sync::sync_events::v5::request::RoomSubscription;
                    use matrix_sdk::ruma::UInt;
                    let mut sub = RoomSubscription::default();
                    sub.timeline_limit = UInt::from(50u32);
                    sliding_sync.subscribe_to_rooms(&[&parsed], Some(sub), false);
                }
            }
            drop(sub_state);

            let stream = sliding_sync.sync();
            futures_util::pin_mut!(stream);
            while let Some(update) = stream.next().await {
                match update {
                    Ok(summary) => {
                        app_log(
                            "info",
                            "sync",
                            format!("Sliding Sync update: {} rooms", summary.rooms.len()),
                        );
                        set_connection_status(ConnectionStatus::Connected);
                        notify_sync_event(SyncEvent::SyncCompleted);
                    }
                    Err(e) => {
                        app_log("error", "sync", format!("Sliding Sync error: {e}"));
                        set_connection_status(ConnectionStatus::Disconnected);
                        // The instance has failed; drop the published handle
                        // so subscribe/unsubscribe calls during the retry
                        // delay don't mutate a stale, soon-discarded instance.
                        ROOM_SUBSCRIPTION.lock().await.active = None;
                        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    }
                }
            }
            app_log(
                "warn",
                "sync",
                "Sliding Sync stream ended; restarting".to_string(),
            );
            set_connection_status(ConnectionStatus::Disconnected);
            // The stream ended (e.g. server closed the connection); the
            // instance is no longer live, so clear the handle before the
            // retry delay to avoid routing room subscriptions to it.
            ROOM_SUBSCRIPTION.lock().await.active = None;
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
    });

    Ok(handle)
}

/// Stream real-time sync events from Rust → Dart.
/// Call this once on app start and listen for updates.
/// When a `SyncCompleted` event arrives, refresh the room list.
/// When a `MessageSent` event arrives, refresh that room's messages.
#[frb]
pub fn watch_sync_events(sink: crate::frb_generated::StreamSink<SyncEvent>) {
    let mut rx = SYNC_EVENT_TX.subscribe();
    std::thread::spawn(move || {
        loop {
            match rx.blocking_recv() {
                Ok(event) => {
                    if sink.add(event).is_err() {
                        break; // Dart side disconnected
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    // Dart can be paused while the app is backgrounded. A
                    // synthetic full refresh catches it up without killing
                    // the only Rust -> Dart update bridge.
                    if sink.add(SyncEvent::SyncCompleted).is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}

// ── Typing notifications ─────────────────────────────────────────────

/// Ephemeral "who is typing right now" update for a room, pushed to Dart.
#[frb]
#[derive(Clone, Debug)]
pub struct TypingNotification {
    pub room_id: String,
    pub user_ids: Vec<String>,
}

static TYPING_TX: Lazy<tokio::sync::broadcast::Sender<TypingNotification>> = Lazy::new(|| {
    let (tx, _rx) = tokio::sync::broadcast::channel(64);
    tx
});

/// Handle to the background task that owns the per-room typing subscription,
/// so we can abort it when switching rooms or leaving.
struct TypingTask {
    room_id: String,
    handle: tokio::task::JoinHandle<()>,
}

static TYPING_TASK: Lazy<tokio::sync::Mutex<Option<TypingTask>>> =
    Lazy::new(|| tokio::sync::Mutex::new(None));

fn take_typing_task_for_room(task: &mut Option<TypingTask>, room_id: &str) -> Option<TypingTask> {
    if task
        .as_ref()
        .is_some_and(|active| active.room_id == room_id)
    {
        task.take()
    } else {
        None
    }
}

/// Stream typing-notification updates (room_id + typing user ids) to Dart.
/// Mirrors `watch_sync_events`.
#[frb]
pub fn watch_typing_notifications(sink: crate::frb_generated::StreamSink<TypingNotification>) {
    let mut rx = TYPING_TX.subscribe();
    std::thread::spawn(move || {
        while let Ok(event) = rx.blocking_recv() {
            if sink.add(event).is_err() {
                break; // Dart side disconnected
            }
        }
    });
}

/// Begin listening for typing notifications in `room_id`. Any previous
/// subscription for another room is cancelled first (only one room is
/// tracked at a time). Call `unsubscribe_typing` when leaving the room.
#[frb]
pub async fn subscribe_typing_for_room(room_id: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    // Cancel any previous typing task before starting a new one.
    {
        let mut task = TYPING_TASK.lock().await;
        if let Some(prev) = task.take() {
            prev.handle.abort();
        }
    }

    // subscribe_to_typing_notifications returns (drop_guard, receiver).
    // The guard must stay alive for the lifetime of the subscription, so we
    // move it into the spawned task along with the receiver.
    let (guard, mut rx) = room.subscribe_to_typing_notifications();
    let tx = TYPING_TX.clone();
    let room_id_for_task = room_id.clone();

    let handle = tokio::spawn(async move {
        // Keep the guard alive by holding it for the task's lifetime.
        let _guard = guard;
        while let Ok(user_ids) = rx.recv().await {
            let ids: Vec<String> = user_ids.into_iter().map(|u| u.to_string()).collect();
            let _ = tx.send(TypingNotification {
                room_id: room_id_for_task.clone(),
                user_ids: ids,
            });
        }
    });

    let mut task = TYPING_TASK.lock().await;
    *task = Some(TypingTask { room_id, handle });
    Ok(())
}

/// Stop tracking typing notifications (e.g. when leaving the room screen).
#[frb]
pub async fn unsubscribe_typing(room_id: String) {
    let mut task = TYPING_TASK.lock().await;
    if let Some(task) = take_typing_task_for_room(&mut task, &room_id) {
        task.handle.abort();
    }
}

#[cfg(test)]
mod typing_subscription_tests {
    use super::{take_typing_task_for_room, TypingTask};

    #[tokio::test]
    async fn stale_unsubscribe_does_not_cancel_a_newer_room() {
        let handle = tokio::spawn(std::future::pending());
        let mut task = Some(TypingTask {
            room_id: "!current:example.org".to_string(),
            handle,
        });

        assert!(take_typing_task_for_room(&mut task, "!stale:example.org").is_none());
        assert_eq!(task.as_ref().unwrap().room_id, "!current:example.org");

        task.take().unwrap().handle.abort();
    }
}

/// Subscribe to the given room in the Sliding Sync instance so that it is
/// included in every sync roundtrip, ensuring read-receipt deltas for it are
/// always delivered. Call when entering a room screen.
///
/// If Sliding Sync is not yet ready (startup race / account switch), the
/// desire is recorded and applied automatically once the sync loop publishes
/// an instance; this function never fails for that reason.
///
/// `desired`/`active` are updated under a single lock so concurrent calls
/// can't interleave (a late-finishing old subscribe can't overwrite a newer
/// room).
#[frb]
pub async fn subscribe_room_for_receipts(room_id: String) -> Result<(), String> {
    let parsed = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| format!("Invalid room id: {e}"))?;
    let mut state = ROOM_SUBSCRIPTION.lock().await;
    let first_subscriber = state.add_desired(&room_id);
    if first_subscriber {
        if let Some(sliding_sync) = state.active.as_ref() {
            use matrix_sdk::ruma::api::client::sync::sync_events::v5::request::RoomSubscription;
            use matrix_sdk::ruma::UInt;
            let mut sub = RoomSubscription::default();
            sub.timeline_limit = UInt::from(50u32);
            sliding_sync.subscribe_to_rooms(&[&parsed], Some(sub), true);
        }
    }
    Ok(())
}

/// Unsubscribe the given room from Sliding Sync (e.g. when leaving the room
/// screen). Receipts for it will still arrive when the room has timeline
/// activity, but not on every roundtrip. Uses `unsubscribe_to_rooms` (not a
/// no-op re-subscribe) so the subscription is actually removed, keeping sync
/// cost bounded as the user visits different rooms.
///
/// The room is removed only after its last mounted owner unsubscribes. The
/// update runs under the same lock as subscribe, so overlapping routes cannot
/// cancel each other's subscription.
#[frb]
pub async fn unsubscribe_room_for_receipts(room_id: String) -> Result<(), String> {
    let parsed = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| format!("Invalid room id: {e}"))?;
    let mut state = ROOM_SUBSCRIPTION.lock().await;
    let last_subscriber = state.remove_desired(&room_id);
    if last_subscriber {
        if let Some(sliding_sync) = state.active.as_ref() {
            sliding_sync.unsubscribe_to_rooms(&[&parsed], true);
        }
    }
    Ok(())
}

/// Check if background sync is alive.
#[frb]
pub async fn is_connected() -> bool {
    let task_running = SYNC_TASK
        .lock()
        .await
        .as_ref()
        .is_some_and(|task| !task.handle.is_finished());
    task_running
}

// ── Chat functions ───────────────────────────────────────────────────

#[frb(sync)]
pub fn get_connection_status() -> ConnectionStatus {
    CONNECTION_STATE
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

#[frb]
pub async fn init_client() -> Result<(), String> {
    Ok(())
}

fn mxc_to_thumbnail_http(
    client: &matrix_sdk::Client,
    mxc_url: &str,
    width: u32,
    height: u32,
) -> Option<String> {
    let url = url::Url::parse(mxc_url).ok()?;
    if url.scheme() != "mxc" {
        return None;
    }
    let server_name = url.host_str()?;
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

/// Convert an mxc:// URI to an avatar-sized thumbnail HTTP URL.
/// Format: `{homeserver}/_matrix/client/v1/media/thumbnail/{server}/{mediaId}?width=96&height=96&method=scale`
#[frb]
pub async fn mxc_to_http_avatar(mxc_url: String) -> Option<String> {
    let client = get_client().await?;
    let media_url = mxc_to_thumbnail_http(&client, &mxc_url, 96, 96)?;
    app_log(
        "info",
        "media",
        format!("Resolved avatar thumbnail for {}", mxc_url),
    );
    Some(media_url)
}

/// Convert an mxc:// URI to a scaled thumbnail HTTP URL for message media.
#[frb]
pub async fn mxc_to_http_thumbnail(mxc_url: String, width: u32, height: u32) -> Option<String> {
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

/// Convert an mxc:// URI to a thumbnail HTTP URL for chat bubbles.
/// Format: `{homeserver}/_matrix/client/v1/media/thumbnail/{server}/{mediaId}?width=800&height=600&method=scale`
#[frb]
pub async fn mxc_to_http(mxc_url: String) -> Option<String> {
    mxc_to_http_thumbnail(mxc_url, 800, 600).await
}

/// Convert an mxc:// URI to a full-quality download HTTP URL.
/// Used for "原图" (original quality) preview.
#[frb]
pub async fn mxc_to_http_full(mxc_url: String) -> Option<String> {
    let client = get_client().await?;
    let url = url::Url::parse(&mxc_url).ok()?;
    if url.scheme() != "mxc" {
        return None;
    }
    let server_name = url.host_str()?;
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

/// Download media content as raw bytes using the Matrix SDK's HTTP client.
/// This is more reliable than constructing URLs and loading from Flutter.
#[frb]
pub async fn download_media_bytes(mxc_url: String) -> Option<Vec<u8>> {
    let client = get_client().await?;
    let url = url::Url::parse(&mxc_url).ok()?;
    if url.scheme() != "mxc" {
        return None;
    }
    let server_name = url.host_str()?.to_string();
    let media_id = url.path().trim_start_matches('/').to_string();
    if server_name.is_empty() || media_id.is_empty() {
        return None;
    }

    use matrix_sdk::ruma::api::client::authenticated_media::get_content::v1::Request as MediaDownloadRequest;
    let server = matrix_sdk::ruma::ServerName::parse(&server_name).ok()?;
    let request = MediaDownloadRequest::new(media_id, server);

    match client.send(request).await {
        Ok(response) => {
            app_log(
                "info",
                "media",
                format!(
                    "download_media_bytes: {} bytes for {}",
                    response.file.len(),
                    mxc_url
                ),
            );
            Some(response.file)
        }
        Err(e) => {
            app_log(
                "error",
                "media",
                format!("download_media_bytes failed: {e}"),
            );
            None
        }
    }
}

fn media_download_limit(max_size_bytes: i32) -> Result<usize, String> {
    usize::try_from(max_size_bytes)
        .ok()
        .filter(|limit| *limit > 0)
        .ok_or_else(|| "Media download limit must be positive.".to_string())
}

fn ensure_media_content_length(content_length: Option<u64>, limit: usize) -> Result<(), String> {
    if content_length.is_some_and(|length| length > limit as u64) {
        return Err(format!("Media exceeds the {limit}-byte download limit."));
    }
    Ok(())
}

fn append_media_chunk(content: &mut Vec<u8>, chunk: &[u8], limit: usize) -> Result<(), String> {
    let next_length = content
        .len()
        .checked_add(chunk.len())
        .ok_or_else(|| "Media download is too large.".to_string())?;
    if next_length > limit {
        return Err(format!("Media exceeds the {limit}-byte download limit."));
    }
    content.extend_from_slice(chunk);
    Ok(())
}

fn media_download_url(
    client: &Client,
    source: &matrix_sdk::ruma::events::room::MediaSource,
) -> Result<url::Url, String> {
    let mxc_url = match source {
        matrix_sdk::ruma::events::room::MediaSource::Plain(uri) => uri.to_string(),
        matrix_sdk::ruma::events::room::MediaSource::Encrypted(file) => file.url.to_string(),
    };
    let mxc_url = url::Url::parse(&mxc_url).map_err(|e| format!("Invalid media URL: {e}"))?;
    if mxc_url.scheme() != "mxc" {
        return Err("Media URL must use the mxc scheme.".to_string());
    }
    let server_name = mxc_url
        .host_str()
        .filter(|server_name| !server_name.is_empty())
        .ok_or("Media URL is missing a server name.")?;
    let server_name = match mxc_url.port() {
        Some(port) => format!("{server_name}:{port}"),
        None => server_name.to_string(),
    };
    let media_id = mxc_url.path().trim_start_matches('/');
    if media_id.is_empty() {
        return Err("Media URL is missing a media ID.".to_string());
    }

    let mut url = client.homeserver();
    url.set_path("/");
    url.set_query(None);
    url.set_fragment(None);
    let mut segments = url
        .path_segments_mut()
        .map_err(|_| "Homeserver URL cannot contain path segments.".to_string())?;
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

fn decrypt_media_bytes(
    encrypted: Vec<u8>,
    file: matrix_sdk::ruma::events::room::EncryptedFile,
    limit: usize,
) -> Result<Vec<u8>, String> {
    let capacity = encrypted.len();
    let mut cursor = Cursor::new(encrypted);
    let mut decryptor = matrix_sdk_base::crypto::AttachmentDecryptor::new(&mut cursor, file.into())
        .map_err(|e| format!("Invalid encrypted media: {e}"))?;
    let mut decrypted = Vec::with_capacity(capacity);
    decryptor
        .by_ref()
        .take(limit as u64 + 1)
        .read_to_end(&mut decrypted)
        .map_err(|e| format!("Media decryption failed: {e}"))?;
    if decrypted.len() > limit {
        return Err(format!("Media exceeds the {limit}-byte download limit."));
    }
    Ok(decrypted)
}

/// Download a Matrix media source, decrypting and integrity-checking encrypted
/// attachments through the SDK when necessary. The response is read in bounded
/// chunks so automatic media previews cannot allocate unbounded memory.
#[frb]
pub async fn download_media_source_bytes(
    media_source_json: String,
    max_size_bytes: i32,
) -> Result<Vec<u8>, String> {
    use futures_util::StreamExt;

    let client = get_client().await.ok_or("No client created.")?;
    let source: matrix_sdk::ruma::events::room::MediaSource =
        serde_json::from_str(&media_source_json)
            .map_err(|e| format!("Invalid media source: {e}"))?;
    let limit = media_download_limit(max_size_bytes)?;
    let url = media_download_url(&client, &source)?;
    let session = client
        .matrix_auth()
        .session()
        .ok_or("No authenticated session.")?;
    let response = client
        .http_client()
        .get(url)
        .bearer_auth(session.tokens.access_token)
        .send()
        .await
        .map_err(|e| format!("Media download failed: {e}"))?
        .error_for_status()
        .map_err(|e| format!("Media download failed: {e}"))?;
    ensure_media_content_length(response.content_length(), limit)?;

    let mut encrypted = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("Media download failed: {e}"))?;
        append_media_chunk(&mut encrypted, &chunk, limit)?;
    }

    let content = match source {
        matrix_sdk::ruma::events::room::MediaSource::Encrypted(file) => {
            decrypt_media_bytes(encrypted, *file, limit)?
        }
        matrix_sdk::ruma::events::room::MediaSource::Plain(_) => encrypted,
    };
    app_log(
        "info",
        "media",
        format!("download_media_source_bytes: {} bytes", content.len()),
    );
    Ok(content)
}

/// Get the current access token for authenticated media requests.
#[frb]
pub async fn get_access_token() -> Option<String> {
    let client = get_client().await?;
    let session = client.matrix_auth().session()?;
    Some(session.tokens.access_token)
}

#[frb]
pub async fn get_refresh_token() -> Option<String> {
    let client = get_client().await?;
    let session = client.matrix_auth().session()?;
    session.tokens.refresh_token
}

#[frb]
pub async fn is_room_encrypted(room_id: String) -> Result<bool, String> {
    let client = get_client()
        .await
        .ok_or_else(|| "No client created.".to_string())?;
    let room = get_room_by_id(&client, &room_id)?;
    Ok(room
        .latest_encryption_state()
        .await
        .map(|state| state.is_encrypted())
        .unwrap_or(true))
}

#[frb]
pub async fn get_chat_rooms() -> Result<Vec<ChatRoom>, String> {
    let client = get_client().await.ok_or_else(|| {
        app_log(
            "error",
            "rooms",
            "get_chat_rooms: no client created".to_string(),
        );
        "No client created.".to_string()
    })?;

    let rooms = client.rooms();
    app_log(
        "info",
        "rooms",
        format!("get_chat_rooms: found {} total rooms", rooms.len()),
    );
    let mut result = Vec::new();
    let mut visible = 0;

    for room in rooms {
        if !matches!(
            room.state(),
            matrix_sdk::RoomState::Joined
                | matrix_sdk::RoomState::Invited
                | matrix_sdk::RoomState::Knocked
        ) {
            continue;
        }
        visible += 1;

        let mut chat_room = room_to_chat_room(&room).await;
        if room.state() == matrix_sdk::RoomState::Joined && !room.is_space() {
            chat_room.room_type = match room.is_direct().await {
                Ok(true) => "dm".to_string(),
                _ => "group".to_string(),
            };
        }
        result.push(chat_room);
    }

    app_log(
        "info",
        "rooms",
        format!("get_chat_rooms: {} visible rooms returned", visible),
    );
    result.sort_by(|a, b| {
        let a_time = a.last_message_time.parse::<u64>().unwrap_or_default();
        let b_time = b.last_message_time.parse::<u64>().unwrap_or_default();
        b_time
            .cmp(&a_time)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(result)
}

fn get_last_message_info(room: &matrix_sdk::Room) -> (String, Option<String>, String) {
    let mut last_msg = "(暂无消息)".to_string();
    let mut last_time = String::new();

    let latest_value = room.latest_event();
    if let matrix_sdk::latest_events::LatestEventValue::Remote(latest) = latest_value {
        let raw = latest.raw();
        if let Ok(any_ev) = raw.deserialize() {
            // Always record the latest event's timestamp for sorting, so that
            // rooms whose newest event isn't a text message (e.g. a reaction or
            // a state change) don't sink to the bottom of the list.
            last_time = u64::from(any_ev.origin_server_ts().0).to_string();

            if latest.kind.is_utd() {
                return (
                    "无法解密此消息".to_string(),
                    Some(any_ev.sender().to_string()),
                    last_time,
                );
            }

            let sender_id = any_ev.sender().to_string();
            let preview = match any_ev {
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(msg),
                ) => msg
                    .as_original()
                    .and_then(|event| room_message_preview(&event.content)),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollStart(poll),
                ) => poll
                    .as_original()
                    .and_then(|event| unstable_poll_preview(&event.content)),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollResponse(
                        response,
                    ),
                ) => response
                    .as_original()
                    .map(|_| "[投票] 有人投票".to_string()),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollEnd(end),
                ) => end.as_original().map(|_| "[投票] 投票已结束".to_string()),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::Sticker(sticker),
                ) => sticker
                    .as_original()
                    .map(|o| format!("[贴纸] {}", o.content.body)),
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::Reaction(_),
                ) => Some("❤️ 表情回应".to_string()),
                _ => None,
            };

            if let Some(mut text) = preview {
                if text.len() > 50 {
                    // Safe truncation that respects UTF-8 char boundaries
                    let mut end = 50;
                    while end > 0 && !text.is_char_boundary(end) {
                        end -= 1;
                    }
                    text.truncate(end);
                    text.push_str("...");
                }
                last_msg = text;
                return (last_msg, Some(sender_id), last_time);
            }
        }
    }

    (last_msg, None, last_time)
}

fn room_message_preview(
    content: &matrix_sdk::ruma::events::room::message::RoomMessageEventContent,
) -> Option<String> {
    // An edit carries the new text in new_content, while its fallback body is
    // conventionally prefixed with "* ".
    if let Some(matrix_sdk::ruma::events::room::message::Relation::Replacement(replacement)) =
        &content.relates_to
    {
        if let Some(edited) = extract_edit_content(&replacement.new_content) {
            return Some(edited.body);
        }
    }

    match &content.msgtype {
        matrix_sdk::ruma::events::room::message::MessageType::Text(text) => {
            let is_reply = matches!(
                &content.relates_to,
                Some(matrix_sdk::ruma::events::room::message::Relation::Reply(_))
            );
            Some(if is_reply {
                strip_reply_fallback(&text.body)
            } else {
                text.body.clone()
            })
        }
        matrix_sdk::ruma::events::room::message::MessageType::Image(image) => {
            Some(format!("[图片] {}", image.body))
        }
        matrix_sdk::ruma::events::room::message::MessageType::Video(video) => {
            Some(format!("[视频] {}", video.filename()))
        }
        matrix_sdk::ruma::events::room::message::MessageType::File(file) => {
            Some(format!("[文件] {}", file.filename()))
        }
        matrix_sdk::ruma::events::room::message::MessageType::Audio(audio) => {
            Some(format!("[音频] {}", audio.filename()))
        }
        matrix_sdk::ruma::events::room::message::MessageType::Location(location) => {
            let label = if location.body.trim().is_empty() {
                &location.geo_uri
            } else {
                &location.body
            };
            Some(format!("[位置] {label}"))
        }
        matrix_sdk::ruma::events::room::message::MessageType::Emote(emote) => {
            Some(emote.body.clone())
        }
        _ => None,
    }
}

fn unstable_poll_preview(
    content: &matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent,
) -> Option<String> {
    let question = content.poll_start().question.text.trim();
    (!question.is_empty()).then(|| format!("[投票] {question}"))
}

/// Strip the Matrix reply fallback prefix from a message body.
/// Matrix replies include a fallback like:
///   > <@user:server> Original message
///
///   Actual reply
/// We strip the leading `> <...>` line and the blank separator line.
fn strip_reply_fallback(body: &str) -> String {
    if let Some(rest) = body.strip_prefix("> <") {
        if let Some(line_end) = rest.find('\n') {
            let after_first_line = &rest[line_end + 1..];
            if after_first_line.starts_with('\n') {
                return after_first_line[1..].to_string();
            }
            if let Some(after_crlf) = after_first_line.strip_prefix("\r\n") {
                if after_crlf.starts_with('\n') {
                    return after_crlf[1..].to_string();
                }
                if after_crlf.starts_with("\r\n") {
                    return after_crlf[2..].to_string();
                }
            }
        }
    }
    body.to_string()
}

fn sanitized_formatted_body(
    formatted: Option<&matrix_sdk::ruma::events::room::message::FormattedBody>,
) -> Option<String> {
    let formatted = formatted?;
    if !matches!(
        &formatted.format,
        matrix_sdk::ruma::events::room::message::MessageFormat::Html
    ) {
        return None;
    }
    let html = matrix_sdk::ruma::html::sanitize_html(
        &formatted.body,
        matrix_sdk::ruma::html::HtmlSanitizerMode::Strict,
        matrix_sdk::ruma::html::RemoveReplyFallback::No,
    );
    (!html.trim().is_empty()).then_some(html)
}

fn sanitized_reply_formatted_body(
    formatted: Option<&matrix_sdk::ruma::events::room::message::FormattedBody>,
) -> Option<String> {
    let formatted = formatted?;
    if !matches!(
        &formatted.format,
        matrix_sdk::ruma::events::room::message::MessageFormat::Html
    ) {
        return None;
    }
    let html = matrix_sdk::ruma::html::sanitize_html(
        &formatted.body,
        matrix_sdk::ruma::html::HtmlSanitizerMode::Strict,
        matrix_sdk::ruma::html::RemoveReplyFallback::Yes,
    );
    (!html.trim().is_empty()).then_some(html)
}

fn media_caption_parts(
    formatted: Option<&matrix_sdk::ruma::events::room::message::FormattedBody>,
    fallback: Option<&str>,
) -> (Option<String>, Option<String>) {
    let caption = fallback
        .map(str::trim)
        .filter(|caption| !caption.is_empty())
        .map(ToString::to_string);
    (caption, sanitized_formatted_body(formatted))
}

fn mentions_parts(mentions: Option<&matrix_sdk::ruma::events::Mentions>) -> (Vec<String>, bool) {
    let Some(mentions) = mentions else {
        return (Vec::new(), false);
    };
    (
        mentions.user_ids.iter().map(ToString::to_string).collect(),
        mentions.room,
    )
}

fn text_message_parts(
    body: &str,
    formatted: Option<&matrix_sdk::ruma::events::room::message::FormattedBody>,
    mentions: Option<&matrix_sdk::ruma::events::Mentions>,
    is_reply: bool,
) -> (String, Option<String>, Vec<String>, bool) {
    let body = if is_reply {
        strip_reply_fallback(body)
    } else {
        body.to_string()
    };
    let formatted_body = if is_reply {
        sanitized_reply_formatted_body(formatted)
    } else {
        sanitized_formatted_body(formatted)
    };
    let (mentioned_user_ids, mentions_room) = mentions_parts(mentions);
    (body, formatted_body, mentioned_user_ids, mentions_room)
}

#[derive(Clone, Debug)]
struct EditedTextContent {
    body: String,
}

fn extract_edit_content(
    new_content: &matrix_sdk::ruma::events::room::message::RoomMessageEventContentWithoutRelation,
) -> Option<EditedTextContent> {
    let body = match &new_content.msgtype {
        matrix_sdk::ruma::events::room::message::MessageType::Text(t) => Some(t.body.clone()),
        matrix_sdk::ruma::events::room::message::MessageType::Notice(t) => Some(t.body.clone()),
        _ => None,
    }?;
    Some(EditedTextContent { body })
}

#[cfg(test)]
mod formatted_message_tests {
    use super::{build_text_content, text_message_parts, FormattedMessageInput};
    use matrix_sdk::ruma::events::{
        room::message::{FormattedBody, RoomMessageEventContent},
        Mentions,
    };

    #[test]
    fn outgoing_html_is_sanitized_and_mentions_are_serialized() {
        let content = build_text_content(FormattedMessageInput {
            body: "Hello Alice".to_string(),
            formatted_body: Some(r#"<strong>Hello</strong><script>bad()</script>"#.to_string()),
            mentioned_user_ids: vec!["@alice:example.org".to_string()],
            mentions_room: false,
        })
        .unwrap();
        let json = serde_json::to_value(&content).unwrap();

        assert_eq!(json["body"], "Hello Alice");
        assert_eq!(json["format"], "org.matrix.custom.html");
        assert!(json["formatted_body"]
            .as_str()
            .unwrap()
            .contains("<strong>"));
        assert!(!json["formatted_body"].as_str().unwrap().contains("<script"));
        assert_eq!(json["m.mentions"]["user_ids"][0], "@alice:example.org");
    }

    #[test]
    fn incoming_formatted_body_keeps_plain_fallback_separate() {
        let formatted = FormattedBody::html("<strong>Hello</strong>".to_string());
        let mentions =
            Mentions::with_user_ids(vec![
                matrix_sdk::ruma::UserId::parse("@alice:example.org").unwrap()
            ]);
        let (body, html, user_ids, room) =
            text_message_parts("Hello", Some(&formatted), Some(&mentions), false);

        assert_eq!(body, "Hello");
        assert_eq!(html.as_deref(), Some("<strong>Hello</strong>"));
        assert_eq!(user_ids, ["@alice:example.org"]);
        assert!(!room);
    }

    #[test]
    fn empty_formatting_sends_plain_text_with_empty_mentions_object() {
        let content = build_text_content(FormattedMessageInput {
            body: "Hello".to_string(),
            formatted_body: None,
            mentioned_user_ids: vec![],
            mentions_room: false,
        })
        .unwrap();
        let json = serde_json::to_value(&content).unwrap();

        assert_eq!(json["body"], "Hello");
        assert!(json.get("formatted_body").is_none());
        assert_eq!(json["m.mentions"], serde_json::json!({}));
        assert!(matches!(
            content,
            RoomMessageEventContent {
                mentions: Some(_),
                ..
            }
        ));
    }
}

fn unable_to_decrypt_message(
    id: String,
    sender_id: String,
    sender_name: String,
    timestamp: String,
    is_me: bool,
) -> ChatMessage {
    ChatMessage {
        id,
        sender_id,
        sender_name,
        content: "无法解密此消息（缺少会话密钥）".to_string(),
        formatted_body: None,
        caption: None,
        caption_formatted_body: None,
        mentioned_user_ids: Vec::new(),
        mentions_room: false,
        timestamp,
        is_me,
        msg_type: MessageType::Text,
        image_url: None,
        media_source_json: None,
        image_width: None,
        image_height: None,
        filename: None,
        file_size: None,
        geo_uri: None,
        poll: None,
        in_reply_to: None,
        is_edited: false,
        edit_history: Vec::new(),
        reactions: Vec::new(),
        readers: Vec::new(),
        total_members: 0,
    }
}

/// Get messages for a room (must sync first).
#[frb]
pub async fn get_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    sdk_timeline::get_messages(&client, &room).await
}

#[frb]
pub async fn get_sticker_packs(room_id: String) -> Result<Vec<StickerPack>, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let parsed_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| format!("Invalid room id: {e}"))?;
    let room = client
        .get_room(&parsed_room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let imported_room_packs = client
        .account()
        .account_data::<ruma::events::image_pack::ImagePackRoomsEventContent>()
        .await
        .map_err(|e| format!("Failed to load image-pack room mapping: {e}"))?
        .and_then(|raw| raw.deserialize().ok())
        .map(|content| {
            content
                .rooms
                .into_iter()
                .map(|(source_room_id, packs)| {
                    (
                        source_room_id.to_string(),
                        packs
                            .keys()
                            .map(|state_key| state_key.to_string())
                            .collect::<std::collections::HashSet<_>>(),
                    )
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let mut packs = Vec::new();
    let mut seen_pack_ids = std::collections::HashSet::new();

    for pack in load_room_sticker_packs(&room, None).await? {
        if seen_pack_ids.insert(pack.id.clone()) {
            packs.push(pack);
        }
    }

    for (source_room_id, enabled_state_keys) in imported_room_packs {
        let parsed_source_room_id = match matrix_sdk::ruma::RoomId::parse(source_room_id.clone()) {
            Ok(room_id) => room_id,
            Err(_) => continue,
        };
        let Some(source_room) = client.get_room(&parsed_source_room_id) else {
            continue;
        };

        for pack in load_room_sticker_packs(&source_room, Some(&enabled_state_keys)).await? {
            if seen_pack_ids.insert(pack.id.clone()) {
                packs.push(pack);
            }
        }
    }

    if let Some(user_pack_raw) = client
        .account()
        .account_data::<ruma::events::image_pack::AccountImagePackEventContent>()
        .await
        .map_err(|e| format!("Failed to load user sticker pack: {e}"))?
    {
        if let Ok(user_pack_content) = user_pack_raw.deserialize() {
            if let Some(pack) = account_image_pack_to_sticker_pack(user_pack_content) {
                if seen_pack_ids.insert(pack.id.clone()) {
                    packs.push(pack);
                }
            }
        }
    }

    packs.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    Ok(packs)
}

fn build_mentions(
    user_ids: &[String],
    room: bool,
) -> Result<matrix_sdk::ruma::events::Mentions, String> {
    let mut mentions = matrix_sdk::ruma::events::Mentions::new();
    mentions.room = room;
    for user_id in user_ids {
        mentions.user_ids.insert(
            matrix_sdk::ruma::UserId::parse(user_id)
                .map_err(|e| format!("Invalid mentioned user ID {user_id}: {e}"))?,
        );
    }
    Ok(mentions)
}

fn build_text_content(
    message: FormattedMessageInput,
) -> Result<matrix_sdk::ruma::events::room::message::RoomMessageEventContent, String> {
    let mentions = build_mentions(&message.mentioned_user_ids, message.mentions_room)?;
    let formatted_body = message
        .formatted_body
        .map(|html| {
            matrix_sdk::ruma::html::sanitize_html(
                &html,
                matrix_sdk::ruma::html::HtmlSanitizerMode::Strict,
                matrix_sdk::ruma::html::RemoveReplyFallback::No,
            )
        })
        .filter(|html| !html.trim().is_empty());
    let mut content = if let Some(formatted_body) = formatted_body {
        matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_html(
            message.body,
            formatted_body,
        )
    } else {
        matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_plain(message.body)
    };
    // Always set m.mentions, including an empty object, to avoid legacy
    // implicit-mention push rules.
    content.mentions = Some(mentions);
    Ok(content)
}

#[frb]
pub async fn send_message(
    room_id: String,
    message: FormattedMessageInput,
) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    let content = build_text_content(message)?;

    let response = room
        .send(content)
        .await
        .map_err(|e| format!("Send failed: {e}"))?;

    app_log("info", "rooms", format!("Message sent to {}", room_id));
    info!("Message sent to {}", room_id);
    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(response.response.event_id.to_string())
}

fn poll_start_for_forward(
    content: &matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent,
) -> Result<matrix_sdk::ruma::events::poll::unstable_start::NewUnstablePollStartEventContent, String>
{
    use matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent;

    let UnstablePollStartEventContent::New(content) = content else {
        return Err("无法将投票编辑事件作为新投票转发".to_string());
    };
    let mut content = content.clone();
    content.relates_to = None;
    Ok(content)
}

/// Forward a message-like event into another room as a new event.
///
/// Text uses the already-aggregated content supplied by Flutter so edits are
/// forwarded at their latest visible revision. Media keeps its original
/// Matrix source, avoiding a lossy download and re-upload cycle; its caption
/// reflects the original event (the app does not currently aggregate media
/// caption edits — see `extract_edit_content`), so it matches what the user
/// sees in the bubble.
#[frb]
pub async fn forward_message(
    source_room_id: String,
    target_room_id: String,
    event_id: String,
    text: FormattedMessageInput,
) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let source_room = get_room_by_id(&client, &source_room_id)?;
    let target_room = get_room_by_id(&client, &target_room_id)?;
    let event_id =
        matrix_sdk::ruma::EventId::parse(event_id).map_err(|e| format!("Invalid event id: {e}"))?;
    let timeline_event = source_room
        .event(&event_id, None)
        .await
        .map_err(|e| format!("Load message failed: {e}"))?;

    if timeline_event.kind.is_utd() {
        return Err("无法转发未解密的消息".to_string());
    }

    let event = timeline_event
        .raw()
        .deserialize()
        .map_err(|e| format!("Read message failed: {e}"))?;

    let event_id = match event {
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(message),
        ) => {
            let Some(original) = message.as_original() else {
                return Err("无法转发已撤回的消息".to_string());
            };
            let mut content = original.content.clone();
            if matches!(
                &content.msgtype,
                matrix_sdk::ruma::events::room::message::MessageType::Text(_)
            ) {
                content = build_text_content(text)?;
            } else {
                content.relates_to = None;
            }
            target_room
                .send(content)
                .await
                .map_err(|e| format!("Forward failed: {e}"))?
                .response
                .event_id
                .to_string()
        }
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::Sticker(sticker),
        ) => {
            let Some(original) = sticker.as_original() else {
                return Err("无法转发已撤回的贴纸".to_string());
            };
            let mut content = original.content.clone();
            content.relates_to = None;
            target_room
                .send(content)
                .await
                .map_err(|e| format!("Forward failed: {e}"))?
                .response
                .event_id
                .to_string()
        }
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollStart(poll),
        ) => {
            let Some(original) = poll.as_original() else {
                return Err("无法转发已撤回的投票".to_string());
            };
            let content = poll_start_for_forward(&original.content)?;
            target_room
                .send(content)
                .await
                .map_err(|e| format!("Forward failed: {e}"))?
                .response
                .event_id
                .to_string()
        }
        _ => return Err("该消息类型暂不支持转发".to_string()),
    };

    app_log(
        "info",
        "rooms",
        format!("Message forwarded to {}", target_room_id),
    );
    notify_sync_event(SyncEvent::MessageSent {
        room_id: target_room_id,
    });
    Ok(event_id)
}

fn parse_supplied_mime_type(value: Option<String>) -> Result<Option<mime::Mime>, String> {
    let Some(value) = value.map(|value| value.trim().to_owned()) else {
        return Ok(None);
    };
    if value.is_empty() {
        return Ok(None);
    }
    value
        .parse::<mime::Mime>()
        .map(Some)
        .map_err(|error| format!("Invalid MIME type: {error}"))
}

fn image_mime_type(filename: &str, supplied: Option<String>) -> Result<mime::Mime, String> {
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
        return Err(format!("Expected an image MIME type, got {mime_type}"));
    }
    Ok(mime_type)
}

fn video_mime_type(filename: &str, supplied: Option<String>) -> Result<mime::Mime, String> {
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
        return Err(format!("Expected a video MIME type, got {mime_type}"));
    }
    Ok(mime_type)
}

fn file_message_content(
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

/// Send an image message to a room.
/// `image_data` is the raw bytes of the image file.
/// `filename` is the original file name (e.g. "photo.jpg").
#[frb]
pub async fn send_image_message(
    room_id: String,
    image_data: Vec<u8>,
    filename: String,
    mime_type: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    let mime_type = image_mime_type(&filename, mime_type)?;

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

    use matrix_sdk::attachment::{AttachmentConfig, AttachmentInfo, BaseImageInfo};

    let image_info = BaseImageInfo {
        width: width
            .filter(|value| *value > 0)
            .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64)),
        height: height
            .filter(|value| *value > 0)
            .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64)),
        size: matrix_sdk::ruma::UInt::new(image_data.len() as u64),
        ..Default::default()
    };
    let config = AttachmentConfig::new().info(AttachmentInfo::Image(image_info));

    // send_attachment encrypts both the event and media bytes when the room is
    // encrypted, and keeps the normal plain-media flow for unencrypted rooms.
    room.send_attachment(filename, &mime_type, image_data, config)
        .await
        .map_err(|e| format!("Send image message failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Image message sent to {}", room_id),
    );
    info!("Image message sent to {}", room_id);

    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(())
}

/// Send an arbitrary file (document) attachment to a room.
#[frb]
pub async fn send_file_message(
    room_id: String,
    file_data: Vec<u8>,
    filename: String,
    mime_type: Option<String>,
    size: Option<i32>,
) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    let mime_type = parse_supplied_mime_type(mime_type)?.unwrap_or(mime::APPLICATION_OCTET_STREAM);
    let file_size = size
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64))
        .or_else(|| matrix_sdk::ruma::UInt::new(file_data.len() as u64));

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

    use matrix_sdk::ruma::events::room::MediaSource;
    use std::io::Cursor;

    let source = if room
        .latest_encryption_state()
        .await
        .map_err(|error| format!("Check room encryption failed: {error}"))?
        .is_encrypted()
    {
        let mut reader = Cursor::new(file_data.as_slice());
        let encrypted_file = client
            .upload_encrypted_file(&mut reader)
            .await
            .map_err(|error| format!("Encrypted file upload failed: {error}"))?;
        MediaSource::Encrypted(Box::new(encrypted_file))
    } else {
        let upload = client
            .media()
            .upload(&mime_type, file_data, None)
            .await
            .map_err(|error| format!("File upload failed: {error}"))?;
        MediaSource::Plain(upload.content_uri)
    };
    let content = file_message_content(filename, &mime_type, file_size, source);
    room.send(content)
        .await
        .map_err(|e| format!("Send file message failed: {e}"))?;

    app_log("info", "rooms", format!("File message sent to {}", room_id));
    info!("File message sent to {}", room_id);

    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(())
}

/// Send a video attachment to a room.
#[frb]
#[allow(clippy::too_many_arguments)]
pub async fn send_video_message(
    room_id: String,
    video_data: Vec<u8>,
    filename: String,
    mime_type: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
    duration_ms: Option<i32>,
    size: Option<i32>,
) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    let mime_type = video_mime_type(&filename, mime_type)?;

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

    use matrix_sdk::attachment::{AttachmentConfig, AttachmentInfo, BaseVideoInfo};

    let info = BaseVideoInfo {
        width: width
            .filter(|value| *value > 0)
            .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64)),
        height: height
            .filter(|value| *value > 0)
            .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64)),
        duration: duration_ms
            .filter(|value| *value > 0)
            .map(|value| matrix_sdk::ruma::time::Duration::from_millis(value as u64)),
        size: size
            .filter(|value| *value > 0)
            .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64))
            .or_else(|| matrix_sdk::ruma::UInt::new(video_data.len() as u64)),
        ..Default::default()
    };
    let config = AttachmentConfig::new().info(AttachmentInfo::Video(info));

    room.send_attachment(&filename, &mime_type, video_data, config)
        .await
        .map_err(|e| format!("Send video message failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Video message sent to {}", room_id),
    );
    info!("Video message sent to {}", room_id);

    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(())
}

/// Validate the RFC 5870 subset supported by the attachment composer.
fn validated_geo_uri(value: &str) -> Result<String, String> {
    let value = value.trim();
    let uri = url::Url::parse(value).map_err(|error| format!("Invalid geo URI: {error}"))?;
    if uri.scheme() != "geo" || uri.query().is_some() || uri.fragment().is_some() {
        return Err("Location must be a geo: URI without a query or fragment.".to_string());
    }

    let coordinate_part = uri.path().split(';').next().unwrap_or_default();
    let coordinates = coordinate_part.split(',').collect::<Vec<_>>();
    if !(2..=3).contains(&coordinates.len()) {
        return Err("Location must contain latitude and longitude.".to_string());
    }
    if coordinates
        .iter()
        .any(|coordinate| coordinate.contains(['e', 'E']))
    {
        return Err("Location coordinates must use decimal notation.".to_string());
    }
    let latitude = coordinates[0]
        .parse::<f64>()
        .map_err(|_| "Invalid latitude.".to_string())?;
    let longitude = coordinates[1]
        .parse::<f64>()
        .map_err(|_| "Invalid longitude.".to_string())?;
    if !latitude.is_finite() || !(-90.0..=90.0).contains(&latitude) {
        return Err("Latitude must be between -90 and 90.".to_string());
    }
    if !longitude.is_finite() || !(-180.0..=180.0).contains(&longitude) {
        return Err("Longitude must be between -180 and 180.".to_string());
    }
    if coordinates.len() == 3
        && coordinates[2]
            .parse::<f64>()
            .ok()
            .filter(|altitude| altitude.is_finite())
            .is_none()
    {
        return Err("Invalid altitude.".to_string());
    }
    Ok(value.to_owned())
}

fn location_message_content(
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

/// Share a geographic location as legacy `m.room.message` / `m.location`.
///
/// The extensible top-level `m.location` event is not parsed by the current
/// `matrix-sdk-ui` version. `geo_uri` follows RFC 5870, for example
/// `geo:37.786971,-122.399677`.
#[frb]
pub async fn send_location(room_id: String, body: String, geo_uri: String) -> Result<(), String> {
    let content = location_message_content(&body, &geo_uri)?;

    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| format!("Send location failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Location message sent to {}", room_id),
    );
    info!("Location message sent to {}", room_id);

    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(())
}

/// Build a validated unstable poll start event with a plain-text fallback.
fn poll_start_content(
    question: &str,
    answers: Vec<String>,
    disclosed: bool,
    max_selections: usize,
) -> Result<matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent, String> {
    use matrix_sdk::ruma::events::poll::{
        start::PollKind,
        unstable_start::{
            NewUnstablePollStartEventContent, UnstablePollAnswer, UnstablePollAnswers,
            UnstablePollStartContentBlock,
        },
    };

    let question = question.trim();
    if question.is_empty() {
        return Err("A poll question cannot be empty.".to_string());
    }

    let mut answer_list = Vec::with_capacity(answers.len());
    for label in answers {
        let label = label.trim();
        if label.is_empty() {
            continue;
        }
        answer_list.push(UnstablePollAnswer::new(
            answer_list.len().to_string(),
            label,
        ));
    }
    if !(2..=20).contains(&answer_list.len()) {
        return Err("A poll needs between 2 and 20 answers.".to_string());
    }
    if !(1..=answer_list.len()).contains(&max_selections) {
        return Err("A poll's maximum selections must match its answers.".to_string());
    }
    let mut fallback = question.to_owned();
    for (index, answer) in answer_list.iter().enumerate() {
        fallback.push_str(&format!("\n{}. {}", index + 1, answer.text));
    }
    let poll_answers = UnstablePollAnswers::try_from(answer_list)
        .map_err(|_| "A poll needs between 2 and 20 answers.".to_string())?;

    let mut poll_start = UnstablePollStartContentBlock::new(question, poll_answers);
    poll_start.kind = if disclosed {
        PollKind::Disclosed
    } else {
        PollKind::Undisclosed
    };
    poll_start.max_selections = matrix_sdk::ruma::UInt::from(max_selections as u32);
    Ok(NewUnstablePollStartEventContent::plain_text(fallback, poll_start).into())
}

/// Start a poll using the unstable `org.matrix.msc3381.poll.start` event.
///
/// This is the poll type surfaced by the current `matrix-sdk-ui` version; its
/// stable counterpart is not parsed there yet.
#[frb]
pub async fn send_poll(
    room_id: String,
    question: String,
    answers: Vec<String>,
    disclosed: bool,
    max_selections: i32,
) -> Result<(), String> {
    let max_selections = usize::try_from(max_selections)
        .map_err(|_| "A poll's maximum selections must be positive.".to_string())?;
    let content = poll_start_content(&question, answers, disclosed, max_selections)?;

    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| format!("Send poll failed: {e}"))?;

    app_log("info", "rooms", format!("Poll message sent to {}", room_id));
    info!("Poll message sent to {}", room_id);

    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(())
}

fn validate_poll_answer_ids(answer_ids: &[String]) -> Result<(), String> {
    if answer_ids.is_empty()
        || answer_ids.len() > 20
        || answer_ids.iter().any(|answer_id| answer_id.is_empty())
        || answer_ids.iter().collect::<BTreeSet<_>>().len() != answer_ids.len()
    {
        return Err("A poll response needs 1 to 20 unique answer ids.".to_string());
    }
    Ok(())
}

/// Submit a vote on a poll. Replaces the current user's previous response on
/// the same poll start event.
#[frb]
pub async fn send_poll_response(
    room_id: String,
    poll_start_event_id: String,
    answer_ids: Vec<String>,
) -> Result<(), String> {
    use matrix_sdk::ruma::events::poll::unstable_response::UnstablePollResponseEventContent;

    validate_poll_answer_ids(&answer_ids)?;
    let event_id = matrix_sdk::ruma::EventId::parse(poll_start_event_id.as_str())
        .map_err(|e| format!("Invalid poll event id: {e}"))?;

    let content = UnstablePollResponseEventContent::new(answer_ids, event_id);

    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| format!("Send poll response failed: {e}"))?;

    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(())
}

/// Close a poll so no further votes are accepted.
#[frb]
pub async fn end_poll(room_id: String, poll_start_event_id: String) -> Result<(), String> {
    use matrix_sdk::ruma::events::poll::unstable_end::UnstablePollEndEventContent;

    let event_id = matrix_sdk::ruma::EventId::parse(poll_start_event_id.as_str())
        .map_err(|e| format!("Invalid poll event id: {e}"))?;

    let content = UnstablePollEndEventContent::new("结束投票", event_id);

    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| format!("End poll failed: {e}"))?;

    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(())
}

#[cfg(test)]
mod attachment_message_tests {
    use super::{
        file_message_content, image_mime_type, location_message_content, poll_start_content,
        poll_start_for_forward, room_message_preview, unstable_poll_preview,
        validate_poll_answer_ids, video_mime_type,
    };
    use matrix_sdk::ruma::{
        events::{
            poll::{
                unstable_response::UnstablePollResponseEventContent,
                unstable_start::UnstablePollStartEventContent,
            },
            room::{
                message::{AudioMessageEventContent, MessageType, RoomMessageEventContent},
                MediaSource,
            },
            StaticEventContent,
        },
        OwnedMxcUri, UInt,
    };

    fn mxc_uri() -> OwnedMxcUri {
        OwnedMxcUri::from("mxc://example.org/media")
    }

    #[test]
    fn media_mime_validation_is_case_insensitive_and_type_safe() {
        assert_eq!(
            image_mime_type("PHOTO.HEIC", None).unwrap().essence_str(),
            "image/heic"
        );
        assert!(image_mime_type("photo.jpg", Some("application/pdf".to_owned())).is_err());
        assert_eq!(
            video_mime_type("clip.MOV", None).unwrap().essence_str(),
            "video/quicktime"
        );
        assert_eq!(
            video_mime_type("clip.WebM", None).unwrap().essence_str(),
            "video/webm"
        );
        assert!(video_mime_type("clip.mp4", Some("image/jpeg".to_owned())).is_err());
    }

    #[test]
    fn file_content_stays_m_file_even_for_audio_mime() {
        let content = file_message_content(
            "track.mp3".to_owned(),
            &"audio/mpeg".parse().unwrap(),
            UInt::new(3),
            MediaSource::Plain(mxc_uri()),
        );
        let json = serde_json::to_value(content).unwrap();

        assert_eq!(json["msgtype"], "m.file");
        assert_eq!(json["body"], "track.mp3");
        assert_eq!(json["url"], "mxc://example.org/media");
        assert_eq!(json["info"]["mimetype"], "audio/mpeg");
        assert_eq!(json["info"]["size"], 3);
    }

    #[test]
    fn location_content_uses_legacy_wire_format_and_validates_ranges() {
        let content = location_message_content("Office", "geo:39.9,116.4").unwrap();
        let json = serde_json::to_value(content).unwrap();

        assert_eq!(json["msgtype"], "m.location");
        assert_eq!(json["body"], "Office");
        assert_eq!(json["geo_uri"], "geo:39.9,116.4");
        assert!(location_message_content("", "geo:91,0").is_err());
        assert!(location_message_content("", "geo:1e1,20").is_err());
        assert!(location_message_content("", "https://example.org").is_err());
    }

    #[test]
    fn poll_content_uses_unstable_wire_format_with_fallback() {
        let content = poll_start_content(
            " Lunch? ",
            vec![" Noodles ".to_owned(), String::new(), "Rice".to_owned()],
            true,
            2,
        )
        .unwrap();
        let json = serde_json::to_value(&content).unwrap();
        let poll = &json["org.matrix.msc3381.poll.start"];

        assert_eq!(
            <UnstablePollStartEventContent as StaticEventContent>::TYPE,
            "org.matrix.msc3381.poll.start"
        );
        assert_eq!(
            json["org.matrix.msc1767.text"],
            "Lunch?\n1. Noodles\n2. Rice"
        );
        assert_eq!(poll["question"]["org.matrix.msc1767.text"], "Lunch?");
        assert_eq!(poll["answers"].as_array().unwrap().len(), 2);
        assert_eq!(poll["answers"][0]["id"], "0");
        assert_eq!(poll["answers"][1]["id"], "1");
        assert_eq!(poll["max_selections"], 2);
        assert!(poll_start_content("", vec!["yes".to_owned()], false, 1).is_err());
        assert!(poll_start_content("Question", vec!["yes".to_owned()], false, 1).is_err());
        assert!(poll_start_content(
            "Question",
            vec!["yes".to_owned(), "no".to_owned()],
            false,
            0,
        )
        .is_err());
        assert!(poll_start_content(
            "Question",
            vec!["yes".to_owned(), "no".to_owned()],
            false,
            3,
        )
        .is_err());
    }

    #[test]
    fn previews_cover_audio_location_and_poll() {
        let audio = RoomMessageEventContent::new(MessageType::Audio(
            AudioMessageEventContent::plain("clip.mp3".to_owned(), mxc_uri()),
        ));
        let location = location_message_content("", "geo:39.9,116.4").unwrap();
        let poll = poll_start_content(
            "Lunch?",
            vec!["Rice".to_owned(), "Noodles".to_owned()],
            false,
            1,
        )
        .unwrap();

        assert_eq!(
            room_message_preview(&audio).as_deref(),
            Some("[音频] clip.mp3")
        );
        assert_eq!(
            room_message_preview(&location).as_deref(),
            Some("[位置] geo:39.9,116.4")
        );
        assert_eq!(
            unstable_poll_preview(&poll).as_deref(),
            Some("[投票] Lunch?")
        );
    }

    #[test]
    fn forwarded_poll_is_a_new_start_without_relation() {
        let poll = poll_start_content(
            "Lunch?",
            vec!["Rice".to_owned(), "Noodles".to_owned()],
            false,
            1,
        )
        .unwrap();
        let forwarded = poll_start_for_forward(&poll).unwrap();

        assert!(forwarded.relates_to.is_none());
        assert_eq!(forwarded.poll_start.question.text, "Lunch?");
    }

    #[test]
    fn poll_response_ids_must_be_nonempty_and_unique() {
        assert!(validate_poll_answer_ids(&["0".to_owned()]).is_ok());
        assert!(validate_poll_answer_ids(&[]).is_err());
        assert!(validate_poll_answer_ids(&["0".to_owned(), "0".to_owned()]).is_err());
        assert!(validate_poll_answer_ids(&[String::new()]).is_err());
    }

    #[test]
    fn poll_response_uses_the_poll_start_as_its_reference() {
        let event_id = matrix_sdk::ruma::EventId::parse("$poll:example.org").unwrap();
        let content =
            UnstablePollResponseEventContent::new(vec!["0".to_owned(), "1".to_owned()], event_id);
        let json = serde_json::to_value(content).unwrap();

        assert_eq!(
            json["org.matrix.msc3381.poll.response"]["answers"],
            serde_json::json!(["0", "1"]),
        );
        assert_eq!(json["m.relates_to"]["event_id"], "$poll:example.org");
        assert_eq!(json["m.relates_to"]["rel_type"], "m.reference");
    }
}

#[frb]
pub async fn send_sticker(
    room_id: String,
    image_url: String,
    body: String,
    mime_type: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;

    let room = client
        .get_room(
            &matrix_sdk::ruma::RoomId::parse(room_id.clone())
                .map_err(|e| format!("Invalid room id: {e}"))?,
        )
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let content_uri = matrix_sdk::ruma::OwnedMxcUri::try_from(image_url.trim())
        .map_err(|e| format!("Invalid sticker MXC URI: {e}"))?;

    let mut info = matrix_sdk::ruma::events::room::ImageInfo::new();
    if let Some(mime_type) = mime_type.filter(|value| !value.trim().is_empty()) {
        info.mimetype = Some(mime_type);
    }
    if let Some(width) = width.filter(|value| *value > 0) {
        info.width = matrix_sdk::ruma::UInt::new(width as u64);
    }
    if let Some(height) = height.filter(|value| *value > 0) {
        info.height = matrix_sdk::ruma::UInt::new(height as u64);
    }

    let label = body.trim();
    let content = matrix_sdk::ruma::events::sticker::StickerEventContent::new(
        if label.is_empty() {
            "贴纸".to_string()
        } else {
            label.to_string()
        },
        info,
        content_uri,
    );

    room.send(content)
        .await
        .map_err(|e| format!("Send sticker message failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Sticker message sent to {}", room_id),
    );
    info!("Sticker message sent to {}", room_id);
    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(())
}

/// Create a new direct chat room with a user.
#[frb]
pub async fn create_dm(user_id: String) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let invited_user =
        matrix_sdk::ruma::UserId::parse(&user_id).map_err(|e| format!("Invalid user ID: {e}"))?;

    for room in client.rooms() {
        if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
            continue;
        }

        if !matches!(room.is_direct().await, Ok(true)) {
            continue;
        }

        let members = match room.members(matrix_sdk::RoomMemberships::JOIN).await {
            Ok(members) => members,
            Err(_) => continue,
        };

        if members
            .iter()
            .any(|member| member.user_id() == invited_user)
        {
            app_log(
                "info",
                "rooms",
                format!(
                    "Reusing existing DM room {} for {}",
                    room.room_id(),
                    user_id
                ),
            );
            return Ok(room.room_id().to_string());
        }
    }

    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.invite = vec![invited_user];
    request.is_direct = true;

    let response = client
        .create_room(request)
        .await
        .map_err(|e| format!("Create room failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Created DM room: {}", response.room_id()),
    );
    info!("Created DM room: {}", response.room_id());
    Ok(response.room_id().to_string())
}

/// Create a group room with a name and optional topic.
#[frb]
pub async fn create_group_room(name: String, topic: Option<String>) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.name = Some(name);
    request.topic = topic;

    let response = client
        .create_room(request)
        .await
        .map_err(|e| format!("Create room failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Created group room: {}", response.room_id()),
    );
    info!("Created group room: {}", response.room_id());
    Ok(response.room_id().to_string())
}

/// Create a space room with a name and optional topic.
#[frb]
pub async fn create_space(name: String, topic: Option<String>) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.name = Some(name);
    request.topic = topic;
    let mut creation_content =
        matrix_sdk::ruma::api::client::room::create_room::v3::CreationContent::default();
    creation_content.room_type = Some(matrix_sdk::ruma::room::RoomType::Space);
    request.creation_content = Some(
        matrix_sdk::ruma::serde::Raw::new(&creation_content)
            .map_err(|e| format!("Failed to encode space creation content: {e}"))?,
    );

    let response = client
        .create_room(request)
        .await
        .map_err(|e| format!("Create space failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Created space: {}", response.room_id()),
    );
    info!("Created space: {}", response.room_id());
    Ok(response.room_id().to_string())
}

/// Join a room or space by room ID or alias.
#[frb]
pub async fn join_room(identifier: String) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let id_or_alias = matrix_sdk::ruma::RoomOrAliasId::parse(identifier.clone())
        .map_err(|e| format!("Invalid room or space identifier: {e}"))?;

    let room = client
        .join_room_by_id_or_alias(&id_or_alias, &[])
        .await
        .map_err(|e| format!("Join failed: {e}"))?;

    app_log("info", "rooms", format!("Joined room: {}", room.room_id()));
    info!("Joined room: {}", room.room_id());
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(room.room_id().to_string())
}

#[frb]
pub async fn accept_room_invite(room_id: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Invited {
        return Err(format!("Room is not an invite: {room_id}"));
    }
    room.join()
        .await
        .map_err(|e| format!("Accept invite failed: {e}"))?;
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn reject_room_invite(room_id: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Invited {
        return Err(format!("Room is not an invite: {room_id}"));
    }
    room.leave()
        .await
        .map_err(|e| format!("Reject invite failed: {e}"))?;
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn withdraw_room_knock(room_id: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Knocked {
        return Err(format!("Room is not a knock request: {room_id}"));
    }
    room.leave()
        .await
        .map_err(|e| format!("Withdraw knock failed: {e}"))?;
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn get_spaces() -> Result<Vec<Space>, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let mut spaces = Vec::new();
    for room in client.rooms() {
        if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
            continue;
        }
        let chat_room = room_to_chat_room(&room).await;
        spaces.push(Space {
            id: chat_room.id,
            name: chat_room.name,
            avatar_url: chat_room.avatar_url,
        });
    }

    spaces.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    Ok(spaces)
}

#[frb]
pub async fn get_space_details(space_id: String) -> Result<SpaceDetails, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| format!("Invalid space id: {e}"))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| format!("Space not found: {space_id}"))?;

    if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
        return Err(format!("Room is not a joined space: {space_id}"));
    }

    let chat_room = room_to_chat_room(&room).await;
    let topic = room
        .topic()
        .map(|topic| topic.trim().to_string())
        .filter(|topic| !topic.is_empty());

    Ok(SpaceDetails {
        id: chat_room.id,
        name: chat_room.name,
        avatar_url: chat_room.avatar_url,
        topic,
    })
}

#[frb]
pub async fn get_space_children(space_id: String) -> Result<Vec<ChatRoom>, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let space_room = client
        .get_room(
            &matrix_sdk::ruma::RoomId::parse(space_id.clone())
                .map_err(|e| format!("Invalid space id: {e}"))?,
        )
        .ok_or_else(|| format!("Space not found: {space_id}"))?;

    let child_events = space_room
        .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
        .await
        .map_err(|e| format!("Failed to load space children: {e}"))?;

    let mut child_rooms = Vec::new();
    for raw_child in child_events {
        let Ok(child_event) = raw_child.deserialize() else {
            continue;
        };
        let child_room_id = match child_event {
            matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
                matrix_sdk::ruma::events::SyncStateEvent::Original(event),
            ) => event.state_key,
            matrix_sdk::deserialized_responses::SyncOrStrippedState::Stripped(event) => {
                event.state_key
            }
            _ => continue,
        };

        let Some(child_room) = client.get_room(&child_room_id) else {
            continue;
        };
        if child_room.state() != matrix_sdk::RoomState::Joined {
            continue;
        }

        let mut chat_room = room_to_chat_room(&child_room).await;
        if !child_room.is_space() {
            chat_room.room_type = match child_room.is_direct().await {
                Ok(true) => "dm".to_string(),
                _ => "group".to_string(),
            };
        }
        child_rooms.push(chat_room);
    }

    child_rooms.sort_by(|a, b| {
        let a_time = a.last_message_time.parse::<u64>().unwrap_or_default();
        let b_time = b.last_message_time.parse::<u64>().unwrap_or_default();
        b_time
            .cmp(&a_time)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(child_rooms)
}

#[frb]
pub async fn update_space_details(
    space_id: String,
    name: String,
    topic: Option<String>,
) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| format!("Invalid space id: {e}"))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| format!("Space not found: {space_id}"))?;

    if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
        return Err(format!("Room is not a joined space: {space_id}"));
    }

    let trimmed_name = name.trim();
    if trimmed_name.is_empty() {
        return Err("Space name cannot be empty.".to_string());
    }

    room.set_name(trimmed_name.to_string())
        .await
        .map_err(|e| format!("Failed to update space name: {e}"))?;

    let normalized_topic = topic.unwrap_or_default().trim().to_string();
    room.set_room_topic(&normalized_topic)
        .await
        .map_err(|e| format!("Failed to update space topic: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Updated space details: {}", space_id),
    );
    info!("Updated space details: {}", space_id);
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

/// Add a room to a space, and advertise the reciprocal parent relation.
#[frb]
pub async fn add_room_to_space(space_id: String, room_id: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| format!("Invalid space id: {e}"))?;
    let child_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| format!("Invalid room id: {e}"))?;

    let space_room = client
        .get_room(&space_room_id)
        .ok_or_else(|| format!("Space not found: {space_id}"))?;
    let child_room = client
        .get_room(&child_room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let via = vec![client
        .user_id()
        .ok_or("No active user.")?
        .server_name()
        .to_owned()];

    space_room
        .send_state_event_for_key(
            &child_room_id,
            matrix_sdk::ruma::events::space::child::SpaceChildEventContent::new(via.clone()),
        )
        .await
        .map_err(|e| format!("Failed to add room to space: {e}"))?;

    child_room
        .send_state_event_for_key(
            &space_room_id,
            matrix_sdk::ruma::events::space::parent::SpaceParentEventContent::new(via),
        )
        .await
        .map_err(|e| format!("Failed to set parent space on room: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Added room {} to space {}", room_id, space_id),
    );
    info!("Added room {} to space {}", room_id, space_id);
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn remove_room_from_space(space_id: String, room_id: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| format!("Invalid space id: {e}"))?;
    let child_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| format!("Invalid room id: {e}"))?;

    let space_room = client
        .get_room(&space_room_id)
        .ok_or_else(|| format!("Space not found: {space_id}"))?;
    let child_room = client
        .get_room(&child_room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let child_events = space_room
        .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
        .await
        .map_err(|e| format!("Failed to load space children: {e}"))?;
    let space_child_event_id = child_events.into_iter().find_map(|raw_child| {
        let Ok(child_event) = raw_child.deserialize() else {
            return None;
        };
        match child_event {
            matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
                matrix_sdk::ruma::events::SyncStateEvent::Original(event),
            ) if event.state_key == child_room_id => Some(event.event_id),
            _ => None,
        }
    });

    let parent_events = child_room
        .get_state_events_static::<matrix_sdk::ruma::events::space::parent::SpaceParentEventContent>()
        .await
        .map_err(|e| format!("Failed to load room parents: {e}"))?;
    let space_parent_event_id = parent_events.into_iter().find_map(|raw_parent| {
        let Ok(parent_event) = raw_parent.deserialize() else {
            return None;
        };
        match parent_event {
            matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
                matrix_sdk::ruma::events::SyncStateEvent::Original(event),
            ) if event.state_key == space_room_id => Some(event.event_id),
            _ => None,
        }
    });

    if let Some(event_id) = space_child_event_id {
        space_room
            .redact(&event_id, Some("Removed from space"), None)
            .await
            .map_err(|e| format!("Failed to remove room from space: {e}"))?;
    }

    if let Some(event_id) = space_parent_event_id {
        child_room
            .redact(&event_id, Some("Removed parent space"), None)
            .await
            .map_err(|e| format!("Failed to remove parent space on room: {e}"))?;
    }

    app_log(
        "info",
        "rooms",
        format!("Removed room {} from space {}", room_id, space_id),
    );
    info!("Removed room {} from space {}", room_id, space_id);
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn leave_space(space_id: String) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| format!("Invalid space id: {e}"))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| format!("Space not found: {space_id}"))?;

    if !room.is_space() {
        return Err(format!("Room is not a space: {space_id}"));
    }

    room.leave()
        .await
        .map_err(|e| format!("Failed to leave space: {e}"))?;

    app_log("info", "rooms", format!("Left space: {}", space_id));
    info!("Left space: {}", space_id);
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn get_ungrouped_rooms() -> Result<Vec<ChatRoom>, String> {
    let client = get_client().await.ok_or("No client created.")?;

    let mut grouped_room_ids = std::collections::HashSet::new();
    for room in client.rooms() {
        if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
            continue;
        }

        let child_events = room
            .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
            .await
            .map_err(|e| format!("Failed to load space children: {e}"))?;

        for raw_child in child_events {
            let Ok(child_event) = raw_child.deserialize() else {
                continue;
            };
            let child_room_id = match child_event {
                matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
                    matrix_sdk::ruma::events::SyncStateEvent::Original(event),
                ) => event.state_key,
                matrix_sdk::deserialized_responses::SyncOrStrippedState::Stripped(event) => {
                    event.state_key
                }
                _ => continue,
            };
            grouped_room_ids.insert(child_room_id);
        }
    }

    let mut rooms = Vec::new();
    for room in client.rooms() {
        if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
            continue;
        }

        if matches!(room.is_direct().await, Ok(true)) {
            continue;
        }

        if grouped_room_ids.contains(room.room_id()) {
            continue;
        }

        let mut chat_room = room_to_chat_room(&room).await;
        chat_room.room_type = "group".to_string();
        rooms.push(chat_room);
    }

    rooms.sort_by(|a, b| {
        let a_time = a.last_message_time.parse::<u64>().unwrap_or_default();
        let b_time = b.last_message_time.parse::<u64>().unwrap_or_default();
        b_time
            .cmp(&a_time)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(rooms)
}

#[frb]
pub async fn get_contacts() -> Result<Vec<Contact>, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let my_user_id = client.user_id().map(|user_id| user_id.to_string());
    let mut contacts_by_id: HashMap<String, Contact> = HashMap::new();

    for room in client.rooms() {
        if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
            continue;
        }

        let members = room
            .members(matrix_sdk::RoomMemberships::JOIN)
            .await
            .map_err(|e| format!("Failed to get contacts from room {}: {e}", room.room_id()))?;

        for member in members {
            let user_id = member.user_id().to_string();
            if my_user_id.as_deref() == Some(user_id.as_str()) {
                continue;
            }

            let name = member.name().to_string();
            let avatar_url = member.avatar_url().map(|u| u.to_string());
            let contact = contacts_by_id
                .entry(user_id.clone())
                .or_insert_with(|| Contact {
                    id: user_id.clone(),
                    name: if name == user_id {
                        user_id.clone()
                    } else {
                        name.clone()
                    },
                    avatar_url: avatar_url.clone(),
                    status: user_id.clone(),
                });

            if contact.name == contact.id && name != user_id {
                contact.name = name;
            }
            if contact.avatar_url.is_none() && avatar_url.is_some() {
                contact.avatar_url = avatar_url;
            }
        }
    }

    let mut contacts: Vec<Contact> = contacts_by_id.into_values().collect();
    contacts.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.id.cmp(&b.id))
    });

    app_log(
        "info",
        "contacts",
        format!("get_contacts: {} unique contacts", contacts.len()),
    );
    Ok(contacts)
}

/// Send a reply to a specific message in a room.
#[frb]
pub async fn send_reply(
    room_id: String,
    message: FormattedMessageInput,
    reply_to_event_id: String,
    reply_to_user_id: Option<String>,
) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    // Parse the event ID we're replying to
    let event_id = matrix_sdk::ruma::EventId::parse(&reply_to_event_id)
        .map_err(|e| format!("Invalid event ID: {e}"))?;

    let mut reply_content = build_text_content(message)?;
    if let Some(reply_to_user_id) = reply_to_user_id {
        let reply_to_user_id = matrix_sdk::ruma::UserId::parse(&reply_to_user_id)
            .map_err(|e| format!("Invalid reply user ID: {e}"))?;
        reply_content
            .mentions
            .get_or_insert_with(matrix_sdk::ruma::events::Mentions::new)
            .user_ids
            .insert(reply_to_user_id);
    }
    reply_content.relates_to = Some(matrix_sdk::ruma::events::room::message::Relation::Reply(
        matrix_sdk::ruma::events::relation::Reply::with_event_id(event_id),
    ));

    let response = room
        .send(reply_content)
        .await
        .map_err(|e| format!("Reply failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Reply sent to {} in room {}", reply_to_event_id, room_id),
    );
    info!("Reply sent to {} in room {}", reply_to_event_id, room_id);
    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(response.response.event_id.to_string())
}

/// Edit (replace) one of your own messages.
///
/// Sends an `m.room.message` event whose `m.new_content` carries the new text
/// and whose `m.relates_to` is an `m.replace` pointing at the original event.
/// Tuwunel relays edits (MSC2676); the displayed edit history is aggregated
/// client-side by `get_messages` (see `Relation::Replacement` parsing).
#[frb]
pub async fn edit_message(
    room_id: String,
    event_id: String,
    message: FormattedMessageInput,
    previous_mentioned_user_ids: Vec<String>,
    previous_mentions_room: bool,
) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| format!("Invalid event ID: {e}"))?;

    use matrix_sdk::ruma::events::room::message::ReplacementMetadata;
    let previous_mentions = build_mentions(&previous_mentioned_user_ids, previous_mentions_room)?;
    let content = build_text_content(message)?.make_replacement(ReplacementMetadata::new(
        parsed_event_id,
        Some(previous_mentions),
    ));

    let response = room
        .send(content)
        .await
        .map_err(|e| format!("Edit failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Edited event {} in room {}", event_id, room_id),
    );
    info!("Edited event {} in room {}", event_id, room_id);
    notify_sync_event(SyncEvent::MessageSent {
        room_id: room_id.clone(),
    });
    Ok(response.response.event_id.to_string())
}

/// Send an emoji reaction (m.annotation) to an event.
///
/// Re-sending the same key is de-duplicated server-side per MSC2677. To remove
/// a reaction, redact the reaction event (not implemented in this client yet).
#[frb]
pub async fn send_reaction(
    room_id: String,
    event_id: String,
    key: String,
) -> Result<String, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| format!("Invalid event ID: {e}"))?;

    use matrix_sdk::ruma::events::relation::Annotation;
    let content = matrix_sdk::ruma::events::reaction::ReactionEventContent::from(Annotation::new(
        parsed_event_id,
        key.clone(),
    ));

    let handle = room
        .send(content)
        .await
        .map_err(|e| format!("Reaction failed: {e}"))?;
    let new_event_id = handle.response.event_id.to_string();

    app_log(
        "info",
        "rooms",
        format!("Reaction '{}' on {} in room {}", key, event_id, room_id),
    );
    info!("Reaction '{}' on {} in room {}", key, event_id, room_id);
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(new_event_id)
}

/// Redact (delete) a message from a room.
#[frb]
pub async fn redact_message(
    room_id: String,
    event_id: String,
    reason: Option<String>,
) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| format!("Invalid event ID: {e}"))?;

    room.redact(&parsed_event_id, reason.as_deref(), None)
        .await
        .map_err(|e| format!("Redact failed: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!("Redacted event {} in room {}", event_id, room_id),
    );
    info!("Redacted event {} in room {}", event_id, room_id);
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

/// Send a typing notice to a room.
#[frb]
pub async fn send_typing_notice(room_id: String, typing: bool) -> Result<(), String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    room.typing_notice(typing)
        .await
        .map_err(|e| format!("Typing notice failed: {e}"))?;
    Ok(())
}

/// Get members of a room.
#[frb]
pub async fn get_room_members(room_id: String) -> Result<Vec<Contact>, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;

    let members = room
        .members(matrix_sdk::RoomMemberships::JOIN)
        .await
        .map_err(|e| format!("Failed to get members: {e}"))?;

    app_log(
        "info",
        "rooms",
        format!(
            "get_room_members: {} members in room {}",
            members.len(),
            room_id
        ),
    );

    let mut contacts = Vec::new();
    for member in members {
        let name = member.name().to_string();
        let user_id = member.user_id().to_string();
        let avatar = member.avatar_url().map(|u| u.to_string());
        contacts.push(Contact {
            id: user_id.clone(),
            name: if name == user_id {
                user_id.clone()
            } else {
                name
            },
            status: user_id,
            avatar_url: avatar,
        });
    }
    Ok(contacts)
}

/// Get the avatar URL for a room.
#[frb]
pub async fn get_room_avatar_url(room_id: String) -> Option<String> {
    let client = get_client().await?;
    let room = get_room_by_id(&client, &room_id).ok()?;
    room.avatar_url().map(|u| u.to_string())
}

/// Search rooms by name.
#[frb]
pub async fn search_rooms(query: String) -> Result<Vec<ChatRoom>, String> {
    let all = get_chat_rooms().await?;
    let q = query.to_lowercase();
    let filtered: Vec<ChatRoom> = all
        .into_iter()
        .filter(|r| r.name.to_lowercase().contains(&q))
        .collect();
    Ok(filtered)
}

/// Load more messages (paginated) from before a given event.
#[frb]
pub async fn get_messages_before(
    room_id: String,
    from_event_id: String,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let client = get_client().await.ok_or("No client created.")?;
    let room = get_room_by_id(&client, &room_id)?;
    sdk_timeline::get_messages_before(&client, &room, &from_event_id, limit).await
}

#[cfg(test)]
mod media_download_tests {
    use super::{
        append_media_chunk, ensure_media_content_length, media_download_limit, media_download_url,
    };
    use matrix_sdk::Client;

    #[test]
    fn media_download_limit_rejects_non_positive_values() {
        assert!(media_download_limit(0).is_err());
        assert!(media_download_limit(-1).is_err());
        assert_eq!(media_download_limit(1024), Ok(1024));
    }

    #[test]
    fn media_download_refuses_oversized_headers_and_streams() {
        assert!(ensure_media_content_length(Some(9), 8).is_err());
        assert!(ensure_media_content_length(None, 8).is_ok());

        let mut content = vec![1, 2, 3];
        assert!(append_media_chunk(&mut content, &[4, 5], 4).is_err());
        assert_eq!(content, [1, 2, 3]);
        assert!(append_media_chunk(&mut content, &[4], 4).is_ok());
        assert_eq!(content, [1, 2, 3, 4]);
    }

    #[tokio::test]
    async fn media_download_url_uses_the_homeserver_and_mxc_port() {
        let client = Client::new(url::Url::parse("https://matrix.example/").unwrap())
            .await
            .unwrap();
        let source =
            serde_json::from_str(r#"{"url":"mxc://media.example:8448/media-id"}"#).unwrap();

        let url = media_download_url(&client, &source).unwrap();

        assert_eq!(
            url.as_str(),
            "https://matrix.example/_matrix/client/v1/media/download/media.example:8448/media-id"
        );
    }
}
