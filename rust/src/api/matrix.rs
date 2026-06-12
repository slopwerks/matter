use flutter_rust_bridge::frb;
use log::{info, warn};
use matrix_sdk::{
    Client, SessionMeta, SessionTokens,
    authentication::matrix::MatrixSession,
    encryption::{
        VerificationState as OwnVerificationState,
        recovery::RecoveryState,
        verification::{Verification, VerificationRequestState},
    },
    ruma::api::client::{
        account::register::v3::Request as RegistrationRequest,
        uiaa::{AuthData, Dummy, RegistrationToken, UiaaInfo},
    },
    ruma::events::key::verification::{
        VerificationMethod,
        request::ToDeviceKeyVerificationRequestEvent,
    },
    store::RoomLoadSettings,
};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};
use tokio::task::JoinHandle;
use std::time::SystemTime;

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
    Lazy::new(|| tokio::sync::broadcast::channel(2000).0);

/// Ring buffer that keeps the last 500 log entries so late-joining
/// subscribers (Dart) can retrieve them via `get_recent_logs()`.
static LOG_RING: Lazy<std::sync::Mutex<Vec<AppLogEntry>>> =
    Lazy::new(|| std::sync::Mutex::new(Vec::new()));
const LOG_RING_CAP: usize = 500;

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
    // Push to ring buffer (for get_recent_logs)
    if let Ok(mut ring) = LOG_RING.lock() {
        if ring.len() >= LOG_RING_CAP {
            ring.remove(0);
        }
        ring.push(entry);
    }
}

/// Stream app log entries from Rust → Dart (live).
#[frb]
pub fn watch_app_logs(sink: crate::frb_generated::StreamSink<AppLogEntry>) {
    let mut rx = APP_LOG_TX.subscribe();
    std::thread::spawn(move || {
        while let Ok(entry) = rx.blocking_recv() {
            if sink.add(entry).is_err() {
                break;
            }
        }
    });
}

/// Retrieve all buffered logs (up to 500 entries).
/// Call this once after connecting the stream to show historical logs.
#[frb(sync)]
pub fn get_recent_logs() -> Vec<AppLogEntry> {
    if let Ok(ring) = LOG_RING.lock() {
        ring.clone()
    } else {
        vec![]
    }
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

static SYNC_EVENT_TX: Lazy<tokio::sync::broadcast::Sender<SyncEvent>> =
    Lazy::new(|| {
        let (tx, _rx) = tokio::sync::broadcast::channel(64);
        tx
    });

fn notify_sync_event(event: SyncEvent) {
    let _ = SYNC_EVENT_TX.send(event);
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
static ACTIVE_USER: Lazy<Arc<RwLock<Option<String>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

struct SyncTask {
    user_id: String,
    handle: JoinHandle<()>,
}

/// Exactly one account owns the app-wide background sync task at a time.
static SYNC_TASK: Lazy<Mutex<Option<SyncTask>>> = Lazy::new(|| Mutex::new(None));

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
    }
}

/// Temporary client during login (before we know the user_id for a per-user dir).
static PENDING: Lazy<Arc<RwLock<Option<PendingEntry>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

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
        (p.client.clone(), p.data_dir.clone(), p.homeserver_url.clone())
    };

    let auth = pending_client.matrix_auth();
    if !auth.logged_in() {
        return Err("Pending client is not logged in".into());
    }
    let session = auth
        .session()
        .ok_or("No session in pending client")?;
    let user_id = session.meta.user_id.to_string();

    app_log("info", "auth", format!("finalize_pending: starting for user {}", user_id));
    info!("finalize_pending: starting for user {}", user_id);

    // Build per-user directory
    let sdk_dir = build_sdk_data_dir(&data_dir, Some(&user_id));

    // A password/token login creates a fresh Matrix device. An existing SDK
    // store for the same user may still be bound to the previous device ID,
    // which matrix-sdk correctly rejects as a crypto-account mismatch.
    // Drop the old client and rebuild its store for the new device.
    stop_sync_task(Some(&user_id)).await;
    {
        let mut clients = CLIENTS.write().await;
        clients.remove(&user_id);
    }
    if sdk_dir.exists() {
        app_log(
            "info",
            "auth",
            format!("Rebuilding SDK store for newly logged-in device: {}", user_id),
        );
        std::fs::remove_dir_all(&sdk_dir)
            .map_err(|e| format!("Failed to reset existing account store: {e}"))?;
    }

    // Create a new client in the per-user directory
    let url = url::Url::parse(&homeserver_url)
        .map_err(|e| format!("Invalid URL: {e}"))?;
    app_log("info", "auth", format!("finalize_pending: creating client in {}", sdk_dir.display()));
    info!("finalize_pending: creating client in {}", sdk_dir.display());
    let new_client = Client::builder()
        .homeserver_url(url)
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
        .map_err(|e| format!("Failed to create per-user client: {e}"))?;

    // Restore the session into the new client
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

    app_log("info", "auth", format!("finalize_pending: restoring session for {}", user_id));
    info!("finalize_pending: restoring session for {}", user_id);
    new_client
        .matrix_auth()
        .restore_session(matrix_session, RoomLoadSettings::default())
        .await
        .map_err(|e| format!("Restore session in per-user store: {e}"))?;
    app_log("info", "auth", format!("finalize_pending: session restored for {}", user_id));
    info!("finalize_pending: session restored for {}", user_id);
    install_verification_event_handler(&new_client);

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

    // Clear pending — this drops our last reference to the pending client,
    // which will close its SQLite connection when it's dropped.
    {
        let mut pending = PENDING.write().await;
        *pending = None;
    }

    // Drop our local reference to the pending client so SQLite can close.
    drop(pending_client);

    // Now safe to clean up the temp directory (SQLite file is closed).
    // Give a small grace period for the OS to release file handles.
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let temp_dir = build_sdk_data_dir(&data_dir, None);
    if temp_dir.exists() {
        app_log("info", "auth", format!("Cleaning up pending dir: {}", temp_dir.display()));
        info!("Cleaning up pending dir: {}", temp_dir.display());
        if let Err(e) = std::fs::remove_dir_all(&temp_dir) {
            warn!("Failed to delete pending dir: {e}");
        }
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
    pub last_message_time: String,
    pub unread_count: i32,
    pub is_pinned: bool,
    pub is_muted: bool,
    /// "dm", "group", or "space"
    pub room_type: String,
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
pub struct Contact {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
    pub status: String,
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
    /// State/member change event (join, leave, etc.)
    Event,
}

#[frb]
#[derive(Clone, Debug)]
pub struct ChatMessage {
    pub id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub content: String,
    pub timestamp: String,
    pub is_me: bool,
    pub msg_type: MessageType,
    pub image_url: Option<String>,
    /// Event ID this message is replying to, if any.
    pub in_reply_to: Option<String>,
    /// Whether this message has been edited.
    pub is_edited: bool,
    /// History of edits (previous versions), oldest first.
    pub edit_history: Vec<String>,
}

/// Result of a registration or login attempt
#[frb]
#[derive(Clone, Debug)]
pub struct AuthResult {
    pub success: bool,
    pub user_id: Option<String>,
    pub device_id: Option<String>,
    pub access_token: Option<String>,
    pub error: Option<String>,
    /// If true, UIAA is needed — caller should call register_account again with token + session
    pub needs_uiaa: bool,
    pub session: Option<String>,
    /// Available UIAA flows (JSON)
    pub flows: Option<String>,
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
        error: None,
        needs_uiaa: true,
        session,
        flows: flows_json,
    }
}

