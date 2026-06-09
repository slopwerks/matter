use flutter_rust_bridge::frb;
use matrix_sdk::{
    Client, SessionMeta, SessionTokens,
    authentication::matrix::MatrixSession,
    ruma::api::client::{
        account::register::v3::Request as RegistrationRequest,
        uiaa::{AuthData, RegistrationToken, UiaaInfo},
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

/// Try to extract UIAA info from a register error.
/// We try multiple ways because the error might be wrapped differently.
fn try_extract_uiaa(err: &matrix_sdk::Error) -> Option<&UiaaInfo> {
    // Method 1: the official SDK method
    if let Some(info) = err.as_uiaa_response() {
        return Some(info);
    }

    // Method 2: dig through HttpError manually
    if let matrix_sdk::Error::Http(http_err) = err {
        if let Some(info) = http_err.as_uiaa_response() {
            return Some(info);
        }
    }

    None
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

    let mut request = RegistrationRequest::new();
    request.username = Some(username);
    request.password = Some(password);
    request.initial_device_display_name = Some("Matter".to_owned());
    // No auth data — this will trigger 401 UIAA from the server

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
            if let Some(uiaa_info) = try_extract_uiaa(&err) {
                Ok(uiaa_to_auth_result(uiaa_info))
            } else {
                Ok(AuthResult {
                    success: false,
                    user_id: None,
                    device_id: None,
                    access_token: None,
                    error: Some(format!("{err}")),
                    needs_uiaa: false,
                    session: None,
                    flows: None,
                })
            }
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
            if let Some(uiaa_info) = try_extract_uiaa(&err) {
                // Still needs UIAA — maybe wrong token, server gave a new session
                Ok(uiaa_to_auth_result(uiaa_info))
            } else {
                Ok(AuthResult {
                    success: false,
                    user_id: None,
                    device_id: None,
                    access_token: None,
                    error: Some(format!("{err}")),
                    needs_uiaa: false,
                    session: None,
                    flows: None,
                })
            }
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

// ── Legacy mock functions (kept for UI compatibility) ────────────────

#[frb(sync)]
pub fn get_connection_status() -> ConnectionStatus {
    ConnectionStatus::Connected
}

#[frb]
pub async fn init_client() -> Result<(), String> {
    Ok(())
}

#[frb]
pub async fn get_chat_rooms() -> Result<Vec<ChatRoom>, String> {
    let rooms = vec![
        ChatRoom {
            id: "room_1".to_string(),
            name: "Flutter 开发者".to_string(),
            avatar_url: None,
            last_message: "新的 UI 看起来真不错 👍".to_string(),
            last_message_time: "14:32".to_string(),
            unread_count: 3,
            is_pinned: true,
            is_muted: false,
        },
        ChatRoom {
            id: "room_2".to_string(),
            name: "Rust 交流".to_string(),
            avatar_url: None,
            last_message: "async/await 在 FFI 里确实有点麻烦".to_string(),
            last_message_time: "12:05".to_string(),
            unread_count: 0,
            is_pinned: false,
            is_muted: false,
        },
        ChatRoom {
            id: "room_3".to_string(),
            name: "Matrix Protocol".to_string(),
            avatar_url: None,
            last_message: "你们试过新的 sliding sync 吗？".to_string(),
            last_message_time: "昨天".to_string(),
            unread_count: 12,
            is_pinned: false,
            is_muted: false,
        },
    ];
    Ok(rooms)
}

#[frb]
pub async fn get_spaces() -> Result<Vec<Space>, String> {
    let spaces = vec![
        Space { id: "all".to_string(), name: "全部".to_string(), avatar_url: None },
        Space { id: "space_1".to_string(), name: "工作".to_string(), avatar_url: None },
    ];
    Ok(spaces)
}

#[frb]
pub async fn get_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
    let _ = room_id;
    let messages = vec![
        ChatMessage {
            id: "msg_1".to_string(),
            sender_id: "user_1".to_string(),
            sender_name: "Alice".to_string(),
            content: "嗨，Matter 的 UI 看起来真不错！".to_string(),
            timestamp: "14:20".to_string(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
        },
    ];
    Ok(messages)
}

#[frb]
pub async fn get_contacts() -> Result<Vec<Contact>, String> {
    let contacts = vec![
        Contact {
            id: "user_1".to_string(),
            name: "Alice".to_string(),
            avatar_url: None,
            status: "在线".to_string(),
        },
    ];
    Ok(contacts)
}
