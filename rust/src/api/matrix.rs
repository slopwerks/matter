use flutter_rust_bridge::frb;
use log::{info, warn};
use matrix_sdk::{
    Client, SessionMeta, SessionTokens,
    authentication::matrix::MatrixSession,
    ruma::api::client::{
        account::register::v3::Request as RegistrationRequest,
        uiaa::{AuthData, Dummy, RegistrationToken, UiaaInfo},
    },
    store::RoomLoadSettings,
};
use once_cell::sync::Lazy;
use std::sync::Arc;
use tokio::sync::RwLock;

// ── Global client store ──────────────────────────────────────────────

static CLIENT_STORE: Lazy<Arc<RwLock<Option<Client>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

async fn store_client(client: Client) {
    let mut store = CLIENT_STORE.write().await;
    *store = Some(client);
}

async fn get_client() -> Option<Client> {
    let store = CLIENT_STORE.read().await;
    store.clone()
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
pub enum MessageType {
    Text,
    Image,
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

// ── Internal helpers ─────────────────────────────────────────────────

/// Try to extract UIAA info from a register error via structured SDK APIs.
fn try_extract_uiaa(err: &matrix_sdk::Error) -> Option<AuthResult> {
    // Method 1: top-level SDK method
    if let Some(uiaa_info) = err.as_uiaa_response() {
        info!("UIAA extracted via err.as_uiaa_response()");
        return Some(uiaa_to_auth_result(uiaa_info));
    }

    // Method 2: dig into HttpError manually
    if let matrix_sdk::Error::Http(http_err) = err {
        if let Some(uiaa_info) = http_err.as_uiaa_response() {
            info!("UIAA extracted via http_err.as_uiaa_response()");
            return Some(uiaa_to_auth_result(uiaa_info));
        }
    }

    None
}
/// Fallback: parse UIAA info from the error Display string.
///
/// The SDK may not always expose UIAA as a structured error. When it doesn't,
/// the raw 401 JSON body ends up in the error Display string like:
///   `the server returned an error: [401] {"completed":[...],"flows":[...],"session":"..."}`
/// We extract that JSON and parse it properly.
fn try_parse_uiaa_from_string(err_str: &str) -> Option<AuthResult> {
    // Find the JSON object — it starts with { after [401]
    let json_start = err_str
        .find("[401]")
        .and_then(|pos| err_str[pos + 5..].find('{').map(|p| pos + 5 + p))?;
    let json_str = &err_str[json_start..];

    let val: serde_json::Value = serde_json::from_str(json_str).ok()?;

    // Verify it's a UIAA challenge with registration_token
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

    let session = val.get("session").and_then(|s| s.as_str()).map(|s| s.to_string());

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

/// Convert UiaaInfo into our AuthResult
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
#[frb]
pub async fn create_client(homeserver_url: String) -> Result<(), String> {
    let url = url::Url::parse(&homeserver_url).map_err(|e| format!("Invalid URL: {e}"))?;

    let client = Client::builder()
        .homeserver_url(url)
        .build()
        .await
        .map_err(|e| format!("Failed to create client: {e}"))?;

    store_client(client).await;
    Ok(())
}

/// Step 1 of registration: send a register request without auth to discover
/// the UIAA session and flows. The server will respond with 401 + UIAA info.
#[frb]
pub async fn register_get_uiaa_session(
    username: String,
    password: String,
) -> Result<AuthResult, String> {
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    // Send a Dummy auth to trigger UIAA flow discovery.
    // Some servers won't return UIAA info without an initial auth body.
    let mut request = RegistrationRequest::new();
    request.username = Some(username);
    request.password = Some(password);
    request.initial_device_display_name = Some("Matter".to_owned());
    request.auth = Some(AuthData::Dummy(Dummy::new()));

    match client.matrix_auth().register(request).await {
        // Unexpected: server registered without UIAA
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
            info!("register_get_uiaa_session error: {}", &err_str[..err_str.len().min(300)]);

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

/// Step 2 of registration: complete registration by providing the registration
/// token and the UIAA session obtained from register_get_uiaa_session.
#[frb]
pub async fn register_complete_uiaa(
    username: String,
    password: String,
    registration_token: String,
    session: String,
) -> Result<AuthResult, String> {
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
            info!("register_complete_uiaa error: {}", &err_str[..err_str.len().min(300)]);

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
    let client = get_client()
        .await
        .ok_or("No client created. Call create_client first.")?;

    match client
        .matrix_auth()
        .login_username(&username, &password)
        .initial_device_display_name("Matter")
        .await
    {
        Ok(response) => Ok(AuthResult {
            success: true,
            user_id: Some(response.user_id.to_string()),
            device_id: Some(response.device_id.to_string()),
            access_token: Some(response.access_token),
            error: None,
            needs_uiaa: false,
            session: None,
            flows: None,
        }),
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

    Ok(AuthResult {
        success: true,
        user_id: client.user_id().map(|u| u.to_string()),
        device_id: client.device_id().map(|d| d.to_string()),
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

/// Logout the current user.
#[frb]
pub async fn logout() -> Result<(), String> {
    if let Some(client) = get_client().await {
        if client.matrix_auth().logged_in() {
            client
                .matrix_auth()
                .logout()
                .await
                .map_err(|e| format!("Logout failed: {e}"))?;
        }
    }
    let mut store = CLIENT_STORE.write().await;
    *store = None;
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

/// Restore a previously saved session.
#[frb]
pub async fn restore_session(session: StoredSession) -> Result<(), String> {
    let url = url::Url::parse(&session.homeserver_url)
        .map_err(|e| format!("Invalid URL: {e}"))?;

    // Use sqlite store for persistent state
    let data_dir = dirs::data_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join("matter")
        .join("sdk");

    let client = Client::builder()
        .homeserver_url(url)
        .sqlite_store(data_dir, None)
        .build()
        .await
        .map_err(|e| format!("Client build failed: {e}"))?;

    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| format!("Invalid user ID: {e}"))?;
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
        .map_err(|e| format!("Restore failed: {e}"))?;

    store_client(client).await;
    info!("Session restored for {}", session.user_id);
    Ok(())
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

/// Perform an initial sync and then start a background sync loop.
/// Returns immediately after the initial sync. The background sync
/// runs forever via `client.sync()` which uses long-polling (30s timeout).
/// When new events arrive, we notify via the sync_state stream.
#[frb]
pub async fn sync_once() -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    client
        .sync_once(matrix_sdk::config::SyncSettings::default())
        .await
        .map_err(|e| format!("Sync failed: {e}"))?;

    info!("Initial sync completed");
    Ok(())
}

/// Start a background sync loop. This uses long-polling (the server holds
/// the connection for up to 30s waiting for new events, then responds).
/// After each response, it immediately starts the next poll.
/// This is the standard approach for Matrix clients — NOT polling.
#[frb]
pub async fn start_sync() -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let settings = matrix_sdk::config::SyncSettings::default();

    // Spawn the sync loop in a background tokio task
    tokio::spawn(async move {
        info!("Background sync loop started");
        match client.sync(settings).await {
            Ok(()) => info!("Sync loop ended normally"),
            Err(e) => warn!("Sync loop error: {e}"),
        }
    });

    Ok(())
}

/// Check if background sync is alive.
#[frb]
pub async fn is_connected() -> bool {
    if let Some(client) = get_client().await {
        client.matrix_auth().logged_in()
    } else {
        false
    }
}

// ── Chat functions ───────────────────────────────────────────────────

#[frb(sync)]
pub fn get_connection_status() -> ConnectionStatus {
    ConnectionStatus::Connected
}

#[frb]
pub async fn init_client() -> Result<(), String> {
    Ok(())
}

/// Get all joined rooms (must sync first).
#[frb]
pub async fn get_chat_rooms() -> Result<Vec<ChatRoom>, String> {
    let client = get_client()
        .await
        .ok_or("No client created.")?;

    let rooms = client.rooms();
    let mut result = Vec::new();

    for room in rooms {
        if room.state() != matrix_sdk::RoomState::Joined {
            continue;
        }

        let room_id = room.room_id().to_string();
        let name = room.display_name().await
            .map(|dn| dn.to_string())
            .unwrap_or_else(|_| room_id.clone());
        let avatar_url = room.avatar_url().map(|u| u.to_string());
        let unread_count = room.unread_notification_counts().notification_count as i32;
        let (last_message, last_message_time) = get_last_message_info(&room).await;

        result.push(ChatRoom {
            id: room_id,
            name,
            avatar_url,
            last_message,
            last_message_time,
            unread_count,
            is_pinned: false,
            is_muted: false,
        });
    }

    result.sort_by(|a, b| {
        b.unread_count.cmp(&a.unread_count)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(result)
}

async fn get_last_message_info(room: &matrix_sdk::Room) -> (String, String) {
    let mut last_msg = "(暂无消息)".to_string();
    let mut last_time = String::new();

    let mut opts = matrix_sdk::room::MessagesOptions::backward();
    opts.limit = 1u32.into();

    if let Ok(msg_resp) = room.messages(opts).await {
        if let Some(timeline_event) = msg_resp.chunk.first() {
            let raw = timeline_event.kind.raw();
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
                            last_msg.truncate(47);
                            last_msg.push_str("...");
                        }
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

    let mut messages = Vec::new();

    let mut opts = matrix_sdk::room::MessagesOptions::backward();
    opts.limit = 50u32.into();

    if let Ok(msg_resp) = room.messages(opts).await {
        for timeline_event in msg_resp.chunk.iter().rev() {
            let raw = timeline_event.kind.raw();
            let Ok(any_ev) = raw.deserialize() else { continue };

            let matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
                matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(msg),
            ) = any_ev else { continue };

            let body = match msg.as_original().and_then(|o| {
                match &o.content.msgtype {
                    matrix_sdk::ruma::events::room::message::MessageType::Text(t) => Some(t.body.clone()),
                    _ => None,
                }
            }) {
                Some(b) => b,
                None => continue,
            };

            let sender_id = msg.sender().to_string();
            let is_me = my_user_id.as_ref() == Some(&sender_id);

            let sender_name = if is_me {
                "我".to_string()
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

            messages.push(ChatMessage {
                id: event_id,
                sender_id,
                sender_name,
                content: body,
                timestamp,
                is_me,
                msg_type: MessageType::Text,
                image_url: None,
            });
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

    info!("Message sent to {}", room_id);
    Ok(())
}

/// Create a new direct chat room with a user.
/// Returns the new room ID.
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

    info!("Created DM room: {}", response.room_id());
    Ok(response.room_id().to_string())
}

/// Create a group room with a name and optional topic.
/// Returns the new room ID.
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