// ── Auth functions ───────────────────────────────────────────────────

/// Create a Matrix client for the given homeserver URL.
/// Must be called before any registration / login attempt.
/// The client is stored as "pending" until a login succeeds,
/// after which it is automatically migrated to a per-user store.
#[frb]
pub async fn create_client(homeserver_url: String, data_dir: String) -> Result<(), String> {
    app_log("info", "auth", format!("create_client: homeserver={}", homeserver_url));
    let url = url::Url::parse(&homeserver_url).map_err(|e| {
        let msg = format!("Invalid URL: {e}");
        app_log("error", "auth", msg.clone());
        msg
    })?;
    let sdk_dir = build_sdk_data_dir(&data_dir, None);

    // Clean up any stale pending directory
    if sdk_dir.exists() {
        info!("Removing stale pending dir: {}", sdk_dir.display());
        if let Err(e) = std::fs::remove_dir_all(&sdk_dir) {
            warn!("Failed to clean pending dir: {e}");
        }
    }

    let client = Client::builder()
        .homeserver_url(url)
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
        .map_err(|e| {
            let msg = format!("Failed to create client: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;

    app_log("info", "auth", format!("Client created for {}", homeserver_url));

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
    app_log("info", "auth", format!("register_get_uiaa_session: user={}", username));
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    let mut request = RegistrationRequest::new();
    request.username = Some(username);
    request.password = Some(password);
    request.initial_device_display_name = Some("Matter".to_owned());
    request.auth = Some(AuthData::Dummy(Dummy::new()));

    match client.matrix_auth().register(request).await {
        Ok(response) => Ok(AuthResult {
            success: true,
            user_id: Some(response.user_id.to_string()),
            device_id: response.device_id.map(|d| d.to_string()),
            access_token: response.access_token,
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
                error: Some(err_str),
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
    app_log("info", "auth", format!("register_complete_uiaa: user={}", username));
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    let mut request = RegistrationRequest::new();
    request.username = Some(username);
    request.password = Some(password);
    request.initial_device_display_name = Some("Matter".to_owned());

    let mut reg_token = RegistrationToken::new(registration_token);
    reg_token.session = Some(session);
    request.auth = Some(AuthData::RegistrationToken(reg_token));

    match client.matrix_auth().register(request).await {
        Ok(response) => {
            // Auto-finalize: migrate pending client to per-user store
            let finalized = finalize_pending().await.map_err(|e| format!("Finalization failed: {e}"))?;
            info!("Account finalized after registration: {}", finalized);
            Ok(AuthResult {
                success: true,
                user_id: Some(response.user_id.to_string()),
                device_id: response.device_id.map(|d| d.to_string()),
                access_token: response.access_token,
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
                error: Some(err_str),
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
    }
}

/// Login with username and password.
#[frb]
pub async fn login_with_password(
    username: String,
    password: String,
) -> Result<AuthResult, String> {
    app_log("info", "auth", format!("login_with_password: user={}", username));
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    match client
        .matrix_auth()
        .login_username(&username, &password)
        .initial_device_display_name("Matter")
        .await
    {
        Ok(response) => {
            // Auto-finalize: migrate pending client to per-user store
            let finalized = finalize_pending().await.map_err(|e| format!("Finalization failed: {e}"))?;
            app_log("info", "auth", format!("Account finalized after password login: {}", finalized));
            info!("Account finalized after password login: {}", finalized);
            Ok(AuthResult {
                success: true,
                user_id: Some(response.user_id.to_string()),
                device_id: Some(response.device_id.to_string()),
                access_token: Some(response.access_token),
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
            error: Some(format!("{e}")),
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
) -> Result<AuthResult, String> {
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    let parsed_user_id = matrix_sdk::ruma::UserId::parse(&user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;
    let parsed_device_id = matrix_sdk::ruma::OwnedDeviceId::from(device_id);

    let session = MatrixSession {
        meta: SessionMeta {
            user_id: parsed_user_id,
            device_id: parsed_device_id,
        },
        tokens: SessionTokens {
            access_token,
            refresh_token: None,
        },
    };

    client
        .matrix_auth()
        .restore_session(session, RoomLoadSettings::default())
        .await
        .map_err(|e| format!("Restore session failed: {e}"))?;

    // Auto-finalize: migrate pending client to per-user store
    match finalize_pending().await {
        Ok(_) => {
            app_log("info", "auth", "Account finalized after token login".to_string());
            info!("Account finalized after token login");
        }
        Err(e) => {
            app_log("warn", "auth", format!("Finalization failed after token login: {e}"));
            warn!("Finalization failed after token login: {e}");
            // For token login, we keep the pending client as a fallback
            // since the account is already logged in.
        }
    }

    // Try to get the user_id from the finalized client first,
    // fallback to the pending client (if finalization failed)
    let final_client = get_client().await;
    let final_user_id = final_client.as_ref().and_then(|c| c.user_id().map(|u| u.to_string()));

    Ok(AuthResult {
        success: true,
        user_id: final_user_id.or_else(|| Some(user_id)),
        device_id: get_client()
            .await
            .and_then(|c| c.device_id().map(|d| d.to_string())),
        access_token: None,
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
        app_log("info", "auth", format!("Switched to account: {}", user_id));
        info!("Switched to account: {}", user_id);
        true
    } else {
        app_log("warn", "auth", format!("switch_account: account {} not found", user_id));
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

    let entry = {
        let mut clients = CLIENTS.write().await;
        clients.remove(&user_id)
    };

    if let Some(entry) = entry {
        if entry.client.matrix_auth().logged_in() {
            entry
                .client
                .matrix_auth()
                .logout()
                .await
                .map_err(|e| format!("Logout failed: {e}"))?;
        }
        // Delete the per-user SDK data directory
        let sdk_dir = build_sdk_data_dir(&entry.data_dir, Some(&user_id));
        if sdk_dir.exists() {
            app_log("info", "auth", format!("Deleting SDK store for {}: {}", user_id, sdk_dir.display()));
            info!("Deleting SDK store for {}: {}", user_id, sdk_dir.display());
            if let Err(e) = std::fs::remove_dir_all(&sdk_dir) {
                warn!("Failed to delete SDK store: {e}");
            }
        }
    }

    // Update active user to another available account, or None
    let clients = CLIENTS.write().await;
    let mut active = ACTIVE_USER.write().await;
    if let Some((next_id, _)) = clients.iter().next() {
        *active = Some(next_id.clone());
        app_log("info", "auth", format!("Switched active account to: {}", next_id));
        info!("Switched active account to: {}", next_id);
    } else {
        *active = None;
        app_log("info", "auth", "No more accounts, active cleared".to_string());
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
    }
    stop_sync_task(Some(&user_id)).await;
    let entry = {
        let mut clients = CLIENTS.write().await;
        clients.remove(&user_id).ok_or("Account not found")?
    };

    if entry.client.matrix_auth().logged_in() {
        let _ = entry.client.matrix_auth().logout().await;
    }

    // Delete the per-user SDK data directory
    let sdk_dir = build_sdk_data_dir(&entry.data_dir, Some(&user_id));
    if sdk_dir.exists() {
        app_log("info", "auth", format!("Deleting SDK store for {}: {}", user_id, sdk_dir.display()));
        info!("Deleting SDK store for {}: {}", user_id, sdk_dir.display());
        if let Err(e) = std::fs::remove_dir_all(&sdk_dir) {
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
        user_id: session.meta.user_id.to_string(),
        device_id: session.meta.device_id.to_string(),
    })
}

/// Restore a previously saved session (used on app startup).
/// Uses a per-user store directory so multiple accounts coexist.
#[frb]
pub async fn restore_session(session: StoredSession, data_dir: String) -> Result<(), String> {
    app_log("info", "auth", format!("restore_session: user={}, homeserver={}", session.user_id, session.homeserver_url));
    let url = url::Url::parse(&session.homeserver_url)
        .map_err(|e| {
            let msg = format!("Invalid URL: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;
    let sdk_dir = build_sdk_data_dir(&data_dir, Some(&session.user_id));

    app_log("info", "auth", format!("restore_session: SDK dir = {}", sdk_dir.display()));

    let client = Client::builder()
        .homeserver_url(url)
        .sqlite_store(&sdk_dir, None)
        .build()
        .await
        .map_err(|e| {
            let msg = format!("Client build failed: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;

    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| {
            let msg = format!("Invalid user ID: {e}");
            app_log("error", "auth", msg.clone());
            msg
        })?;
    let device_id = matrix_sdk::ruma::OwnedDeviceId::from(session.device_id);

    let matrix_session = MatrixSession {
        meta: SessionMeta {
            user_id,
            device_id,
        },
        tokens: SessionTokens {
            access_token: session.access_token,
            refresh_token: None,
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
    install_verification_event_handler(&client);

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

    app_log("info", "auth", format!("Session restored for {}", session.user_id));
    Ok(())
}

// ── Device verification & encryption recovery ─────────────────────

fn active_session_meta(client: &Client) -> Result<(String, String), String> {
    let session = client.matrix_auth().session().ok_or("No active Matrix session")?;
    Ok((session.meta.user_id.to_string(), session.meta.device_id.to_string()))
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
    if active.as_ref().is_some_and(|session| session.flow_id == flow_id) {
        *active = None;
    }
}

#[frb]
pub async fn list_own_devices() -> Result<Vec<VerificationDevice>, String> {
    let client = get_client().await.ok_or("No active client")?;
    let (user_id, current_device_id) = active_session_meta(&client)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;

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
    let user_id = matrix_sdk::ruma::UserId::parse(user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;
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
        if session.accepted && !sas.can_be_presented() && !sas.is_done() && sas.cancel_info().is_none() {
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
        Some(VerificationRequestState::Ready { .. }) => {
            ("starting", "Starting emoji verification")
        }
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
    Ok(EncryptionRecoveryInfo { state: state.into(), device_verified })
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
        .map_err(|e| format!("Failed to recover encryption data: {e}"))
}

#[frb]
pub async fn enable_encryption_recovery(passphrase: Option<String>) -> Result<String, String> {
    let client = get_client().await.ok_or("No active client")?;
    let recovery = client.encryption().recovery();
    let passphrase = passphrase.map(|value| value.trim().to_string()).filter(|value| !value.is_empty());
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

/// Perform an initial sync with a 30-second timeout.
/// Uses traditional /sync for the initial load (Sliding Sync needs
/// this data in the state store first).
#[frb]
pub async fn sync_once() -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| {
            app_log("error", "sync", "sync_once: no client created".to_string());
            "No client created.".to_string()
        })?;
    let user_id = client
        .user_id()
        .map(|u| u.to_string())
        .unwrap_or_default();
    let hs = client.homeserver().to_string();
    app_log("info", "sync", format!("sync_once: starting for user {} (homeserver: {hs})", user_id));
    set_connection_status(ConnectionStatus::Connecting);

    let result = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        client.sync_once(matrix_sdk::config::SyncSettings::default()),
    )
    .await;

    match result {
        Ok(Ok(_)) => {
            app_log("info", "sync", format!("sync_once: completed for user {}", user_id));
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
            let msg = format!("sync_once: timed out after 30s for user {} (homeserver: {hs})", user_id);
            app_log("error", "sync", msg.clone());
            set_connection_status(ConnectionStatus::Disconnected);
            Err("Sync timed out after 30 seconds. Check your network connection and homeserver URL.".to_string())
        }
    }
}

/// Start a Sliding Sync loop for real-time updates.
/// Falls back to traditional sync_once loop if Sliding Sync is unavailable.
#[frb]
pub async fn start_sync() -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| {
            app_log("error", "sync", "start_sync: no client created".to_string());
            "No client created.".to_string()
        })?;
    let user_id = client
        .user_id()
        .map(|u| u.to_string())
        .unwrap_or_default();
    let hs = client.homeserver().to_string();
    app_log("info", "sync", format!("start_sync: beginning for user {} (homeserver: {hs})", user_id));

    stop_sync_task(None).await;

    // Try Sliding Sync first
    let handle = match try_start_sliding_sync(client.clone()).await {
        Ok(handle) => {
            app_log("info", "sync", format!("start_sync: Sliding Sync started for user {}", user_id));
            handle
        }
        Err(e) => {
            app_log("warn", "sync", format!("start_sync: Sliding Sync failed ({}), falling back to traditional sync loop", e));
            // Fallback: traditional sync loop
            let loop_user_id = user_id.clone();
            tokio::spawn(async move {
                app_log("info", "sync", format!("Traditional sync loop started for user {}", loop_user_id));
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
    use matrix_sdk::sliding_sync::{SlidingSyncList, SlidingSyncMode, Version};
    use matrix_sdk::ruma::events::StateEventType as RoomStateType;
    use futures_util::StreamExt;

    // Build the Sliding Sync instance
    let sliding_sync = client
        .sliding_sync("main")
        .map_err(|e| format!("Failed to create Sliding Sync: {e}"))?
        // Use native MSC4186 protocol (or proxy)
        .version(Version::Native)
        .with_all_extensions()
        // List: all visible rooms, growing from 0
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
                ])
                .timeline_limit(10u32),
        )
        .build()
        .await
        .map_err(|e| format!("Failed to build Sliding Sync: {e}"))?;

    // Spawn the sync loop
    let handle = tokio::spawn(async move {
        app_log("info", "sync", "Sliding Sync loop started".to_string());
        let stream = sliding_sync.sync();
        futures_util::pin_mut!(stream);
        while let Some(update) = stream.next().await {
            match update {
                Ok(summary) => {
                    app_log("info", "sync", format!("Sliding Sync update: {} rooms", summary.rooms.len()));
                    set_connection_status(ConnectionStatus::Connected);
                    notify_sync_event(SyncEvent::SyncCompleted);
                }
                Err(e) => {
                    app_log("error", "sync", format!("Sliding Sync error: {e}"));
                    set_connection_status(ConnectionStatus::Disconnected);
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                }
            }
        }
        app_log("warn", "sync", "Sliding Sync stream ended".to_string());
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
        while let Ok(event) = rx.blocking_recv() {
            if sink.add(event).is_err() {
                break; // Dart side disconnected
            }
        }
    });
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
    CONNECTION_STATE.read().unwrap_or_else(|e| e.into_inner()).clone()
}

#[frb]
pub async fn init_client() -> Result<(), String> {
    Ok(())
}

/// Convert an mxc:// URI to a thumbnail HTTP URL for chat bubbles.
/// Format: `{homeserver}/_matrix/client/v1/media/thumbnail/{server}/{mediaId}?width=800&height=600&method=scale`
#[frb]
pub async fn mxc_to_http(mxc_url: String) -> Option<String> {
    let client = get_client().await?;
    let url = url::Url::parse(&mxc_url).ok()?;
    if url.scheme() != "mxc" { return None; }
    let server_name = url.host_str()?;
    let media_id = url.path().trim_start_matches('/');
    if server_name.is_empty() || media_id.is_empty() { return None; }
    let raw_base = client.homeserver().to_string();
    let base = raw_base.trim_end_matches('/');
    let media_url = format!("{}/_matrix/client/v1/media/thumbnail/{}/{}?width=800&height=600&method=scale",
        base, server_name, media_id);
    app_log("info", "media", format!("Resolved media thumbnail for {}", mxc_url));
    Some(media_url)
}

/// Convert an mxc:// URI to a full-quality download HTTP URL.
/// Used for "原图" (original quality) preview.
#[frb]
pub async fn mxc_to_http_full(mxc_url: String) -> Option<String> {
    let client = get_client().await?;
    let url = url::Url::parse(&mxc_url).ok()?;
    if url.scheme() != "mxc" { return None; }
    let server_name = url.host_str()?;
    let media_id = url.path().trim_start_matches('/');
    if server_name.is_empty() || media_id.is_empty() { return None; }
    let raw_base = client.homeserver().to_string();
    let base = raw_base.trim_end_matches('/');
    let media_url = format!("{}/_matrix/client/v1/media/download/{}/{}",
        base, server_name, media_id);
    app_log("info", "media", format!("Resolved full media URL for {}", mxc_url));
    Some(media_url)
}

/// Download media content as raw bytes using the Matrix SDK's HTTP client.
/// This is more reliable than constructing URLs and loading from Flutter.
#[frb]
pub async fn download_media_bytes(mxc_url: String) -> Option<Vec<u8>> {
    let client = get_client().await?;
    let url = url::Url::parse(&mxc_url).ok()?;
    if url.scheme() != "mxc" { return None; }
    let server_name = url.host_str()?.to_string();
    let media_id = url.path().trim_start_matches('/').to_string();
    if server_name.is_empty() || media_id.is_empty() { return None; }

    use matrix_sdk::ruma::api::client::authenticated_media::get_content::v1::Request as MediaDownloadRequest;
    let server = matrix_sdk::ruma::ServerName::parse(&server_name).ok()?;
    let request = MediaDownloadRequest::new(media_id, server);

    match client.send(request).await {
        Ok(response) => {
            app_log("info", "media", format!("download_media_bytes: {} bytes for {}", response.file.len(), mxc_url));
            Some(response.file)
        }
        Err(e) => {
            app_log("error", "media", format!("download_media_bytes failed: {e}"));
            None
        }
    }
}

/// Get the current access token for authenticated media requests.
#[frb]
pub async fn get_access_token() -> Option<String> {
    let client = get_client().await?;
    let session = client.matrix_auth().session()?;
    Some(session.tokens.access_token)
}

#[frb]
pub async fn get_chat_rooms() -> Result<Vec<ChatRoom>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| {
            app_log("error", "rooms", "get_chat_rooms: no client created".to_string());
            "No client created.".to_string()
        })?;

    let rooms = client.rooms();
    app_log("info", "rooms", format!("get_chat_rooms: found {} total rooms", rooms.len()));
    let mut result = Vec::new();
    let mut joined = 0;

    for room in rooms {
        if room.state() != matrix_sdk::RoomState::Joined {
            continue;
        }
        joined += 1;

        let room_id = room.room_id().to_string();
        // Try explicit m.room.name first (sync, from state store)
        let mut name = room
            .name()
            .filter(|n| !n.is_empty())
            .unwrap_or_default();
        // If no explicit name, use cached display name (fast, no async)
        if name.is_empty() {
            name = room.cached_display_name()
                .map(|dn| dn.to_string())
                .unwrap_or_default();
        }
        name = name.trim().to_string();
        if name.is_empty() {
            name = room_id.clone();
        }
        let avatar_url = room.avatar_url().map(|u| u.to_string());
        let unread_count = room.unread_notification_counts().notification_count as i32;
        let (last_message, last_message_time) = get_last_message_info(&room);

        // Determine room type
        let room_type = if room.is_space() {
            "space".to_string()
        } else {
            match room.is_direct().await {
                Ok(true) => "dm".to_string(),
                _ => "group".to_string(),
            }
        };

        result.push(ChatRoom {
            id: room_id,
            name,
            avatar_url,
            last_message,
            last_message_time,
            unread_count,
            is_pinned: false,
            is_muted: false,
            room_type,
        });
    }

    app_log("info", "rooms", format!("get_chat_rooms: {} joined rooms returned", joined));
    result.sort_by(|a, b| {
        b.unread_count.cmp(&a.unread_count)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(result)
}

fn get_last_message_info(room: &matrix_sdk::Room) -> (String, String) {
    let mut last_msg = "(暂无消息)".to_string();
    let mut last_time = String::new();

    let latest_value = room.latest_event();
    if let matrix_sdk::latest_events::LatestEventValue::Remote(latest) = latest_value {
        let raw = latest.raw();
        if let Ok(any_ev) = raw.deserialize() {
            if let matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(msg),
            ) = any_ev
            {
                last_time = format_timestamp(u64::from(msg.origin_server_ts().0));
                if let Some(text) = msg.as_original().and_then(|o| {
                    match &o.content.msgtype {
                        matrix_sdk::ruma::events::room::message::MessageType::Text(t) => Some(t.body.clone()),
                        _ => None,
                    }
                }) {
                    last_msg = text;
                    if last_msg.len() > 50 {
                        // Safe truncation that respects UTF-8 char boundaries
                        let mut end = 50;
                        while end > 0 && !last_msg.is_char_boundary(end) {
                            end -= 1;
                        }
                        last_msg.truncate(end);
                        last_msg.push_str("...");
                    }
                }
            }
        }
    }

    (last_msg, last_time)
}

fn format_timestamp(millis: u64) -> String {
    let secs = millis / 1000;
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let diff = now_secs.saturating_sub(secs);

    if diff < 60 {
        "刚刚".to_string()
    } else if diff < 3600 {
        format!("{}分钟前", diff / 60)
    } else if diff < 86400 {
        format!("{}小时前", diff / 3600)
    } else if diff < 604800 {
        format!("{}天前", diff / 86400)
    } else {
        let hours = ((secs / 3600) % 24) as u8;
        let mins = ((secs / 60) % 60) as u8;
        format!("{:02}:{:02}", hours, mins)
    }
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

/// Extract edit text from a replacement relation's new_content.
fn extract_edit_text(new_content: &matrix_sdk::ruma::events::room::message::RoomMessageEventContentWithoutRelation) -> Option<String> {
    match &new_content.msgtype {
        matrix_sdk::ruma::events::room::message::MessageType::Text(t) => Some(t.body.clone()),
        matrix_sdk::ruma::events::room::message::MessageType::Notice(t) => Some(t.body.clone()),
        _ => None,
    }
}

/// Get messages for a room (must sync first).
#[frb]
pub async fn get_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let my_user_id = client.user_id().map(|u| u.to_string());

    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let mut raw_messages: Vec<(String, ChatMessage)> = Vec::new();
    let mut edits: HashMap<String, Vec<String>> = HashMap::new();
    let mut last_event_id: Option<String> = None;

    let mut opts = matrix_sdk::room::MessagesOptions::backward();
    opts.limit = 50u32.into();

    if let Ok(msg_resp) = room.messages(opts).await {
        for timeline_event in msg_resp.chunk.iter().rev() {
            let raw = timeline_event.kind.raw();
            let Ok(any_ev) = raw.deserialize() else { continue };

            let event_id_str = any_ev.event_id().to_string();
            let sender_id = any_ev.sender().to_string();
            let is_me = my_user_id.as_ref() == Some(&sender_id);
            let sender_name = if is_me {
                "\u{6211}".to_string() // "我"
            } else {
                sender_id.split(':').next()
                    .unwrap_or(&sender_id)
                    .trim_start_matches('@')
                    .to_string()
            };

            let ts_millis = u64::from(any_ev.origin_server_ts().0);
            let secs = ts_millis / 1000;
            let hours = ((secs / 3600) % 24) as u8;
            let mins = ((secs / 60) % 60) as u8;
            let timestamp = format!("{:02}:{:02}", hours, mins);

            match &any_ev {
                // ── Message events ──
                matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                    matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(msg),
                ) => {
                    let Some(original) = msg.as_original() else { continue };

                    // Check if this is an edit (replacement) event
                    if let Some(matrix_sdk::ruma::events::room::message::Relation::Replacement(replacement)) = &original.content.relates_to {
                        if let Some(edit_text) = extract_edit_text(&replacement.new_content) {
                            edits.entry(replacement.event_id.to_string())
                                .or_default()
                                .push(edit_text);
                        }
                        continue; // Do not add the edit event itself to the message list
                    }

                    let in_reply_to = original.content.relates_to.as_ref().and_then(|rel| {
                        if let matrix_sdk::ruma::events::room::message::Relation::Reply(reply) = rel {
                            Some(reply.in_reply_to.event_id.to_string())
                        } else {
                            None
                        }
                    });

                    let chat_msg = match &original.content.msgtype {
                        matrix_sdk::ruma::events::room::message::MessageType::Text(t) => {
                            let content = if in_reply_to.is_some() {
                                strip_reply_fallback(&t.body)
                            } else {
                                t.body.clone()
                            };
                            ChatMessage {
                                id: event_id_str.clone(), sender_id: sender_id.clone(), sender_name: sender_name.clone(),
                                content, timestamp: timestamp.clone(), is_me,
                                msg_type: MessageType::Text, image_url: None, in_reply_to,
                                is_edited: false, edit_history: Vec::new(),
                            }
                        }
                        matrix_sdk::ruma::events::room::message::MessageType::Emote(t) => {
                            let name = sender_name.clone();
                            let content = if in_reply_to.is_some() {
                                format!("* {} {}", name, strip_reply_fallback(&t.body))
                            } else {
                                format!("* {} {}", name, t.body)
                            };
                            ChatMessage {
                                id: event_id_str.clone(), sender_id: sender_id.clone(), sender_name: sender_name.clone(),
                                content, timestamp: timestamp.clone(), is_me,
                                msg_type: MessageType::Text, image_url: None, in_reply_to,
                                is_edited: false, edit_history: Vec::new(),
                            }
                        }
                        matrix_sdk::ruma::events::room::message::MessageType::Notice(t) => {
                            let content = if in_reply_to.is_some() {
                                strip_reply_fallback(&t.body)
                            } else {
                                t.body.clone()
                            };
                            ChatMessage {
                                id: event_id_str.clone(), sender_id: sender_id.clone(), sender_name: sender_name.clone(),
                                content, timestamp: timestamp.clone(), is_me,
                                msg_type: MessageType::Text, image_url: None, in_reply_to,
                                is_edited: false, edit_history: Vec::new(),
                            }
                        }
                        matrix_sdk::ruma::events::room::message::MessageType::Image(t) => {
                            let url = match &t.source {
                                matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                                _ => None,
                            };
                            ChatMessage {
                                id: event_id_str.clone(), sender_id: sender_id.clone(), sender_name: sender_name.clone(),
                                content: t.body.clone(), timestamp: timestamp.clone(), is_me,
                                msg_type: MessageType::Image, image_url: url, in_reply_to,
                                is_edited: false, edit_history: Vec::new(),
                            }
                        }
                        matrix_sdk::ruma::events::room::message::MessageType::File(t) => {
                            ChatMessage {
                                id: event_id_str.clone(), sender_id: sender_id.clone(), sender_name: sender_name.clone(),
                                content: format!("\u{6587}\u{4EF6}: {}", t.body),
                                timestamp: timestamp.clone(), is_me,
                                msg_type: MessageType::Text, image_url: None, in_reply_to,
                                is_edited: false, edit_history: Vec::new(),
                            }
                        }
                        _ => {
                            last_event_id = Some(event_id_str.clone());
                            continue; // skip unknown message types
                        }
                    };
                    raw_messages.push((event_id_str.clone(), chat_msg));
                    last_event_id = Some(event_id_str.clone());
                }

                // ── State/member events ──
                matrix_sdk::ruma::events::AnySyncTimelineEvent::State(state_ev) => {
                    let content = match state_ev {
                        matrix_sdk::ruma::events::AnySyncStateEvent::RoomMember(m) => {
                            let target = m.state_key().to_string();
                            let target_name = target.split(':').next()
                                .unwrap_or(&target)
                                .trim_start_matches('@')
                                .to_string();
                            match m.as_original() {
                                Some(orig) => match &orig.content.membership {
                                    matrix_sdk::ruma::events::room::member::MembershipState::Join => Some(format!("{} 加入了房间", target_name)),
                                    matrix_sdk::ruma::events::room::member::MembershipState::Leave => {
                                        if is_me {
                                            Some(format!("{} 离开了房间", target_name))
                                        } else {
                                            None // skip own leave
                                        }
                                    }
                                    matrix_sdk::ruma::events::room::member::MembershipState::Ban => Some(format!("{} 被封禁", target_name)),
                                    matrix_sdk::ruma::events::room::member::MembershipState::Invite => Some(format!("{} 被邀请加入房间", target_name)),
                                    matrix_sdk::ruma::events::room::member::MembershipState::Knock => Some(format!("{} 请求加入房间", target_name)),
                                    _ => None,
                                },
                                None => None,
                            }
                        }
                        matrix_sdk::ruma::events::AnySyncStateEvent::RoomCreate(_) => {
                            Some("房间已创建".to_string())
                        }
                        matrix_sdk::ruma::events::AnySyncStateEvent::RoomName(n) => {
                            n.as_original().map(|o| format!("房间名称更改为: {}", o.content.name))
                        }
                        matrix_sdk::ruma::events::AnySyncStateEvent::RoomTopic(t) => {
                            t.as_original().map(|o| format!("主题更改为: {}", o.content.topic))
                        }
                        matrix_sdk::ruma::events::AnySyncStateEvent::RoomAvatar(_) => {
                            Some("房间头像已更改".to_string())
                        }
                        _ => None,
                    };
                    if let Some(content) = content {
                        raw_messages.push((event_id_str.clone(), ChatMessage {
                            id: event_id_str.clone(), sender_id: sender_id.clone(), sender_name: sender_name.clone(),
                            content, timestamp: timestamp.clone(), is_me: false,
                            msg_type: MessageType::Event, image_url: None, in_reply_to: None,
                            is_edited: false, edit_history: Vec::new(),
                        }));
                    }
                    last_event_id = Some(any_ev.event_id().to_string());
                }
                _ => {}
            }
        }
    }

    // Apply edits to the corresponding messages
    let mut messages = Vec::new();
    for (event_id, mut msg) in raw_messages {
        if let Some(history) = edits.remove(&event_id) {
            msg.is_edited = true;
            // Prepend original content so edit_history = [original, edit1, edit2, ...]
            let original = msg.content.clone();
            let mut full_history = vec![original];
            full_history.extend(history);
            msg.content = full_history.last().unwrap().clone();
            msg.edit_history = full_history;
        }
        messages.push(msg);
    }

    // Send read receipt for the last event (mark room as read)
    if let Some(ref last_id) = last_event_id {
        if let Ok(event_id) = matrix_sdk::ruma::EventId::parse(last_id) {
            let receipts = matrix_sdk::room::Receipts::new()
                .fully_read_marker(event_id.clone())
                .public_read_receipt(event_id);
            let _ = room.send_multiple_receipts(receipts).await;
        }
    }

    Ok(messages)
}

/// Send a text message to a room.
#[frb]
pub async fn send_message(room_id: String, message: String) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let content = matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_plain(&message);

    room.send(content)
        .await
        .map_err(|e| format!("Send failed: {e}"))?;

    app_log("info", "rooms", format!("Message sent to {}", room_id));
    info!("Message sent to {}", room_id);
    notify_sync_event(SyncEvent::MessageSent { room_id: room_id.clone() });
    Ok(())
}

/// Send an image message to a room.
/// `image_data` is the raw bytes of the image file.
/// `filename` is the original file name (e.g. "photo.jpg").
#[frb]
pub async fn send_image_message(
    room_id: String,
    image_data: Vec<u8>,
    filename: String,
) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    // Detect MIME type from filename extension
    let mime_type: mime::Mime = if filename.ends_with(".png") {
        mime::IMAGE_PNG
    } else if filename.ends_with(".gif") {
        mime::IMAGE_GIF
    } else if filename.ends_with(".webp") {
        "image/webp".parse().unwrap_or(mime::IMAGE_JPEG)
    } else {
        mime::IMAGE_JPEG
    };

    app_log("info", "media", format!("Uploading image: {} ({} bytes, mime: {})", filename, image_data.len(), mime_type));

    // Upload image to homeserver
    let upload_response = client
        .media()
        .upload(&mime_type, image_data, None)
        .await
        .map_err(|e| format!("Image upload failed: {e}"))?;

    let content_uri = upload_response.content_uri;
    app_log("info", "media", format!("Image uploaded: {}", content_uri));

    // Build image message content
    use matrix_sdk::ruma::events::room::message::{ImageMessageEventContent, MessageType, RoomMessageEventContent};

    let image_content = ImageMessageEventContent::plain(filename.clone(), content_uri);
    let content = RoomMessageEventContent::new(MessageType::Image(image_content));

    room.send(content)
        .await
        .map_err(|e| format!("Send image message failed: {e}"))?;

    app_log("info", "rooms", format!("Image message sent to {}", room_id));
    info!("Image message sent to {}", room_id);
    notify_sync_event(SyncEvent::MessageSent { room_id: room_id.clone() });
    Ok(())
}

/// Create a new direct chat room with a user.
#[frb]
pub async fn create_dm(user_id: String) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let invited_user = matrix_sdk::ruma::UserId::parse(&user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;

    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.invite = vec![invited_user];
    request.is_direct = true;

    let response = client
        .create_room(request)
        .await
        .map_err(|e| format!("Create room failed: {e}"))?;

    app_log("info", "rooms", format!("Created DM room: {}", response.room_id()));
    info!("Created DM room: {}", response.room_id());
    Ok(response.room_id().to_string())
}

/// Create a group room with a name and optional topic.
#[frb]
pub async fn create_group_room(name: String, topic: Option<String>) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.name = Some(name);
    request.topic = topic;

    let response = client
        .create_room(request)
        .await
        .map_err(|e| format!("Create room failed: {e}"))?;

    app_log("info", "rooms", format!("Created group room: {}", response.room_id()));
    info!("Created group room: {}", response.room_id());
    Ok(response.room_id().to_string())
}

#[frb]
pub async fn get_spaces() -> Result<Vec<Space>, String> {
    Ok(vec![
        Space { id: "all".to_string(), name: "全部".to_string(), avatar_url: None },
    ])
}

#[frb]
pub async fn get_contacts() -> Result<Vec<Contact>, String> {
    Ok(vec![])
}

/// Send a reply to a specific message in a room.
#[frb]
pub async fn send_reply(room_id: String, message: String, reply_to_event_id: String) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    // Parse the event ID we're replying to
    let event_id = matrix_sdk::ruma::EventId::parse(&reply_to_event_id)
        .map_err(|e| format!("Invalid event ID: {e}"))?;

    // Build the reply content
    let content = matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_plain(&message);
    let mut reply_content = content;
    reply_content.relates_to = Some(matrix_sdk::ruma::events::room::message::Relation::Reply(
        matrix_sdk::ruma::events::relation::Reply::with_event_id(event_id),
    ));

    room.send(reply_content)
        .await
        .map_err(|e| format!("Reply failed: {e}"))?;

    app_log("info", "rooms", format!("Reply sent to {} in room {}", reply_to_event_id, room_id));
    info!("Reply sent to {} in room {}", reply_to_event_id, room_id);
    notify_sync_event(SyncEvent::MessageSent { room_id: room_id.clone() });
    Ok(())
}

/// Redact (delete) a message from a room.
#[frb]
pub async fn redact_message(room_id: String, event_id: String, reason: Option<String>) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| format!("Invalid event ID: {e}"))?;

    room.redact(&parsed_event_id, reason.as_deref(), None)
        .await
        .map_err(|e| format!("Redact failed: {e}"))?;

    app_log("info", "rooms", format!("Redacted event {} in room {}", event_id, room_id));
    info!("Redacted event {} in room {}", event_id, room_id);
    notify_sync_event(SyncEvent::SyncCompleted);
    Ok(())
}

/// Send a typing notice to a room.
#[frb]
pub async fn send_typing_notice(room_id: String, typing: bool) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    room.typing_notice(typing)
        .await
        .map_err(|e| format!("Typing notice failed: {e}"))?;
    Ok(())
}

/// Get members of a room.
#[frb]
pub async fn get_room_members(room_id: String) -> Result<Vec<Contact>, String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let members = room.members(matrix_sdk::RoomMemberships::JOIN).await
        .map_err(|e| format!("Failed to get members: {e}"))?;

    app_log("info", "rooms", format!("get_room_members: {} members in room {}", members.len(), room_id));

    let mut contacts = Vec::new();
    for member in members {
        let name = member.name().to_string();
        let user_id = member.user_id().to_string();
        let avatar = member.avatar_url().map(|u| u.to_string());
        contacts.push(Contact {
            id: user_id.clone(),
            name: if name == user_id { user_id.clone() } else { name },
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
    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)?;
    room.avatar_url().map(|u| u.to_string())
}

/// Search rooms by name.
#[frb]
pub async fn search_rooms(query: String) -> Result<Vec<ChatRoom>, String> {
    let all = get_chat_rooms().await?;
    let q = query.to_lowercase();
    let filtered: Vec<ChatRoom> = all.into_iter()
        .filter(|r| r.name.to_lowercase().contains(&q))
        .collect();
    Ok(filtered)
}

/// Load more messages (paginated) from before a given event.
#[frb]
pub async fn get_messages_before(room_id: String, from_event_id: String, limit: u32) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let my_user_id = client.user_id().map(|u| u.to_string());

    let room = client.rooms()
        .into_iter()
        .find(|r| r.room_id().to_string() == room_id)
        .ok_or_else(|| format!("Room not found: {room_id}"))?;

    let mut raw_messages: Vec<(String, ChatMessage)> = Vec::new();
    let mut edits: HashMap<String, Vec<String>> = HashMap::new();

    // Use the event ID as the "from" token for backwards pagination
    let _from_token = matrix_sdk::ruma::events::TimelineEventType::from(from_event_id.clone());
    let mut opts = matrix_sdk::room::MessagesOptions::backward();
    opts.limit = limit.into();
    opts.from = Some(from_event_id);

    if let Ok(msg_resp) = room.messages(opts).await {
        for timeline_event in msg_resp.chunk.iter().rev() {
            let raw = timeline_event.kind.raw();
            let Ok(any_ev) = raw.deserialize() else { continue };

            let matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(msg),
            ) = any_ev else { continue };

            let Some(original) = msg.as_original() else { continue };

            let sender_id = msg.sender().to_string();
            let is_me = my_user_id.as_ref() == Some(&sender_id);
            let sender_name = if is_me {
                "\u{6211}".to_string()
            } else {
                sender_id.split(':').next()
                    .unwrap_or(&sender_id)
                    .trim_start_matches('@')
                    .to_string()
            };

            let ts_millis = u64::from(msg.origin_server_ts().0);
            let secs = ts_millis / 1000;
            let hours = ((secs / 3600) % 24) as u8;
            let mins = ((secs / 60) % 60) as u8;
            let timestamp = format!("{:02}:{:02}", hours, mins);
            let event_id = msg.event_id().to_string();

            // Check if this is an edit (replacement) event
            if let Some(matrix_sdk::ruma::events::room::message::Relation::Replacement(replacement)) = &original.content.relates_to {
                if let Some(edit_text) = extract_edit_text(&replacement.new_content) {
                    edits.entry(replacement.event_id.to_string())
                        .or_default()
                        .push(edit_text);
                }
                continue;
            }

            let in_reply_to = original.content.relates_to.as_ref().and_then(|rel| {
                if let matrix_sdk::ruma::events::room::message::Relation::Reply(reply) = rel {
                    Some(reply.in_reply_to.event_id.to_string())
                } else {
                    None
                }
            });

            let chat_msg = match &original.content.msgtype {
                matrix_sdk::ruma::events::room::message::MessageType::Text(t) => {
                    let content = if in_reply_to.is_some() {
                        strip_reply_fallback(&t.body)
                    } else {
                        t.body.clone()
                    };
                    ChatMessage {
                        id: event_id.clone(),
                        sender_id,
                        sender_name,
                        content,
                        timestamp,
                        is_me,
                        msg_type: MessageType::Text,
                        image_url: None,
                        in_reply_to,
                        is_edited: false,
                        edit_history: Vec::new(),
                    }
                }
                matrix_sdk::ruma::events::room::message::MessageType::Image(t) => {
                    let url = match &t.source {
                        matrix_sdk::ruma::events::room::MediaSource::Plain(mxc) => Some(mxc.to_string()),
                        _ => None,
                    };
                    ChatMessage {
                        id: event_id.clone(),
                        sender_id,
                        sender_name,
                        content: t.body.clone(),
                        timestamp,
                        is_me,
                        msg_type: MessageType::Image,
                        image_url: url,
                        in_reply_to,
                        is_edited: false,
                        edit_history: Vec::new(),
                    }
                }
                _ => continue,
            };
            raw_messages.push((event_id, chat_msg));
        }
    }

    // Apply edits
    let mut messages = Vec::new();
    for (event_id, mut msg) in raw_messages {
        if let Some(history) = edits.remove(&event_id) {
            msg.is_edited = true;
            let original = msg.content.clone();
            let mut full_history = vec![original];
            full_history.extend(history);
            msg.content = full_history.last().unwrap().clone();
            msg.edit_history = full_history;
        }
        messages.push(msg);
    }

    Ok(messages)
}
