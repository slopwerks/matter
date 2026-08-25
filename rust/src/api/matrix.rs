use flutter_rust_bridge::frb;
use futures_util::future::{BoxFuture, FutureExt, Shared};
use log::{info, warn};
use matrix_sdk::config::RequestConfig;
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
        ignored_user_list::{IgnoredUser, IgnoredUserListEventContent},
        key::verification::{request::ToDeviceKeyVerificationRequestEvent, VerificationMethod},
        marked_unread::MarkedUnreadEventContent,
        receipt::SyncReceiptEvent,
        room::{
            avatar::RoomAvatarEventContent, member::RoomMemberEventContent,
            name::RoomNameEventContent, pinned_events::RoomPinnedEventsEventContent,
            topic::RoomTopicEventContent,
        },
        AnySyncMessageLikeEvent, GlobalAccountDataEvent, RoomAccountDataEvent, StateEventType,
        SyncStateEvent,
    },
    store::RoomLoadSettings,
    Client, Room, SessionMeta, SessionTokens,
};
use once_cell::sync::Lazy;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::future::Future;
use std::io::{Cursor, Read};
use std::ops::Deref;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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

/// Initialize persisted logging before startup session discovery begins.
#[frb(sync)]
pub fn initialize_log_store(data_dir: String) {
    init_log_store(&data_dir);
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

/// Record an API failure in the app log and return the message for
/// propagation to Dart, so no error crosses the FFI boundary silently.
fn api_err(tag: &str, message: String) -> String {
    app_log("error", tag, message.clone());
    message
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

/// Write a log entry from the Dart side into the same app-wide log system
/// (ring buffer, persisted file, live stream) used by Rust. Unknown levels
/// fall back to "info".
#[frb(sync)]
pub fn log_app_message(level: String, tag: String, message: String) {
    let level = match level.as_str() {
        "error" | "warn" => level,
        _ => "info".to_string(),
    };
    app_log(&level, &tag, message);
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
static SYNC_PUBLICATION_LOCK: Lazy<std::sync::Mutex<()>> = Lazy::new(|| std::sync::Mutex::new(()));

fn set_connection_status(status: ConnectionStatus) {
    if let Ok(mut guard) = CONNECTION_STATE.write() {
        *guard = status;
    }
}

fn advance_sync_generation() -> u64 {
    let _publication = sync_publication_lock();
    SYNC_GENERATION.fetch_add(1, Ordering::SeqCst) + 1
}

fn set_connection_status_for_generation(generation: u64, status: ConnectionStatus) {
    let _publication = sync_publication_lock();
    if SYNC_GENERATION.load(Ordering::SeqCst) == generation {
        set_connection_status(status);
    }
}

fn notify_sync_event_for_generation(generation: u64, event: SyncEvent) {
    let _publication = sync_publication_lock();
    if SYNC_GENERATION.load(Ordering::SeqCst) == generation {
        notify_sync_event(event);
    }
}

/// Lock the sync-publication mutex, recovering from a poisoned lock so a
/// panic in the (tiny, atomic-only) critical section can never wedge all
/// sync state publication forever.
fn sync_publication_lock() -> std::sync::MutexGuard<'static, ()> {
    SYNC_PUBLICATION_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

// ── Event bus for real-time updates ─────────────────────────────────

/// Events pushed from Rust → Dart when something changes.
#[derive(Clone, Debug)]
pub enum SyncEvent {
    /// A sync cycle completed (rooms may have new messages).
    SyncCompleted,
    /// Specific sync events were dropped; all interested views must refresh.
    FullRefreshRequired,
    /// Room-list metadata changed without requiring a timeline refresh.
    RoomListChanged,
    /// A message was sent (room list should refresh).
    MessageSent { room_id: String },
    /// A room's pinned-event state changed.
    PinnedMessagesChanged { room_id: String },
    /// A room's membership state changed.
    RoomMembersChanged { room_id: String },
    /// The account's ignored-user list changed.
    IgnoredUsersChanged,
}

static SYNC_EVENT_TX: Lazy<tokio::sync::broadcast::Sender<SyncEvent>> = Lazy::new(|| {
    // Generous capacity: a large catch-up sync (reconnect, cold start) can
    // emit one MessageSent per message-like event, and a lagging Dart side
    // must not force a FullRefreshRequired storm on every such burst.
    let (tx, _rx) = tokio::sync::broadcast::channel(512);
    tx
});

type MutationFuture = Shared<BoxFuture<'static, Result<(), String>>>;
type LifecycleProtection = Arc<tokio::sync::RwLockReadGuard<'static, ()>>;

/// The caller-side timeout message of `run_bounded_mutation`. Kept as a
/// single constant because `mark_room_as_read` distinguishes the queue-wait
/// timeout (the clear never ran and keeps running in the background) from a
/// genuine clear failure by comparing against this exact string — a
/// reworded message would otherwise turn "still running" into a bogus
/// "failed, retry".
const MUTATION_TIMEOUT_MESSAGE: &str = "操作超时，请稍后查看最终状态。";

/// Error surfaced when a mutation key's queue is already at its depth
/// limit: the operation was rejected outright instead of chaining. Distinct
/// from MUTATION_TIMEOUT_MESSAGE ("still running in the background") so the
/// Dart side can tell the two apart.
const MUTATION_QUEUE_FULL_MESSAGE: &str = "操作排队已满，请稍后重试。";

/// Maximum operations chained on a single mutation key (1 running + 2
/// queued). Every chained operation holds a share of the SYNC_LIFECYCLE
/// read lease from enqueue until completion, so an unbounded chain under a
/// bad server (user retries stacking up) would stall logout/account switch
/// — which need the write lock — for minutes. New enqueues are rejected
/// instead of extending the chain beyond this bound.
const MUTATION_QUEUE_MAX_DEPTH: usize = 3;

struct MutationTail {
    id: u64,
    /// Chain depth when this tail was enqueued: 1 for the running
    /// operation, +1 per queued successor. Stays monotonic along the chain
    /// (a completing predecessor does not decrement it), so it is an upper
    /// bound on the remaining chain length — exactly what the depth limit
    /// needs to reject a new enqueue.
    depth: usize,
    future: MutationFuture,
}

static MUTATION_TAILS: Lazy<std::sync::Mutex<HashMap<String, MutationTail>>> =
    Lazy::new(|| std::sync::Mutex::new(HashMap::new()));
static NEXT_MUTATION_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy)]
struct MarkedUnreadOverride {
    baseline: bool,
    desired: bool,
    /// When the override was created. `{baseline:true, desired:false}`
    /// (a clear in flight) must survive the pending `true` echo of the
    /// cleared flag — but only for a short window: a *new* `true` set by
    /// another device after the clear must not be suppressed forever. The
    /// TTL bounds the suppression window; afterwards a matching echo is
    /// treated as a fresh server state and the override is dropped.
    /// The TTL is equally load-bearing in the other direction
    /// (`{baseline:false, desired:true}`, a mark-unread in flight): if the
    /// write failed there is no echo for `reconcile` to drop the override
    /// on, so without the TTL a failed mark would show unread forever.
    /// The echo-side latency this exposes (up to TTL + echo delay the
    /// display shows the pre-echo state) is the accepted price for that
    /// bound.
    created_at: std::time::Instant,
}

const MARKED_UNREAD_OVERRIDE_TTL: std::time::Duration = std::time::Duration::from_secs(30);

static MARKED_UNREAD_OVERRIDES: Lazy<RwLock<HashMap<String, MarkedUnreadOverride>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

#[derive(Clone, Copy)]
struct IgnoredUserOverride {
    baseline: bool,
    desired: bool,
    /// Set when an ignored-list event arrived that did not contain this
    /// target. After the TTL the override expires (ABA protection: a
    /// cross-device un-ignore may have coalesced the list back to the
    /// pre-write baseline). None while no event has been seen, so an offline
    /// window — the exact case overrides exist for — never expires them.
    event_seen: Option<std::time::Instant>,
}

/// How long an ignore override survives after an account-data event that
/// does not confirm its target, before the authoritative store wins.
const IGNORED_OVERRIDE_TTL: std::time::Duration = std::time::Duration::from_secs(30);

fn ignored_override_expired(local: &IgnoredUserOverride) -> bool {
    local
        .event_seen
        .is_some_and(|seen| seen.elapsed() >= IGNORED_OVERRIDE_TTL)
}

/// Per-account ignored-user overrides for locally confirmed writes whose
/// account-data echo has not synced yet: `set_account_data` does not update
/// the SDK state store, so `Client::is_user_ignored` would keep serving the
/// pre-write value and room previews would stay visible until the echo (or
/// indefinitely, if connectivity drops first).
static IGNORED_USER_OVERRIDES: Lazy<RwLock<HashMap<String, IgnoredUserOverride>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

/// Per-account notification-settings handles. Reusing one instance matters:
/// it applies its own writes to its internal ruleset, while a fresh instance
/// initializes from the local store copy of push rules, which lags the sync
/// echo and can turn a rapid mute/unmute/re-mute sequence into a no-op.
static NOTIFICATION_SETTINGS: Lazy<
    RwLock<HashMap<String, matrix_sdk::notification_settings::NotificationSettings>>,
> = Lazy::new(|| RwLock::new(HashMap::new()));

async fn notification_settings_for(
    client: &Client,
    user_id: &str,
    expected_instance_id: Option<u64>,
) -> matrix_sdk::notification_settings::NotificationSettings {
    // Key by (user_id, instance_id) so a restored/replaced client can never
    // reuse the old client's handle. Queue-tail callers pass the instance id
    // their own guard captured, so the key always matches the client the
    // settings were built from.
    let instance_id = match expected_instance_id {
        Some(id) => Some(id),
        None => CLIENTS
            .read()
            .await
            .get(user_id)
            .map(|entry| entry.instance_id),
    };
    let cache_key = match instance_id {
        Some(id) => format!("{user_id}:{id}"),
        None => user_id.to_string(),
    };
    if let Some(settings) = NOTIFICATION_SETTINGS.read().await.get(&cache_key) {
        return settings.clone();
    }
    let settings = client.notification_settings().await;
    NOTIFICATION_SETTINGS
        .write()
        .await
        .entry(cache_key)
        .or_insert(settings)
        .clone()
}

/// Request configuration for user-initiated operations.
///
/// The SDK default already has a 30s per-request timeout and does not retry
/// network failures, but it retries transient server errors (5xx/429)
/// indefinitely, bounded only by a 15-minute total delay — a server stuck in
/// an error loop would leave a P0 operation (leave, invite, rename, mute,
/// pin, read markers, ignore, knock) spinning without feedback for minutes.
/// `retry_limit(3)` caps that at three attempts (~93s worst case with
/// backoff, matching the 90s call-side bounds closely), at the cost of also
/// retrying network failures up to twice — a bounded, user-visible failure
/// either way (an operation that outlives the call-side bound keeps running
/// in its background queue task). Sliding Sync builds its own request config
/// and is unaffected. Media uploads inherit the retry limit but override the
/// timeout by size; media downloads also inherit the retry limit (their
/// timeout is lifted to unlimited) — a flaky-network large download fails
/// after three attempts instead of retrying forever.
fn bounded_request_config() -> RequestConfig {
    RequestConfig::new()
        .timeout(std::time::Duration::from_secs(30))
        .retry_limit(3)
}

const MEDIA_DOWNLOAD_TOTAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);
const MEDIA_SEND_TOTAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(600);
const MEDIA_EVENT_SEND_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(90);

/// Drop per-account runtime state whenever a client is removed or replaced
/// (logout, account removal, or login replacing an existing client), so a
/// later session never reuses state bound to the old client or sync position.
async fn clear_account_runtime_state(user_id: &str) {
    {
        // Prefix match: since the instance-keyed change, entries are
        // `{user_id}:{instance_id}` (the bare `{user_id}` key survives from
        // before the change).
        let mut settings = NOTIFICATION_SETTINGS.write().await;
        settings.retain(|key, _| key != user_id && !key.starts_with(&format!("{user_id}:")));
    }
    {
        let mut overrides = MARKED_UNREAD_OVERRIDES.write().await;
        overrides.retain(|key, _| !key.starts_with(&format!("{user_id}:")));
    }
    {
        let mut overrides = IGNORED_USER_OVERRIDES.write().await;
        overrides.retain(|key, _| !key.starts_with(&format!("{user_id}:")));
    }
    // Queued mutations for this account (keys are `{kind}:{user_id}:...`,
    // `ignored:{user_id}`, or the room-scoped `pinned:{room_id}` shared
    // across accounts) are deliberately NOT dropped. Their background tails
    // retain lifecycle read protection until completion, so teardown drains
    // them before revoking the session or deleting its store. Keeping the
    // queue entries also preserves serialization with any successor.
    // Note: Matrix user IDs contain a colon (`@alice:example.org`), so the
    // kind must be split off with `split_once`, never by splitting the whole
    // key on colons.
}

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

/// Queue-wait timeout for mutations sharing a key (seconds). Test overrides
/// this so they do not wait the real 30s.
static MUTATION_WAIT_TIMEOUT_SECS: AtomicU64 = AtomicU64::new(30);

/// Hard total bound on a queued operation's EXECUTION inside the background
/// tail (seconds). The caller-side 90s of `run_bounded_mutation` only bounds
/// the caller; the tail keeps running the operation afterwards, and a
/// multi-request operation (e.g. the DM reuse scan in `create_dm`, one
/// `members()` call per candidate room, each bounded only by the ~93s HTTP
/// budget) could otherwise hold its SYNC_LIFECYCLE read share — and the
/// queue slot successors wait on — for many minutes, stalling logout and
/// account switch. On expiry the operation future is dropped (releasing the
/// lease), the tail completes with an error, and the cleanup hook frees the
/// queue entry. Atomic so tests can shorten it (see mutation_queue_tests).
static MUTATION_EXECUTION_TIMEOUT_SECS: AtomicU64 = AtomicU64::new(300);

// Used by the mutation-queue tests; production callers go through
// `run_bounded_mutation` / `run_bounded_mutation_undroppable`, which pick
// the drop behavior explicitly.
#[cfg(test)]
async fn enqueue_mutation<F, T>(key: String, operation: F) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    enqueue_mutation_inner(key, operation, true).await
}

/// `drop_on_execution_timeout`: see MUTATION_EXECUTION_TIMEOUT_SECS.
/// Operations whose server-side effect is neither idempotent nor verifiable
/// on retry (currently only `create_dm`) pass false: dropping their tail
/// mid-flight can orphan server-side state the client never learns about,
/// so they bound their duration internally instead of being dropped.
async fn enqueue_mutation_inner<F, T>(
    key: String,
    operation: F,
    drop_on_execution_timeout: bool,
) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    let id = NEXT_MUTATION_ID.fetch_add(1, Ordering::Relaxed);
    let log_key = key.clone();
    let future = {
        let mut tails = MUTATION_TAILS
            .lock()
            .map_err(|_| api_err("mutation", "操作队列不可用，请重试。".to_string()))?;
        let previous = tails
            .get(&key)
            .map(|tail| (tail.future.clone(), tail.depth));
        // Bound the chain length (see MUTATION_QUEUE_MAX_DEPTH): each
        // chained operation holds a share of the SYNC_LIFECYCLE read lease
        // from enqueue until completion, so an unbounded chain would let a
        // bad server + user retries stall logout/account switch for minutes.
        // Reject the excess instead of extending the chain past
        // 1 running + 2 queued.
        if previous
            .as_ref()
            .is_some_and(|(_, depth)| *depth >= MUTATION_QUEUE_MAX_DEPTH)
        {
            return Err(api_err("mutation", MUTATION_QUEUE_FULL_MESSAGE.to_string()));
        }
        let depth = previous.as_ref().map_or(1, |(_, depth)| depth + 1);
        let previous = previous.map(|(future, _)| future);
        let future = std::panic::AssertUnwindSafe(async move {
            if let Some(previous) = previous {
                // The SDK's HTTP timeout (see bounded_request_config) bounds
                // a single request at ~93s (3 attempts with backoff), but
                // several operations can still back up behind a slow one.
                // State mutations are server-side read-modify-writes:
                // running two
                // concurrently would make one overwrite the other (lost
                // pins, resurrected ignored users).
                let wait_timeout = std::time::Duration::from_secs(
                    MUTATION_WAIT_TIMEOUT_SECS.load(Ordering::Relaxed),
                );
                if tokio::time::timeout(wait_timeout, previous.clone())
                    .await
                    .is_err()
                {
                    // The predecessor outlived the queue wait. Never run
                    // concurrently with it (state mutations are server-side
                    // read-modify-writes), and keep this entry chained so
                    // successors still serialize behind the chain — but once
                    // the predecessor finishes (it is itself bounded by the
                    // HTTP timeout), running our own operation is serial-safe
                    // and honors the user's latest intent. Only when the
                    // predecessor still has not finished do we give up: wait
                    // for it (bounded by the HTTP timeout) so this entry
                    // completes only after the predecessor, keeping
                    // successors chained on it serialized — completing early
                    // would release them to run concurrently with the
                    // in-flight predecessor.
                    app_log(
                        "warn",
                        "mutation",
                        format!(
                            "Mutation queue wait timed out for key {log_key}; waiting for the predecessor to finish."
                        ),
                    );
                    if tokio::time::timeout(std::time::Duration::from_secs(120), previous.clone())
                        .await
                        .is_err()
                    {
                        app_log(
                            "warn",
                            "mutation",
                            format!(
                                "Predecessor for key {log_key} still running; waiting for it to finish before running this operation."
                            ),
                        );
                        // Wait for the predecessor before running our own
                        // operation: this entry must not execute while the
                        // predecessor is still running, or successors chained
                        // on it would run concurrently with it (both
                        // server-side read-modify-writes). The bound is the
                        // predecessor's own completion (its requests are
                        // individually bounded by the HTTP timeout; a chained
                        // queue can accumulate across several predecessors).
                        // Dropping the operation here would silently lose the
                        // user's latest intent AND contradict the caller-side
                        // "操作超时，仍在后台执行" wording (the operation
                        // never ran) — so run it once the predecessor is
                        // done, exactly like the 120s branch.
                        let _ = previous.await;
                    }
                }
            }
            // The execution itself is hard-bounded: the caller-side 90s of
            // `run_bounded_mutation` does not constrain this background tail,
            // so without a total bound a multi-request operation (N rooms x
            // the ~93s HTTP budget) could pin the queue — and its share of
            // the SYNC_LIFECYCLE read lease — for many minutes. On expiry the
            // operation future is dropped: the lease is released, the tail
            // completes with an error, and the cleanup hook frees the queue
            // entry so successors are not stuck behind a dead operation.
            // Non-idempotent operations opt out: dropping their tail
            // mid-flight can orphan server-side state the client never
            // learns about (a created DM room whose response was lost —
            // the retry's reuse scan cannot see it until sync delivers it),
            // so they bound their duration internally instead.
            if !drop_on_execution_timeout {
                return operation.await;
            }
            let execution_timeout = std::time::Duration::from_secs(
                MUTATION_EXECUTION_TIMEOUT_SECS.load(Ordering::Relaxed),
            );
            match tokio::time::timeout(execution_timeout, operation).await {
                Ok(result) => result,
                Err(_) => {
                    app_log(
                        "warn",
                        "mutation",
                        format!(
                            "Mutation for key {log_key} exceeded the total execution bound; dropping it to release the queue."
                        ),
                    );
                    Err("操作超时，请重试。".to_string())
                }
            }
        })
        // A panicking predecessor (or operation) would otherwise unwind
        // through this future, skipping the tail cleanup below and leaving a
        // stale queue entry that panics every successor. Catch it and turn
        // it into a regular error so cleanup always runs.
        .catch_unwind()
        .map(|result| result.unwrap_or_else(|_| Err(api_err("mutation", "操作执行异常，请重试。".to_string()))))
        .boxed()
        .shared();
        // Chain on a unit-typed projection so operations with different
        // payload types can share one queue per key. The cleanup is part of
        // the tail itself: it runs when the operation finishes regardless of
        // whether the caller is still awaiting (a caller that times out in
        // `run_bounded_mutation` drops its future — without the spawn below
        // the shared future would freeze un-polled, and without this cleanup
        // the tail would linger forever).
        let cleanup_id = id;
        let cleanup_key = key.clone();
        let tail_future = future
            .clone()
            .map(move |result| {
                if let Ok(mut tails) = MUTATION_TAILS.lock() {
                    if tails
                        .get(&cleanup_key)
                        .is_some_and(|tail| tail.id == cleanup_id)
                    {
                        tails.remove(&cleanup_key);
                    }
                }
                result.map(|_| ())
            })
            .boxed()
            .shared();
        tails.insert(
            key.clone(),
            MutationTail {
                id,
                depth,
                future: tail_future.clone(),
            },
        );
        // Drive the shared future in the background: `Shared` only polls its
        // inner future while at least one clone is being awaited, so a
        // caller that drops its clone (timeout) would otherwise freeze the
        // operation mid-flight — and a later successor would revive it,
        // double-applying a non-idempotent toggle (pin/unpin). Drive the
        // tail future (not the raw one) so the cleanup hook always runs.
        tokio::spawn(tail_future.clone());
        future
    };

    future.await
}

/// Enqueue a mutation with a total bound on the caller's side. The queue
/// itself stays correct after a timeout (the tail keeps running to
/// completion under its share of the client lease), but the caller must not
/// wait unboundedly: the queue wait alone can reach 30s + 120s, plus the
/// operation's own HTTP attempts.
async fn run_bounded_mutation<F, T>(
    key: String,
    lifecycle_protection: LifecycleProtection,
    operation: F,
) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    run_bounded_mutation_inner(key, lifecycle_protection, operation, true).await
}

/// Variant of [`run_bounded_mutation`] for operations whose server-side
/// effect is neither idempotent nor verifiable on retry (currently only
/// `create_dm`): the tail must NOT be dropped on the execution timeout —
/// a dropped create can orphan a room whose response never arrived, and
/// the retry's reuse scan cannot see it until sync delivers it (a duplicate
/// DM). The operation must bound its own duration instead (create_dm caps
/// its reuse scan; each request is bounded by bounded_request_config).
async fn run_bounded_mutation_undroppable<F, T>(
    key: String,
    lifecycle_protection: LifecycleProtection,
    operation: F,
) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    run_bounded_mutation_inner(key, lifecycle_protection, operation, false).await
}

async fn run_bounded_mutation_inner<F, T>(
    key: String,
    lifecycle_protection: LifecycleProtection,
    operation: F,
    drop_on_execution_timeout: bool,
) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    // Move a share of the caller's lifecycle lease into the queued operation
    // itself. When the caller times out, the spawned tail can keep using its
    // Client/Room safely while logout or account removal waits for this share.
    let protected_operation = async move {
        let _lifecycle_protection = lifecycle_protection;
        operation.await
    };
    tokio::time::timeout(
        std::time::Duration::from_secs(90),
        enqueue_mutation_inner(key, protected_operation, drop_on_execution_timeout),
    )
    .await
    .map_err(|_| api_err("mutation", MUTATION_TIMEOUT_MESSAGE.to_string()))?
}

/// Total bound for a non-queued P0 write. These hold the client lease
/// (blocking logout/account switch) for their whole duration, and each
/// request inside is individually bounded by `bounded_request_config` — but
/// multi-request operations (name+topic, upload+state, verify+invite)
/// could otherwise hold the lease for minutes.
async fn run_bounded<F, T>(operation: F) -> Result<T, String>
where
    F: Future<Output = Result<T, String>> + Send + 'static,
    T: Clone + Send + Sync + 'static,
{
    tokio::time::timeout(std::time::Duration::from_secs(90), operation)
        .await
        .map_err(|_| api_err("mutation", "操作超时，请重试。".to_string()))?
}

async fn synced_marked_unread(room: &Room) -> bool {
    room.account_data_static::<matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent>()
        .await
        .ok()
        .flatten()
        .and_then(|raw| raw.deserialize().ok())
        .is_some_and(|event| event.content.unread)
}

fn marked_unread_override_key(client: &Client, room: &Room) -> Option<String> {
    client
        .user_id()
        .map(|user_id| format!("{user_id}:{}", room.room_id()))
}

fn resolve_marked_unread(synced: bool, local: Option<MarkedUnreadOverride>) -> (bool, bool) {
    match local {
        // A fresh override matching the synced value is effective. A
        // `{baseline:true, desired:false}` clear in flight must ALSO be
        // effective while the store still reads false — the window between
        // issuing the clear and the pending `true` echo of the cleared
        // flag. Without this, the first read in that window would drop the
        // override as stale (synced != baseline) and the pending `true`
        // echo would briefly resurrect the unread marker. The TTL still
        // bounds the whole suppression: an expired override is stale
        // regardless of the synced value — a `true` arriving long after a
        // clear was issued is a *new* cross-device mark that must not be
        // suppressed for the rest of the session.
        Some(local)
            if local.created_at.elapsed() <= MARKED_UNREAD_OVERRIDE_TTL
                && (synced == local.baseline || (local.baseline && !local.desired && !synced)) =>
        {
            (local.desired, false)
        }
        Some(_) => (synced, true),
        None => (synced, false),
    }
}

async fn effective_marked_unread(client: &Client, room: &Room) -> bool {
    let synced = synced_marked_unread(room).await;
    let Some(key) = marked_unread_override_key(client, room) else {
        return synced;
    };
    let mut overrides = MARKED_UNREAD_OVERRIDES.write().await;
    let (effective, stale) = resolve_marked_unread(synced, overrides.get(&key).copied());
    if stale {
        overrides.remove(&key);
    }
    effective
}

async fn set_marked_unread_override(key: String, baseline: bool, desired: bool) {
    let mut overrides = MARKED_UNREAD_OVERRIDES.write().await;
    if baseline == desired {
        overrides.remove(&key);
    } else {
        overrides.insert(
            key,
            MarkedUnreadOverride {
                baseline,
                desired,
                created_at: std::time::Instant::now(),
            },
        );
    }
}

fn reconcile_marked_unread_override(
    overrides: &mut HashMap<String, MarkedUnreadOverride>,
    key: &str,
    synced: bool,
) {
    // The override lives until the synced value reaches its baseline (the
    // state it was snapshot against); a different synced value means the
    // snapshot is stale. Crucially, a `{baseline:true, desired:false}`
    // override (a clear in flight) must survive the pending `true` echo —
    // synced == baseline — to keep suppressing the marker until the `false`
    // echo arrives. The TTL bounds that suppression: a `true` arriving long
    // after the clear was issued is a *new* cross-device mark, not the
    // pending echo, and must not be hidden for the rest of the session.
    if overrides.get(key).is_some_and(|local| {
        synced != local.baseline || local.created_at.elapsed() > MARKED_UNREAD_OVERRIDE_TTL
    }) {
        overrides.remove(key);
    }
}

fn ignored_user_override_key(client: &Client, target: &matrix_sdk::ruma::UserId) -> Option<String> {
    client
        .user_id()
        .map(|user_id| format!("{user_id}:{target}"))
}

fn resolve_ignored_user(synced: bool, local: Option<IgnoredUserOverride>) -> (bool, bool) {
    match local {
        Some(local) if synced == local.baseline => (local.desired, false),
        Some(_) => (synced, true),
        None => (synced, false),
    }
}

/// Effective ignored state for previews: while the state store still shows
/// the baseline of a confirmed write, report the confirmed value; once the
/// echo (or any newer server state) advances the store, the store wins and
/// the stale override is dropped.
async fn effective_is_user_ignored(client: &Client, target: &matrix_sdk::ruma::UserId) -> bool {
    let synced = client.is_user_ignored(target).await;
    let Some(key) = ignored_user_override_key(client, target) else {
        return synced;
    };
    let mut overrides = IGNORED_USER_OVERRIDES.write().await;
    if overrides.get(&key).is_some_and(ignored_override_expired) {
        overrides.remove(&key);
    }
    let (effective, stale) = resolve_ignored_user(synced, overrides.get(&key).copied());
    if stale {
        overrides.remove(&key);
    }
    effective
}

async fn set_ignored_user_override(key: String, baseline: bool, desired: bool) {
    let mut overrides = IGNORED_USER_OVERRIDES.write().await;
    if baseline == desired {
        overrides.remove(&key);
    } else {
        overrides.insert(
            key,
            IgnoredUserOverride {
                baseline,
                desired,
                event_seen: None,
            },
        );
    }
}

fn merge_ignored_user_overrides(
    account_prefix: &str,
    content: &mut IgnoredUserListEventContent,
    overrides: &mut HashMap<String, IgnoredUserOverride>,
) {
    overrides.retain(|key, local| {
        let Some(target) = key.strip_prefix(account_prefix) else {
            return true;
        };
        let Ok(user_id) = matrix_sdk::ruma::OwnedUserId::try_from(target) else {
            return false;
        };
        if ignored_override_expired(local) {
            return false;
        }
        let synced = content.ignored_users.contains_key(&user_id);
        let (effective, stale) = resolve_ignored_user(synced, Some(*local));
        if effective {
            content.ignored_users.insert(user_id, IgnoredUser::new());
        } else {
            content.ignored_users.remove(&user_id);
        }
        !stale
    })
}

async fn merge_current_account_ignored_user_overrides(
    client: &Client,
    content: &mut IgnoredUserListEventContent,
) {
    let Some(account_prefix) = client.user_id().map(|user_id| format!("{user_id}:")) else {
        return;
    };
    let mut overrides = IGNORED_USER_OVERRIDES.write().await;
    merge_ignored_user_overrides(&account_prefix, content, &mut overrides);
}

/// Reconcile ignored-user overrides against an authoritative account-data
/// event. The event proves the server list advanced past every local write:
///
/// - A target that IS in the received content was decided by the server
///   (echo or a cross-device change); its override is stale either way.
/// - A target that is NOT in the content, with `desired=false` (an
///   un-ignore), was confirmed by the server; its override is stale.
/// - A target that is NOT in the content, with `desired=true` (an ignore),
///   may still be awaiting its echo (the snapshot predates our write, e.g.
///   a concurrent write to a different target synced first). It is kept,
///   but its `event_seen` timestamp is set so the TTL expires it in the
///   ABA case where a cross-device un-ignore coalesced the list back to
///   the pre-write baseline. Overrides for other accounts are untouched.
///
/// Without the TTL an override whose target is no room's latest sender
/// would never be read, never expire, and would keep hiding previews after
/// another device un-ignores the user.
fn reconcile_ignored_user_overrides_inner(
    account_prefix: &str,
    content: &IgnoredUserListEventContent,
    overrides: &mut HashMap<String, IgnoredUserOverride>,
) {
    overrides.retain(|key, local| {
        let Some(target) = key.strip_prefix(account_prefix) else {
            // Belongs to another account; leave it untouched.
            return true;
        };
        let Ok(user_id) = matrix_sdk::ruma::UserId::parse(target) else {
            return false;
        };
        if content.ignored_users.contains_key(&user_id) || !local.desired {
            return false;
        }
        if ignored_override_expired(local) {
            return false;
        }
        // Start the TTL clock on the first event that does not confirm the
        // target. Do NOT refresh it on every event: global account data is
        // delivered on each sync response even when unchanged, so refreshing
        // would keep the override alive forever in the ABA case (a
        // cross-device un-ignore that coalesces the list back to baseline).
        if local.event_seen.is_none() {
            local.event_seen = Some(std::time::Instant::now());
        }
        true
    });
}

async fn reconcile_ignored_user_overrides(client: &Client, content: &IgnoredUserListEventContent) {
    let Some(account_prefix) = client.user_id().map(|user_id| format!("{user_id}:")) else {
        return;
    };
    let mut overrides = IGNORED_USER_OVERRIDES.write().await;
    reconcile_ignored_user_overrides_inner(&account_prefix, content, &mut overrides);
}

#[cfg(test)]
mod mutation_queue_tests {
    use super::{
        clear_account_runtime_state, enqueue_mutation, merge_ignored_user_overrides,
        reconcile_ignored_user_overrides_inner, reconcile_marked_unread_override,
        resolve_ignored_user, resolve_marked_unread, run_bounded_mutation, IgnoredUserOverride,
        MarkedUnreadOverride, MUTATION_EXECUTION_TIMEOUT_SECS, MUTATION_QUEUE_FULL_MESSAGE,
        MUTATION_TAILS, MUTATION_WAIT_TIMEOUT_SECS,
    };
    use matrix_sdk::ruma::events::ignored_user_list::{IgnoredUser, IgnoredUserListEventContent};
    use std::sync::atomic::Ordering;
    use std::{
        collections::HashMap,
        sync::{Arc, Mutex},
    };
    use tokio::sync::oneshot;

    /// Serializes the timeout tests, which override the global
    /// MUTATION_WAIT_TIMEOUT_SECS and must not run concurrently. Tokio mutex
    /// so the guard may be held across awaits without clippy warnings.
    static TEST_TIMEOUT_LOCK: super::Lazy<tokio::sync::Mutex<()>> =
        super::Lazy::new(|| tokio::sync::Mutex::new(()));

    /// Restores MUTATION_WAIT_TIMEOUT_SECS on drop, even when a test
    /// assertion panics mid-way.
    struct TimeoutOverrideGuard;
    impl TimeoutOverrideGuard {
        fn acquire() -> Self {
            MUTATION_WAIT_TIMEOUT_SECS.store(1, Ordering::Relaxed);
            TimeoutOverrideGuard
        }
    }
    impl Drop for TimeoutOverrideGuard {
        fn drop(&mut self) {
            MUTATION_WAIT_TIMEOUT_SECS.store(30, Ordering::Relaxed);
        }
    }

    /// Restores MUTATION_EXECUTION_TIMEOUT_SECS on drop, even when a test
    /// assertion panics mid-way.
    struct ExecutionTimeoutOverrideGuard;
    impl ExecutionTimeoutOverrideGuard {
        fn acquire() -> Self {
            MUTATION_EXECUTION_TIMEOUT_SECS.store(1, Ordering::Relaxed);
            ExecutionTimeoutOverrideGuard
        }
    }
    impl Drop for ExecutionTimeoutOverrideGuard {
        fn drop(&mut self) {
            MUTATION_EXECUTION_TIMEOUT_SECS.store(300, Ordering::Relaxed);
        }
    }

    #[tokio::test]
    async fn serializes_mutations_with_the_same_key() {
        let key = format!("test:{}", std::process::id());
        let order = Arc::new(Mutex::new(Vec::new()));
        let first_order = order.clone();
        let (release_first, wait_for_release) = oneshot::channel();
        let (first_started, wait_for_first) = oneshot::channel();
        let first_key = key.clone();
        let first = tokio::spawn(async move {
            enqueue_mutation(first_key, async move {
                first_order.lock().unwrap().push(1);
                let _ = first_started.send(());
                let _ = wait_for_release.await;
                Ok(())
            })
            .await
        });

        wait_for_first.await.unwrap();

        let second_order = order.clone();
        let second = tokio::spawn(async move {
            enqueue_mutation(key, async move {
                second_order.lock().unwrap().push(2);
                Ok(())
            })
            .await
        });

        tokio::task::yield_now().await;
        assert_eq!(*order.lock().unwrap(), [1]);

        let _ = release_first.send(());
        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        assert_eq!(*order.lock().unwrap(), [1, 2]);
    }

    #[tokio::test]
    async fn dropped_mutation_waiter_retains_lifecycle_until_tail_finishes() {
        let lifecycle = Box::leak(Box::new(tokio::sync::RwLock::new(())));
        let protection = Arc::new(lifecycle.read().await);
        let key = format!("test-lifecycle:{}", std::process::id());
        let (release, wait_for_release) = oneshot::channel();
        let (started, wait_for_start) = oneshot::channel();

        let caller = tokio::spawn(run_bounded_mutation(key, protection, async move {
            let _ = started.send(());
            let _ = wait_for_release.await;
            Ok(())
        }));
        wait_for_start.await.unwrap();

        // Cancel the caller just as the 90s wrapper does on timeout. The
        // spawned queue tail must still hold the lifecycle read protection.
        caller.abort();
        let _ = caller.await;
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), lifecycle.write())
                .await
                .is_err()
        );

        let _ = release.send(());
        let _write_guard =
            tokio::time::timeout(std::time::Duration::from_secs(1), lifecycle.write())
                .await
                .expect("tail should release lifecycle protection");
    }

    #[tokio::test]
    async fn timed_out_queue_wait_fails_instead_of_racing() {
        // The two timeout tests share the global MUTATION_WAIT_TIMEOUT_SECS
        // override, so they must not run concurrently.
        let _timeout_lock = TEST_TIMEOUT_LOCK.lock().await;
        let _timeout_override = TimeoutOverrideGuard::acquire();
        let key = format!("test-timeout:{}", std::process::id());
        let (release_first, wait_for_release) = oneshot::channel();
        let (first_started, wait_for_first) = oneshot::channel();
        let first_key = key.clone();
        let first = tokio::spawn(async move {
            enqueue_mutation(first_key, async move {
                let _ = first_started.send(());
                let _ = wait_for_release.await;
                Ok(())
            })
            .await
        });

        wait_for_first.await.unwrap();

        let order = Arc::new(Mutex::new(Vec::new()));
        let second_order = order.clone();
        let second = tokio::spawn(async move {
            enqueue_mutation(key, async move {
                second_order.lock().unwrap().push(2);
                Ok(())
            })
            .await
        });

        // Wait past the 1s queue-wait timeout: the second mutation refuses
        // to run concurrently, but its queue entry stays chained on the
        // (bounded) first mutation, so it must not complete yet either.
        tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
        assert!(!second.is_finished());
        assert_eq!(*order.lock().unwrap(), Vec::<i32>::new());

        // Once the first mutation finishes, the second runs its own
        // operation: serial-safe by then, and it honors the user's latest
        // intent instead of dropping it.
        let _ = release_first.send(());
        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        assert_eq!(*order.lock().unwrap(), [2]);
    }

    #[tokio::test]
    async fn timed_out_waiter_keeps_successors_serialized_behind_the_predecessor() {
        let _timeout_lock = TEST_TIMEOUT_LOCK.lock().await;
        let _timeout_override = TimeoutOverrideGuard::acquire();
        let key = format!("test-restore:{}", std::process::id());
        let (release_first, wait_for_release) = oneshot::channel();
        let (first_started, wait_for_first) = oneshot::channel();
        let first_key = key.clone();
        let first = tokio::spawn(async move {
            enqueue_mutation(first_key, async move {
                let _ = first_started.send(());
                let _ = wait_for_release.await;
                Ok(())
            })
            .await
        });

        wait_for_first.await.unwrap();

        // B queues behind A; C queues behind B.
        let second_key = key.clone();
        let second =
            tokio::spawn(async move { enqueue_mutation(second_key, async move { Ok(()) }).await });
        let third_key = key.clone();
        let order = Arc::new(Mutex::new(Vec::new()));
        let third_order = order.clone();
        let third = tokio::spawn(async move {
            enqueue_mutation(third_key, async move {
                third_order.lock().unwrap().push(3);
                Ok(())
            })
            .await
        });

        // After B's wait times out, neither B nor C may complete: B stays
        // chained on the still-running A, and C stays chained on B. Letting
        // B complete would release C to run concurrently with A (both
        // server-side read-modify-writes racing each other).
        tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
        assert!(!second.is_finished());
        assert!(!third.is_finished());
        assert_eq!(*order.lock().unwrap(), Vec::<i32>::new());

        // Once A finishes, B (then C) runs their own operations in queue
        // order — serial-safe, never concurrent with A.
        let _ = release_first.send(());
        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        third.await.unwrap().unwrap();
        assert_eq!(*order.lock().unwrap(), [3]);
    }

    #[tokio::test]
    async fn account_runtime_cleanup_keeps_inflight_mutations_serialized() {
        let (release_me, wait_me) = oneshot::channel();
        let (started_me, wait_started_me) = oneshot::channel();
        let my_key = "muted:@me:example.org:!room:example.org".to_string();
        let my_task = tokio::spawn({
            let key = my_key.clone();
            async move {
                enqueue_mutation(key, async move {
                    let _ = started_me.send(());
                    let _ = wait_me.await;
                    Ok(())
                })
                .await
            }
        });
        wait_started_me.await.unwrap();

        // Account cleanup (logout/removal) must NOT drop the in-flight tail:
        // after a same-account relogin, a new operation on the same key must
        // still serialize behind the running one — removing the tail would
        // let both run concurrently as server-side read-modify-writes.
        clear_account_runtime_state("@me:example.org").await;

        let order = Arc::new(Mutex::new(Vec::new()));
        let second_order = order.clone();
        let second = tokio::spawn({
            let key = my_key.clone();
            async move {
                enqueue_mutation(key, async move {
                    second_order.lock().unwrap().push(2);
                    Ok(())
                })
                .await
            }
        });

        // The successor must not run while the in-flight operation is still
        // pending.
        tokio::task::yield_now().await;
        assert_eq!(*order.lock().unwrap(), Vec::<i32>::new());

        let _ = release_me.send(());
        my_task.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        assert_eq!(*order.lock().unwrap(), [2]);
    }

    #[tokio::test]
    async fn overlong_queue_chains_are_rejected() {
        let key = format!("test-depth:{}", std::process::id());
        let (release_first, wait_for_release) = oneshot::channel();
        let (first_started, wait_for_first) = oneshot::channel();
        let first_key = key.clone();
        let first = tokio::spawn(async move {
            enqueue_mutation(first_key, async move {
                let _ = first_started.send(());
                let _ = wait_for_release.await;
                Ok(())
            })
            .await
        });

        wait_for_first.await.unwrap();

        // Fill the queue up to the depth limit (1 running + 2 queued).
        let second_key = key.clone();
        let second =
            tokio::spawn(async move { enqueue_mutation(second_key, async move { Ok(()) }).await });
        let third_key = key.clone();
        let third =
            tokio::spawn(async move { enqueue_mutation(third_key, async move { Ok(()) }).await });

        // Wait until both successors have actually chained (tail depth 3).
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                let depth = MUTATION_TAILS
                    .lock()
                    .map(|tails| tails.get(&key).map_or(0, |tail| tail.depth))
                    .unwrap_or(0);
                if depth >= 3 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("successors should chain onto the running mutation");

        // A fourth operation for the same key is rejected outright instead
        // of extending the chain: every chained operation holds a share of
        // the SYNC_LIFECYCLE read lease, so an unbounded chain would stall
        // logout/account switch behind a backlog.
        let fourth_key = key.clone();
        let fourth =
            tokio::spawn(async move { enqueue_mutation(fourth_key, async move { Ok(()) }).await });
        assert_eq!(
            fourth.await.unwrap().unwrap_err(),
            MUTATION_QUEUE_FULL_MESSAGE.to_string()
        );

        // The queue still drains in order once the running mutation
        // finishes; the rejected fourth operation never ran.
        let _ = release_first.send(());
        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        third.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn overlong_operation_is_dropped_to_release_the_queue() {
        // Shares the global-timeout override discipline with the other
        // timeout tests (TEST_TIMEOUT_LOCK), so they never run concurrently.
        let _timeout_lock = TEST_TIMEOUT_LOCK.lock().await;
        let _execution_timeout_override = ExecutionTimeoutOverrideGuard::acquire();
        let key = format!("test-exec-timeout:{}", std::process::id());
        let (started, wait_started) = oneshot::channel();
        let first_key = key.clone();
        let first = tokio::spawn(async move {
            enqueue_mutation(first_key, async move {
                let _ = started.send(());
                // Never completes on its own: only the tail's total execution
                // bound can end this operation.
                std::future::pending::<()>().await;
                Ok(())
            })
            .await
        });
        wait_started.await.unwrap();

        // The operation outlives the 1s execution bound: the tail drops it,
        // completes with an error, and frees the queue entry — a caller that
        // is still around gets the failure instead of hanging forever.
        let result = tokio::time::timeout(std::time::Duration::from_secs(10), first)
            .await
            .expect("tail should complete once the execution bound expires")
            .unwrap();
        assert_eq!(result, Err("操作超时，请重试。".to_string()));

        // The cleanup hook removes the queue entry (driven by the spawned
        // tail, so poll briefly for it).
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                let removed = MUTATION_TAILS
                    .lock()
                    .map(|tails| !tails.contains_key(&key))
                    .unwrap_or(false);
                if removed {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("dropped operation should free its queue entry");

        // A successor enqueued afterwards runs normally: the queue is not
        // stuck behind the dropped operation.
        let order = Arc::new(Mutex::new(Vec::new()));
        let second_order = order.clone();
        let second = tokio::spawn(async move {
            enqueue_mutation(key, async move {
                second_order.lock().unwrap().push(2);
                Ok(())
            })
            .await
        });
        second.await.unwrap().unwrap();
        assert_eq!(*order.lock().unwrap(), [2]);
    }

    #[test]
    fn marked_unread_override_expires_when_sync_advances() {
        let local = MarkedUnreadOverride {
            baseline: false,
            desired: true,
            created_at: std::time::Instant::now(),
        };
        assert_eq!(resolve_marked_unread(false, Some(local)), (true, false));
        assert_eq!(resolve_marked_unread(true, Some(local)), (true, true));

        let local = MarkedUnreadOverride {
            baseline: true,
            desired: false,
            created_at: std::time::Instant::now(),
        };
        assert_eq!(resolve_marked_unread(true, Some(local)), (false, false));
        // synced=false with a fresh clear-in-flight override: the store can
        // lag the clear (the pending `true` echo of the cleared flag has
        // not landed — or a forced-baseline install where the flag never
        // synced locally). Keeping the override effective (showing read)
        // prevents the pending `true` echo from briefly resurrecting the
        // marker; the reconcile at the `false` echo or the TTL expiry drops
        // it. A genuinely cleared flag displays read either way.
        assert_eq!(resolve_marked_unread(false, Some(local)), (false, false));
    }

    #[test]
    fn marked_unread_event_reconciles_an_aba_override() {
        let key = "@me:example.org:!room:example.org";
        let mut overrides = HashMap::from([(
            key.to_owned(),
            MarkedUnreadOverride {
                baseline: false,
                desired: true,
                created_at: std::time::Instant::now(),
            },
        )]);

        // A sync event is newer than the confirmed local write even when its
        // final boolean coalesces back to the same pre-write value: the
        // synced `true` no longer matches the baseline snapshot `false`.
        reconcile_marked_unread_override(&mut overrides, key, true);

        assert!(!overrides.contains_key(key));
    }

    #[test]
    fn clear_in_flight_override_survives_the_pending_true_echo() {
        let key = "@me:example.org:!room:example.org";
        let mut overrides = HashMap::from([(
            key.to_owned(),
            MarkedUnreadOverride {
                baseline: true,
                desired: false,
                created_at: std::time::Instant::now(),
            },
        )]);

        // A clear was issued while the store lagged; the pending `true` echo
        // matches the override's baseline, so the override must keep
        // suppressing the marker (no unread flicker) until the `false` echo.
        reconcile_marked_unread_override(&mut overrides, key, true);
        assert!(overrides.contains_key(key));

        reconcile_marked_unread_override(&mut overrides, key, false);
        assert!(!overrides.contains_key(key));
    }

    #[test]
    fn ignored_user_override_expires_when_sync_advances() {
        let local = IgnoredUserOverride {
            baseline: false,
            desired: true,
            event_seen: None,
        };
        assert_eq!(resolve_ignored_user(false, Some(local)), (true, false));
        assert_eq!(resolve_ignored_user(true, Some(local)), (true, true));

        let local = IgnoredUserOverride {
            baseline: true,
            desired: false,
            event_seen: None,
        };
        assert_eq!(resolve_ignored_user(true, Some(local)), (false, false));
        assert_eq!(resolve_ignored_user(false, Some(local)), (false, true));

        assert_eq!(resolve_ignored_user(true, None), (true, false));
    }

    #[test]
    fn ignored_user_override_heals_before_another_device_unignores() {
        // 1. Local ignore: the store has not caught up; the override hides.
        let local = IgnoredUserOverride {
            baseline: false,
            desired: true,
            event_seen: None,
        };
        assert_eq!(resolve_ignored_user(false, Some(local)), (true, false));
        // 2. Echo lands: the override is stale and must be dropped. This
        //    consult has to happen even while the write-through list still
        //    hides the sender (see room_to_chat_room), or step 3 goes wrong.
        assert_eq!(resolve_ignored_user(true, Some(local)), (true, true));
        // 3. Another device un-ignores: no override remains; the store wins.
        assert_eq!(resolve_ignored_user(false, None), (false, false));
    }

    #[test]
    fn account_data_event_reconciles_ignored_user_overrides() {
        let prefix = "@me:example.org:";
        let mut echoed = IgnoredUserListEventContent::default();
        echoed.ignored_users.insert(
            matrix_sdk::ruma::OwnedUserId::try_from("@target:example.org").unwrap(),
            IgnoredUser::default(),
        );
        let mut overrides = HashMap::from([
            // Target present in the authoritative content: stale either way.
            (
                format!("{prefix}@target:example.org"),
                IgnoredUserOverride {
                    baseline: false,
                    desired: true,
                    event_seen: None,
                },
            ),
            // Target absent and desired=false: the server confirmed the
            // un-ignore, stale.
            (
                format!("{prefix}@unignored:example.org"),
                IgnoredUserOverride {
                    baseline: true,
                    desired: false,
                    event_seen: None,
                },
            ),
            // Target absent and desired=true: may still await its echo; the
            // override survives this round (TTL handles the ABA case later).
            (
                format!("{prefix}@pending:example.org"),
                IgnoredUserOverride {
                    baseline: false,
                    desired: true,
                    event_seen: None,
                },
            ),
            // Overrides of other accounts are never touched.
            (
                "@someoneelse:example.org:@target:example.org".to_owned(),
                IgnoredUserOverride {
                    baseline: false,
                    desired: true,
                    event_seen: None,
                },
            ),
        ]);

        reconcile_ignored_user_overrides_inner(prefix, &echoed, &mut overrides);

        assert!(!overrides.contains_key(&format!("{prefix}@target:example.org")));
        assert!(!overrides.contains_key(&format!("{prefix}@unignored:example.org")));
        assert!(overrides.contains_key(&format!("{prefix}@pending:example.org")));
        assert!(overrides.contains_key("@someoneelse:example.org:@target:example.org"));
    }

    #[test]
    fn account_data_event_starts_ttl_only_once() {
        let prefix = "@me:example.org:";
        let key = format!("{prefix}@pending:example.org");
        // Target absent and desired=true: survives the event, and the TTL
        // clock starts on the FIRST such event. Global account data arrives
        // on every sync response even when unchanged; refreshing the clock
        // each time would keep the override alive forever in the ABA case.
        let mut overrides = HashMap::from([(
            key.clone(),
            IgnoredUserOverride {
                baseline: false,
                desired: true,
                event_seen: None,
            },
        )]);
        let empty = IgnoredUserListEventContent::default();

        reconcile_ignored_user_overrides_inner(prefix, &empty, &mut overrides);
        let first_seen = overrides.get(&key).unwrap().event_seen;
        assert!(first_seen.is_some());

        // A second unchanged event must NOT reset the clock.
        reconcile_ignored_user_overrides_inner(prefix, &empty, &mut overrides);
        let second_seen = overrides.get(&key).unwrap().event_seen;
        assert_eq!(first_seen.unwrap(), second_seen.unwrap());
    }

    #[test]
    fn store_fallback_applies_pending_local_ignore_overrides() {
        let prefix = "@me:example.org:";
        let ignored = matrix_sdk::ruma::OwnedUserId::try_from("@ignored:example.org").unwrap();
        let unignored = matrix_sdk::ruma::OwnedUserId::try_from("@unignored:example.org").unwrap();
        let mut content = IgnoredUserListEventContent::default();
        content
            .ignored_users
            .insert(unignored.clone(), IgnoredUser::new());
        let mut overrides = HashMap::from([
            (
                format!("{prefix}{ignored}"),
                IgnoredUserOverride {
                    baseline: false,
                    desired: true,
                    event_seen: None,
                },
            ),
            (
                format!("{prefix}{unignored}"),
                IgnoredUserOverride {
                    baseline: true,
                    desired: false,
                    event_seen: None,
                },
            ),
        ]);

        merge_ignored_user_overrides(prefix, &mut content, &mut overrides);

        assert!(content.ignored_users.contains_key(&ignored));
        assert!(!content.ignored_users.contains_key(&unignored));
        assert_eq!(overrides.len(), 2);
    }
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
        .map_err(|error| {
            api_err(
                "auth",
                format!("Failed to install session token callback: {error}"),
            )
        })
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

/// Drop only the removed/logged-out/left account's timelines: a global
/// clear would tear down the timelines of every other active account (the
/// one the user is currently in included), forcing an avoidable rebuild.
/// The cache is keyed per account and holds Arc<Timeline> instances bound
/// to that account's client.
async fn clear_timeline_cache_for(user_id: &str) {
    sdk_timeline::clear_for_user(user_id).await;
}

/// Accounts whose remote logout failed or timed out (their access token may
/// still be valid on the server): user_id → (access_token, homeserver_url).
/// Retried best-effort when the same account logs in again on the SAME
/// homeserver (`finalize_pending`), so a dead-network logout does not leave
/// a permanently valid ghost session behind.
static PENDING_REMOTE_LOGOUTS: Lazy<RwLock<HashMap<String, (String, String)>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

/// Fire-and-forget retry of a pending remote logout for [user_id] using the
/// freshly logged-in client's HTTP transport (the new session is up either
/// way). A cross-homeserver re-login cannot invalidate the old token — the
/// retry is skipped unless the homeserver matches. Only a 2xx response
/// settles the pending entry: the stored access token may have expired by
/// the time the retry runs (refresh tokens are enabled), so a 401 means
/// "this token is rejected", not "the session is gone" — the entry stays
/// for a later login of the same account to retry again.
async fn retry_pending_remote_logout(user_id: &str, client: &Client) {
    let (token, homeserver) = match PENDING_REMOTE_LOGOUTS.read().await.get(user_id) {
        Some(entry) => entry.clone(),
        None => return,
    };
    let current_hs = client.homeserver().to_string();
    if current_hs.trim_end_matches('/') != homeserver.trim_end_matches('/') {
        return;
    }
    let client = client.clone();
    let user_id = user_id.to_string();
    tokio::spawn(async move {
        // Url Display always ends with '/': trim it so the path join does
        // not produce a double slash (some servers 404 on those).
        let base = client.homeserver().to_string();
        let url = format!("{}/_matrix/client/v3/logout", base.trim_end_matches('/'));
        let request = client.http_client().post(url).bearer_auth(token).send();
        let outcome = match tokio::time::timeout(std::time::Duration::from_secs(15), request).await
        {
            Err(_) => {
                app_log(
                    "warn",
                    "auth",
                    format!("Retried remote logout timed out for {user_id}"),
                );
                return;
            }
            Ok(result) => match result {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if remote_logout_retry_settles(status) {
                        // 2xx: the retry itself revoked the old token — the
                        // ghost session is gone; settle the pending entry.
                        PENDING_REMOTE_LOGOUTS.write().await.remove(&user_id);
                        None
                    } else if status == 401 {
                        // With refresh tokens enabled the access token
                        // expires on its own, so by the time the retry runs
                        // the stored token is usually expired even though
                        // the server-side session is still valid. A 401
                        // therefore does NOT prove the session was revoked:
                        // dropping the entry here would strand a live ghost
                        // session with no further retry. Keep it so the
                        // next login of this account tries again.
                        app_log(
                            "warn",
                            "auth",
                            format!(
                                "Retried remote logout for {user_id} rejected (401); keeping the pending entry for a later retry."
                            ),
                        );
                        None
                    } else {
                        Some(response.error_for_status())
                    }
                }
                Err(error) => Some(Err(error)),
            },
        };
        if let Some(Err(error)) = outcome {
            app_log(
                "warn",
                "auth",
                format!("Retried remote logout failed for {user_id}: {error}"),
            );
        }
    });
}

/// Whether a retried remote logout response settles the pending entry
/// (removes it): only a 2xx proves the session was revoked server-side. A
/// 401 is ambiguous when refresh tokens are enabled (the stored access
/// token may simply have expired) and must keep the entry for a later
/// retry.
fn remote_logout_retry_settles(status: u16) -> bool {
    (200..300).contains(&status)
}

#[cfg(test)]
mod remote_logout_retry_tests {
    use super::remote_logout_retry_settles;

    #[test]
    fn only_success_retries_settle_the_pending_entry() {
        // 2xx: the retry itself revoked the old session — settle.
        assert!(remote_logout_retry_settles(200));
        assert!(remote_logout_retry_settles(204));
        // 401: with refresh tokens enabled the stored access token can
        // expire on its own, so the session may still be alive — the entry
        // must survive for a later retry.
        assert!(!remote_logout_retry_settles(401));
        // Other server errors keep the entry too.
        assert!(!remote_logout_retry_settles(500));
        assert!(!remote_logout_retry_settles(429));
    }
}

// ── Multi-account store ──────────────────────────────────────────────

struct ClientEntry {
    client: Client,
    data_dir: String,
    instance_id: u64,
    room_key_task: JoinHandle<()>,
}

impl ClientEntry {
    async fn into_client_and_data_dir(self) -> (Client, String) {
        let ClientEntry {
            client,
            data_dir,
            room_key_task,
            ..
        } = self;
        room_key_task.abort();
        let _ = room_key_task.await;
        (client, data_dir)
    }
}

struct PendingEntry {
    client: Client,
    data_dir: String,
    homeserver_url: String,
}

/// All logged-in accounts, keyed by user_id.
static CLIENTS: Lazy<Arc<RwLock<HashMap<String, ClientEntry>>>> =
    Lazy::new(|| Arc::new(RwLock::new(HashMap::new())));
static NEXT_CLIENT_INSTANCE_ID: AtomicU64 = AtomicU64::new(1);

/// Currently active account.
static ACTIVE_USER: Lazy<Arc<RwLock<Option<String>>>> = Lazy::new(|| Arc::new(RwLock::new(None)));

/// Account allowed to create room-scoped subscriptions.
///
/// Callers pass the account that owns their route. Holding this read lock
/// until the subscription is registered orders an in-flight subscribe before
/// an account switch; the switch then clears it. Calls arriving after the
/// switch observe the new account and are rejected.
static SUBSCRIPTION_USER: Lazy<RwLock<Option<String>>> = Lazy::new(|| RwLock::new(None));

async fn set_subscription_user(user_id: Option<String>) {
    *SUBSCRIPTION_USER.write().await = user_id;
}

fn subscription_user_matches(active: Option<&str>, requested: Option<&str>) -> bool {
    requested.is_none_or(|requested| active == Some(requested))
}

async fn lock_subscription_state<'a, T>(
    subscription_user: &'a RwLock<Option<String>>,
    state: &'a Mutex<T>,
    account_user_id: Option<&str>,
    inactive_error: &'static str,
) -> Result<
    (
        tokio::sync::RwLockReadGuard<'a, Option<String>>,
        tokio::sync::MutexGuard<'a, T>,
    ),
    String,
> {
    let subscription_user = subscription_user.read().await;
    if !subscription_user_matches(subscription_user.as_deref(), account_user_id) {
        return Err(api_err("sync", inactive_error.to_string()));
    }
    let state = state.lock().await;
    Ok((subscription_user, state))
}

struct SyncTask {
    user_id: String,
    generation: u64,
    handle: JoinHandle<()>,
}

struct PendingSyncTask {
    handle: JoinHandle<()>,
    start: tokio::sync::oneshot::Sender<()>,
}

/// Exactly one account owns the app-wide background sync task at a time.
static SYNC_TASK: Lazy<Mutex<Option<SyncTask>>> = Lazy::new(|| Mutex::new(None));
/// Sync startup and one-shot syncs take a read guard; account transitions take
/// a write guard. This drains untracked sync_once work before a client/store is
/// replaced or deleted and prevents start_sync from installing a task midway
/// through that transition.
static SYNC_LIFECYCLE: Lazy<RwLock<()>> = Lazy::new(|| RwLock::new(()));
static SYNC_GENERATION: AtomicU64 = AtomicU64::new(0);
static NEXT_ROOM_SUBSCRIPTION_ID: AtomicU64 = AtomicU64::new(1);
/// Accounts whose sync loop has been degraded from Sliding Sync to the
/// traditional loop this session. Prevents the two loops from ping-ponging:
/// a degraded loop must not re-probe and upgrade back only to fail again
/// seconds later. Cleared on the next explicit `start_sync()` call so a
/// fresh session (or a recovered server) can retry Sliding Sync.
static SYNC_DEGRADED_ACCOUNTS: Lazy<RwLock<HashSet<String>>> =
    Lazy::new(|| RwLock::new(HashSet::new()));
tokio::task_local! {
    static SYNC_EVENT_GENERATION: u64;
}

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
    /// Mounted chat screens by room, keyed by opaque owner tokens so a stale
    /// route from an old account cannot cancel a newer route for the same ID.
    desired: HashMap<String, HashSet<String>>,
    /// The live Sliding Sync instance, present once the sync loop has built
    /// one (and reset to `None` when it's stopped).
    active: Option<matrix_sdk::sliding_sync::SlidingSync>,
    active_generation: Option<u64>,
}

static ROOM_SUBSCRIPTION: Lazy<tokio::sync::Mutex<RoomSubscriptionState>> = Lazy::new(|| {
    tokio::sync::Mutex::new(RoomSubscriptionState {
        desired: HashMap::new(),
        active: None,
        active_generation: None,
    })
});

impl RoomSubscriptionState {
    fn add_desired(&mut self, room_id: &str, subscription_id: String) -> bool {
        let subscriptions = self.desired.entry(room_id.to_owned()).or_default();
        subscriptions.insert(subscription_id);
        subscriptions.len() == 1
    }

    fn remove_desired(&mut self, room_id: &str, subscription_id: &str) -> bool {
        let Some(subscriptions) = self.desired.get_mut(room_id) else {
            return false;
        };
        if !subscriptions.remove(subscription_id) || !subscriptions.is_empty() {
            return false;
        }
        self.desired.remove(room_id);
        true
    }

    fn reset(&mut self, preserve_desired: bool) {
        self.active = None;
        self.active_generation = None;
        if !preserve_desired {
            self.desired.clear();
        }
    }

    fn clear_active_for_generation(&mut self, generation: u64) {
        if self.active_generation == Some(generation) {
            self.active = None;
            self.active_generation = None;
        }
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
    use super::{
        lock_subscription_state, receipt_extension_for_subscribed_rooms, subscription_user_matches,
        RoomSubscriptionState,
    };
    use std::collections::HashMap;
    use std::sync::Arc;
    use tokio::sync::{Mutex, RwLock};

    fn state() -> RoomSubscriptionState {
        RoomSubscriptionState {
            desired: HashMap::new(),
            active: None,
            active_generation: None,
        }
    }

    #[test]
    fn duplicate_routes_only_unsubscribe_after_the_last_owner() {
        let mut state = state();
        assert!(state.add_desired("!room:example.org", "first".to_owned()));
        assert!(!state.add_desired("!room:example.org", "second".to_owned()));
        assert!(!state.remove_desired("!room:example.org", "first"));
        assert!(state.desired.contains_key("!room:example.org"));
        assert!(state.remove_desired("!room:example.org", "second"));
        assert!(!state.desired.contains_key("!room:example.org"));
    }

    #[test]
    fn stacked_rooms_are_tracked_independently() {
        let mut state = state();
        assert!(state.add_desired("!first:example.org", "first".to_owned()));
        assert!(state.add_desired("!second:example.org", "second".to_owned()));
        assert!(state.remove_desired("!second:example.org", "second"));
        assert!(state.desired.contains_key("!first:example.org"));
    }

    #[test]
    fn receipt_extension_requests_all_subscribed_rooms() {
        assert_eq!(
            serde_json::to_value(receipt_extension_for_subscribed_rooms()).unwrap(),
            serde_json::json!({"enabled": true, "rooms": ["*"]}),
        );
    }

    #[test]
    fn sync_restart_preserves_subscriptions_registered_before_start() {
        let mut state = state();
        state.add_desired("!room:example.org", "owner".to_owned());

        state.reset(true);

        assert!(state.desired.contains_key("!room:example.org"));
    }

    #[test]
    fn account_change_clears_old_account_subscriptions() {
        let mut state = state();
        state.add_desired("!room:example.org", "old-owner".to_owned());

        state.reset(false);

        assert!(state.desired.is_empty());
    }

    #[test]
    fn stale_owner_cannot_unsubscribe_a_new_account_route() {
        let mut state = state();
        state.add_desired("!room:example.org", "old-owner".to_owned());
        state.reset(false);
        state.add_desired("!room:example.org", "new-owner".to_owned());

        assert!(!state.remove_desired("!room:example.org", "old-owner"));
        assert!(state.desired.contains_key("!room:example.org"));
    }

    #[test]
    fn stale_account_cannot_register_after_a_switch() {
        assert!(!subscription_user_matches(
            Some("@bob:example.org"),
            Some("@alice:example.org"),
        ));
        assert!(subscription_user_matches(
            Some("@bob:example.org"),
            Some("@bob:example.org"),
        ));
    }

    #[test]
    fn stale_sync_cannot_clear_a_newer_published_generation() {
        let mut state = state();
        state.active_generation = Some(2);

        state.clear_active_for_generation(1);
        assert_eq!(state.active_generation, Some(2));

        state.clear_active_for_generation(2);
        assert_eq!(state.active_generation, None);
    }

    #[tokio::test]
    async fn queued_account_writer_does_not_deadlock_subscription_registration() {
        let user = Arc::new(RwLock::new(Some("@alice:example.org".to_string())));
        let state = Arc::new(Mutex::new(()));
        let held_state = state.lock().await;

        let registration = {
            let user = user.clone();
            let state = state.clone();
            tokio::spawn(async move {
                let guards =
                    lock_subscription_state(&user, &state, Some("@alice:example.org"), "inactive")
                        .await
                        .unwrap();
                drop(guards);
            })
        };
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while let Ok(guard) = user.try_write() {
                drop(guard);
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("registration must acquire the subscription-user read lock");

        let writer = {
            let user = user.clone();
            tokio::spawn(async move {
                *user.write().await = Some("@bob:example.org".to_string());
            })
        };
        tokio::task::yield_now().await;
        drop(held_state);

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            registration.await.unwrap();
            writer.await.unwrap();
        })
        .await
        .expect("subscription registration and queued writer must complete");
    }
}

#[cfg(test)]
mod sync_lifecycle_tests {
    use std::sync::Arc;
    use tokio::sync::{oneshot, RwLock};

    #[tokio::test]
    async fn account_transition_drains_and_blocks_sync_admissions() {
        let lifecycle = Arc::new(RwLock::new(()));
        let running_sync = lifecycle.read().await;
        let transition_lifecycle = lifecycle.clone();
        let (transition_acquired_tx, transition_acquired_rx) = oneshot::channel();
        let (release_transition_tx, release_transition_rx) = oneshot::channel();

        let transition = tokio::spawn(async move {
            let _transition = transition_lifecycle.write().await;
            let _ = transition_acquired_tx.send(());
            let _ = release_transition_rx.await;
        });

        tokio::task::yield_now().await;
        drop(running_sync);
        transition_acquired_rx.await.unwrap();

        let waiting_sync_lifecycle = lifecycle.clone();
        let waiting_sync = tokio::spawn(async move {
            let _sync = waiting_sync_lifecycle.read().await;
        });
        tokio::task::yield_now().await;
        assert!(!waiting_sync.is_finished());

        let _ = release_transition_tx.send(());
        transition.await.unwrap();
        waiting_sync.await.unwrap();
    }
}

async fn stop_sync_task(user_id: Option<&str>, preserve_subscriptions: bool) -> u64 {
    let mut task = SYNC_TASK.lock().await;
    let should_stop = user_id.is_none()
        || task
            .as_ref()
            .is_some_and(|running| user_id.is_some_and(|id| running.user_id == id));
    let generation = if should_stop {
        advance_sync_generation()
    } else {
        SYNC_GENERATION.load(Ordering::SeqCst)
    };
    if should_stop {
        let running = task.take();
        // A same-account restart must retain mounted rooms registered before
        // start_sync. Account changes clear them so they cannot be replayed
        // into another account's Sliding Sync instance.
        let mut sub = ROOM_SUBSCRIPTION.lock().await;
        let graceful_stop = running.as_ref().and_then(|running| {
            (sub.active_generation == Some(running.generation))
                .then(|| sub.active.clone())
                .flatten()
        });
        let graceful_stop_requested = graceful_stop
            .as_ref()
            .is_some_and(|sliding_sync| sliding_sync.stop_sync().is_ok());
        sub.reset(preserve_subscriptions);
        drop(sub);
        if !preserve_subscriptions {
            let mut typing = TYPING_TASK.lock().await;
            if let Some(task) = typing.take() {
                task.handle.abort();
            }
        }
        if let Some(running) = running {
            if !graceful_stop_requested {
                running.handle.abort();
            }
            // Drop the task lock before awaiting the old loop: a hung SDK
            // task must not block start_sync (or logout/switch) forever.
            // The generation barrier already isolates the old loop's
            // callbacks, so waiting outside the lock stays safe.
            drop(task);
            // Sliding Sync deliberately finishes response processing in an
            // uncancellable SDK task. Waiting for the loop after stop_sync()
            // drains that work before an A -> B -> A account transition can
            // make its old handlers look current again. The timeout bounds
            // the wait for the pathological case where the SDK task never
            // exits (the SDK has no HTTP timeout); after it fires, the
            // generation barrier alone keeps the old loop inert.
            let user_id = running.user_id;
            let abort_handle = running.handle.abort_handle();
            if tokio::time::timeout(std::time::Duration::from_secs(10), running.handle)
                .await
                .is_err()
            {
                // The old loop did not exit in time (a hung SDK task with no
                // HTTP timeout). Abort it so it stops holding the old client
                // and connection; the generation barrier already keeps its
                // callbacks from surfacing to the UI.
                abort_handle.abort();
                app_log(
                    "warn",
                    "sync",
                    format!("Sync loop for user {user_id} did not exit in time; aborted."),
                );
            }
            app_log(
                "info",
                "sync",
                format!("Stopped sync loop for user {user_id}"),
            );
        }
    }
    generation
}

async fn sync_generation_is_active(generation: u64, user_id: &str) -> bool {
    if SYNC_GENERATION.load(Ordering::SeqCst) != generation {
        return false;
    }
    let matches = ACTIVE_USER.read().await.as_deref() == Some(user_id);
    matches && SYNC_GENERATION.load(Ordering::SeqCst) == generation
}

/// Retry-delay sleep that aborts early once the sync generation is no longer
/// active. Without this, `stop_sync_task` (account switch, logout, restart)
/// would wait out the whole delay while the loop sits in this sleep, because
/// `stop_sync()` cannot interrupt a `sleep()`.
async fn interruptible_retry_sleep(generation: u64, user_id: &str, duration: std::time::Duration) {
    let deadline = tokio::time::Instant::now() + duration;
    loop {
        if !sync_generation_is_active(generation, user_id).await {
            return;
        }
        let now = tokio::time::Instant::now();
        if now >= deadline {
            return;
        }
        let remaining = deadline - now;
        tokio::time::sleep(remaining.min(std::time::Duration::from_millis(100))).await;
    }
}

async fn clear_published_sync(generation: u64) {
    let mut subscriptions = ROOM_SUBSCRIPTION.lock().await;
    subscriptions.clear_active_for_generation(generation);
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

#[derive(Clone)]
struct ClientIdentity {
    user_id: String,
    instance_id: u64,
}

async fn active_generation_for_client(identity: &ClientIdentity) -> Option<u64> {
    let generation = SYNC_EVENT_GENERATION
        .try_with(|generation| *generation)
        .unwrap_or_else(|_| SYNC_GENERATION.load(Ordering::SeqCst));
    if !sync_generation_is_active(generation, &identity.user_id).await {
        return None;
    }
    let is_current_instance = CLIENTS
        .read()
        .await
        .get(&identity.user_id)
        .is_some_and(|entry| entry.instance_id == identity.instance_id);
    if !is_current_instance || !sync_generation_is_active(generation, &identity.user_id).await {
        return None;
    }
    Some(generation)
}

async fn notify_sync_event_for_client(identity: &ClientIdentity, event: SyncEvent) {
    if let Some(generation) = active_generation_for_client(identity).await {
        notify_sync_event_for_generation(generation, event);
    }
}

fn install_verification_event_handler(client: &Client, identity: ClientIdentity) {
    client.add_event_handler(
        move |event: ToDeviceKeyVerificationRequestEvent, client: Client| {
            let identity = identity.clone();
            async move {
                let Some(own_user_id) = client.user_id() else {
                    return;
                };
                if event.sender != own_user_id
                    || active_generation_for_client(&identity).await.is_none()
                {
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
            }
        },
    );
}

fn install_live_update_event_handlers(client: &Client, identity: ClientIdentity) {
    let message_identity = identity.clone();
    client.add_event_handler(move |_event: AnySyncMessageLikeEvent, room: Room| {
        let identity = message_identity.clone();
        async move {
            notify_sync_event_for_client(
                &identity,
                SyncEvent::MessageSent {
                    room_id: room.room_id().to_string(),
                },
            )
            .await;
        }
    });

    let receipt_identity = identity.clone();
    client.add_event_handler(move |event: SyncReceiptEvent, room: Room| {
        let identity = receipt_identity.clone();
        async move {
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
            notify_sync_event_for_client(&identity, SyncEvent::MessageSent { room_id }).await;
        }
    });

    let pinned_identity = identity.clone();
    client.add_event_handler(
        move |_event: SyncStateEvent<RoomPinnedEventsEventContent>, room: Room| {
            let identity = pinned_identity.clone();
            async move {
                notify_sync_event_for_client(
                    &identity,
                    SyncEvent::PinnedMessagesChanged {
                        room_id: room.room_id().to_string(),
                    },
                )
                .await;
            }
        },
    );

    let member_identity = identity.clone();
    client.add_event_handler(
        move |_event: SyncStateEvent<RoomMemberEventContent>, room: Room| {
            let identity = member_identity.clone();
            async move {
                notify_sync_event_for_client(
                    &identity,
                    SyncEvent::RoomMembersChanged {
                        room_id: room.room_id().to_string(),
                    },
                )
                .await;
            }
        },
    );

    let marked_unread_identity = identity.clone();
    client.add_event_handler(
        move |event: RoomAccountDataEvent<MarkedUnreadEventContent>, room: Room, client: Client| {
            let identity = marked_unread_identity.clone();
            async move {
                if active_generation_for_client(&identity).await.is_none() {
                    return;
                }
                if let Some(key) = marked_unread_override_key(&client, &room) {
                    let mut overrides = MARKED_UNREAD_OVERRIDES.write().await;
                    let synced = event.content.unread;
                    reconcile_marked_unread_override(&mut overrides, &key, synced);
                }
                notify_sync_event_for_client(&identity, SyncEvent::RoomListChanged).await;
            }
        },
    );

    let ignored_identity = identity;
    client.add_event_handler(
        move |event: GlobalAccountDataEvent<IgnoredUserListEventContent>, client: Client| {
            let identity = ignored_identity.clone();
            async move {
                if active_generation_for_client(&identity).await.is_none() {
                    return;
                }
                reconcile_ignored_user_overrides(&client, &event.content).await;
                notify_sync_event_for_client(&identity, SyncEvent::IgnoredUsersChanged).await;
            }
        },
    );
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

fn install_room_key_event_handler(client: &Client, identity: ClientIdentity) -> JoinHandle<()> {
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
                        notify_sync_event_for_client(&identity, SyncEvent::MessageSent { room_id })
                            .await;
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
                    notify_sync_event_for_client(&identity, SyncEvent::SyncCompleted).await;
                }
            }
        }
    })
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

async fn delete_account_sdk_store(data_dir: &str, user_id: &str) -> Result<(), String> {
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
    remove_dir_all_if_exists(&sdk_dir)
        .await
        .map(|_| ())
        .map_err(|error| {
            api_err(
                "auth",
                format!("Failed to delete SDK store for {user_id}: {error}"),
            )
        })
}

/// Retry SDK-store cleanup for an account whose persisted removal transaction
/// was interrupted. Called during startup before any sessions are restored.
#[frb]
pub async fn cleanup_removed_account_store(
    user_id: String,
    data_dir: String,
) -> Result<(), String> {
    delete_account_sdk_store(&data_dir, &user_id).await
}

#[cfg(test)]
mod account_store_cleanup_tests {
    use super::{build_sdk_data_dir, cleanup_removed_account_store};

    #[tokio::test]
    async fn removed_account_store_cleanup_is_idempotent() {
        let data_dir = std::env::temp_dir().join(format!(
            "matter-removed-account-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let user_id = "@removed:example.org";
        let sdk_dir = build_sdk_data_dir(data_dir.to_str().unwrap(), Some(user_id));
        tokio::fs::create_dir_all(&sdk_dir).await.unwrap();
        tokio::fs::write(sdk_dir.join("store.db"), b"stale credentials")
            .await
            .unwrap();

        cleanup_removed_account_store(user_id.to_string(), data_dir.to_str().unwrap().to_string())
            .await
            .unwrap();
        assert!(!sdk_dir.exists());

        cleanup_removed_account_store(user_id.to_string(), data_dir.to_str().unwrap().to_string())
            .await
            .unwrap();
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }
}

struct ClientLease {
    client: Client,
    lifecycle: LifecycleProtection,
}

impl Deref for ClientLease {
    type Target = Client;

    fn deref(&self) -> &Self::Target {
        &self.client
    }
}

impl ClientLease {
    fn lifecycle_protection(&self) -> LifecycleProtection {
        self.lifecycle.clone()
    }
}

/// Return the currently active client, or the pending one if no account is
/// active yet. The lease keeps account removal/replacement from dropping its
/// SQLite store while any API call still holds the Client or a derived Room.
async fn get_client() -> Option<ClientLease> {
    let lifecycle = SYNC_LIFECYCLE.read().await;
    let active = ACTIVE_USER.read().await;
    let client = if let Some(user_id) = active.as_ref() {
        let clients = CLIENTS.read().await;
        clients.get(user_id).map(|e| e.client.clone())
    } else {
        PENDING.read().await.as_ref().map(|p| p.client.clone())
    }?;
    Some(ClientLease {
        client,
        lifecycle: Arc::new(lifecycle),
    })
}

/// After a successful auth on the pending client, migrate it to a per-user store.
async fn finalize_pending() -> Result<String, String> {
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
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
    if CLIENTS.read().await.contains_key(&user_id) {
        // This pending login will never be used — the account is already
        // signed in. But the password/token login already created a session
        // on the server: dropping the client here would leave a permanently
        // valid ghost device session (with a refresh token) behind. Revoke
        // it first, bounded like logout()/remove_account (this runs under
        // the SYNC_LIFECYCLE write lock, so an unreachable server must not
        // freeze the error path). On failure the token is remembered in
        // PENDING_REMOTE_LOGOUTS so the next login of this account retries
        // the remote logout (see retry_pending_remote_logout).
        match tokio::time::timeout(
            std::time::Duration::from_secs(15),
            pending_client.matrix_auth().logout(),
        )
        .await
        {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                PENDING_REMOTE_LOGOUTS.write().await.insert(
                    user_id.clone(),
                    (
                        matrix_session.tokens.access_token.clone(),
                        homeserver_url.clone(),
                    ),
                );
                app_log(
                    "warn",
                    "auth",
                    format!("Remote logout of duplicate pending session failed for {user_id}: {e}"),
                );
                warn!("Remote logout of duplicate pending session failed for {user_id}: {e}");
            }
            Err(_) => {
                PENDING_REMOTE_LOGOUTS.write().await.insert(
                    user_id.clone(),
                    (
                        matrix_session.tokens.access_token.clone(),
                        homeserver_url.clone(),
                    ),
                );
                app_log(
                    "warn",
                    "auth",
                    format!("Remote logout of duplicate pending session timed out for {user_id}"),
                );
                warn!("Remote logout of duplicate pending session timed out for {user_id}");
            }
        }
        // Clear PENDING and drop the freshly built client so its session is
        // not retained as an orphan.
        {
            let mut pending = PENDING.write().await;
            *pending = None;
        }
        drop(pending_client);
        return Err("This account is already signed in.".to_string());
    }

    // Build per-user directory
    let sdk_dir = build_sdk_data_dir(&data_dir, Some(&user_id));

    // A password login creates the crypto identity in the pending store. Keep
    // that exact store: rebuilding an empty store with the same Matrix device
    // ID discards the Olm account and makes encrypted messages undecryptable.
    stop_sync_task(Some(&user_id), false).await;
    clear_account_runtime_state(&user_id).await;

    // Release every reference before moving SQLite files (required on Windows
    // and avoids moving a database while WAL writes are still in flight).
    {
        let mut pending = PENDING.write().await;
        *pending = None;
    }
    drop(pending_client);
    // TODO: Tweak this value to avoid "Access Denied" (OS error 5) errors on
    // Windows on login (on `rename(&temp_dir, &sdk_dir)`).
    // 20000 (20 seconds) worked for me but obviously butchered the waiting time.
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
        .request_config(bounded_request_config())
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
    let instance_id = NEXT_CLIENT_INSTANCE_ID.fetch_add(1, Ordering::Relaxed);
    let identity = ClientIdentity {
        user_id: user_id.clone(),
        instance_id,
    };
    install_verification_event_handler(&new_client, identity.clone());
    install_live_update_event_handlers(&new_client, identity.clone());
    let room_key_task = install_room_key_event_handler(&new_client, identity);

    // Stop event publication before replacing the client entry. This orders
    // callbacks from the old instance before the identity swap.
    set_subscription_user(None).await;
    stop_sync_task(None, false).await;
    // A previous logout of this account may have failed to reach the
    // server (dead network): its old token may still be valid there —
    // retry the remote logout best-effort (fire-and-forget) with this
    // client's transport.
    retry_pending_remote_logout(&user_id, &new_client).await;
    {
        let mut clients = CLIENTS.write().await;
        clients.insert(
            user_id.clone(),
            ClientEntry {
                client: new_client,
                data_dir: data_dir.clone(),
                instance_id,
                room_key_task,
            },
        );
    }

    // Invalidate builders on both sides of the active-account write.
    {
        let mut active = ACTIVE_USER.write().await;
        *active = Some(user_id.clone());
    }
    stop_sync_task(None, false).await;
    set_subscription_user(Some(user_id.clone())).await;

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
    /// Event IDs of the current name/avatar state. Unlike display values,
    /// these distinguish repeated values in optimistic-update reconciliation.
    pub name_event_id: Option<String>,
    pub avatar_event_id: Option<String>,
    pub last_message: String,
    pub last_message_sender: Option<String>,
    pub last_message_time: String,
    /// Event ID of the latest timeline event (empty when none): the room's
    /// revision token for optimistic-state baselines.
    pub last_event_id: String,
    pub unread_count: i32,
    /// Whether the user explicitly marked this room as unread.
    pub is_marked_unread: bool,
    /// "dm", "group", or "space"
    pub room_type: String,
    pub is_encrypted: bool,
    /// Whether an explicit mute push rule exists for this room.
    pub is_muted: bool,
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

/// Mutable metadata for a joined non-space room.
#[frb]
#[derive(Clone, Debug)]
pub struct RoomDetails {
    pub id: String,
    pub name: String,
    pub has_explicit_name: bool,
    pub avatar_url: Option<String>,
    pub name_event_id: Option<String>,
    pub avatar_event_id: Option<String>,
    pub topic_event_id: Option<String>,
    pub topic: Option<String>,
}

#[frb]
#[derive(Clone, Debug)]
pub struct RoomDetailsUpdate {
    pub name_event_id: Option<String>,
    pub topic_event_id: Option<String>,
    pub name_error: Option<String>,
    pub topic_error: Option<String>,
}

#[frb]
#[derive(Clone, Debug)]
pub struct RoomAvatarUpdate {
    pub avatar_url: String,
    pub event_id: String,
}

#[frb]
#[derive(Clone, Debug)]
pub struct Contact {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
    pub status: String,
}

/// A pending request to join a knock-enabled room.
#[frb]
#[derive(Clone, Debug)]
pub struct KnockRequest {
    pub user_id: String,
    pub display_name: String,
    pub avatar_url: Option<String>,
    pub reason: Option<String>,
}

async fn room_name_event_id(room: &Room) -> Option<String> {
    let raw = room
        .get_state_event_static::<RoomNameEventContent>()
        .await
        .ok()
        .flatten()?;
    raw.deserialize().ok()?.event_id().map(ToString::to_string)
}

async fn room_avatar_event_id(room: &Room) -> Option<String> {
    let raw = room
        .get_state_event_static::<RoomAvatarEventContent>()
        .await
        .ok()
        .flatten()?;
    raw.deserialize().ok()?.event_id().map(ToString::to_string)
}

async fn room_topic_event_id(room: &Room) -> Option<String> {
    let raw = room
        .get_state_event_static::<RoomTopicEventContent>()
        .await
        .ok()
        .flatten()?;
    raw.deserialize().ok()?.event_id().map(ToString::to_string)
}

async fn room_to_chat_room(
    room: &matrix_sdk::Room,
    ignored_user_ids: Option<&std::collections::HashSet<String>>,
    authoritative: bool,
) -> ChatRoom {
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
    let (name_event_id, avatar_event_id) =
        tokio::join!(room_name_event_id(room), room_avatar_event_id(room));
    // `notification_count` is 0 for muted rooms (which would hide the
    // indicator entirely) AND for non-muted rooms whose unread messages do
    // not trigger notifications (default group push rules only count
    // mentions) or whose notification state was settled by another device's
    // receipt — which is not the same as THIS device having read them. So
    // whenever the server count is 0, fall back to the client-side unread
    // count (tracked from this device's own read marker, independent of
    // push rules): the badge then reflects this device's actual unread
    // state. The only inaccuracy is a brief, conservative "unread" while
    // our own read receipt's echo lags the server count by up to a sync
    // cycle — opening the room clears it.
    let notification_settings = notification_settings_for(
        &room.client(),
        &room
            .client()
            .user_id()
            .map(|id| id.to_string())
            .unwrap_or_default(),
        None,
    )
    .await;
    let is_muted = notification_settings
        .get_user_defined_room_notification_mode(room.room_id())
        .await
        == Some(matrix_sdk::notification_settings::RoomNotificationMode::Mute);
    let server_unread = room.unread_notification_counts().notification_count as i32;
    let unread_count = if server_unread > 0 {
        // Known limitation: the server-side count has no per-sender
        // dimension, so messages from ignored users still contribute to
        // the unread badge (the fallback below shares this for the same
        // reason).
        server_unread
    } else {
        // Known limitations of this client-side count
        // (`read_receipts.num_unread`): it has no per-sender breakdown, so
        // messages from ignored users still contribute to the unread
        // marker; and without any read receipt the SDK recounts the events
        // in the local cache window, so a room the user never opened shows
        // an approximate count bounded by that window (truncated when the
        // window is small), and a room with no cached events shows none.
        // The SDK does not expose the unread event senders to filter them
        // out here; the timeline itself and the preview text do hide
        // ignored senders.
        room.num_unread_messages() as i32
    };
    let is_marked_unread = effective_marked_unread(&room.client(), room).await;
    let (mut last_message, mut last_message_sender_id, last_message_time, last_event_id) =
        get_last_message_info(room);
    if let Some(sender_id) = last_message_sender_id.as_deref() {
        // The Dart ignore list comes in three freshness levels:
        // - authoritative (a confirmed write-through or a just-completed
        //   fetch): the list wins outright. The SDK store's sync echo can
        //   lag in either direction — after a confirmed un-ignore it may
        //   still report the sender as ignored, and merging would keep
        //   previews hidden indefinitely while offline.
        // - a merely persisted cache: union with the store, so the stale
        //   snapshot can neither re-expose a sender the store already hides
        //   (cross-device change, echo ahead of write-through) nor be
        //   overridden by it forever.
        // - no list at all (unknown): the store plus pending-write
        //   overrides are the only source.
        // Overrides are deliberately consulted ONLY in the unknown case:
        // they bridge the store lag for local writes (already covered by
        // the list otherwise), and a coalesced sync (false → true → false
        // reports only the final false) can leave an override stuck at its
        // baseline forever (ABA).
        let hidden = match ignored_user_ids {
            Some(list) if authoritative => list.contains(sender_id),
            Some(list) => {
                let store_ignored = match matrix_sdk::ruma::UserId::parse(sender_id) {
                    Ok(user_id) => room.client().is_user_ignored(&user_id).await,
                    Err(_) => false,
                };
                list.contains(sender_id) || store_ignored
            }
            None => match matrix_sdk::ruma::UserId::parse(sender_id) {
                Ok(user_id) => effective_is_user_ignored(&room.client(), &user_id).await,
                Err(_) => false,
            },
        };
        if hidden {
            last_message = "(消息已隐藏)".to_string();
            last_message_sender_id = None;
        }
    }
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
        name_event_id,
        avatar_event_id,
        last_message,
        last_message_sender,
        last_message_time,
        last_event_id,
        unread_count,
        is_marked_unread,
        room_type,
        is_encrypted,
        is_muted,
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
    info: Option<&matrix_sdk::ruma::events::room::ImageInfo>,
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
            api_err(
                "rooms",
                format!(
                    "Failed to load sticker packs for room {}: {e}",
                    room.room_id()
                ),
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

fn truncate_utf8(value: &str, max_bytes: usize) -> &str {
    let mut end = value.len().min(max_bytes);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
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
            truncate_utf8(err_str, 500)
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
    let parsed_room_id = matrix_sdk::ruma::RoomId::parse(room_id)
        .map_err(|e| api_err("rooms", format!("Invalid room ID: {e}")))?;
    client
        .get_room(parsed_room_id.as_ref())
        .ok_or_else(|| api_err("rooms", format!("房间不存在: {room_id}")))
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

#[cfg(test)]
mod auth_error_tests {
    use super::friendly_auth_error;

    #[test]
    fn password_login_errors_do_not_expose_server_response_text() {
        let raw = "[403 / M_FORBIDDEN] password was secret-value";
        let safe = friendly_auth_error(raw, "登录失败，请稍后重试");

        assert_eq!(safe, "认证失败，请检查账号、密码或 Token");
        assert!(!safe.contains("secret-value"));
    }
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

    // Clean up any stale pending directory under the lifecycle write lock
    // (same level as finalize_pending / logout / restore): a previous login
    // attempt may still be in flight with its pending client's SQLite store
    // open on this directory — its lease holds a SYNC_LIFECYCLE read share,
    // so the write guard drains those calls before the store is deleted
    // underneath them, and blocks new ones until the fresh pending client
    // is installed. Lock order SYNC_LIFECYCLE → PENDING matches get_client
    // and finalize_pending.
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
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
        .request_config(bounded_request_config())
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
    let client = get_client().await.ok_or_else(|| {
        api_err(
            "auth",
            "No client created. Call create_client first.".to_string(),
        )
    })?;

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
                truncate_utf8(&err_str, 300)
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
    let client = get_client().await.ok_or_else(|| {
        api_err(
            "auth",
            "No client created. Call create_client first.".to_string(),
        )
    })?;

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
                .map_err(|e| api_err("auth", format!("Finalization failed: {e}")))?;
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
                truncate_utf8(&err_str, 300)
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
    let client = get_client().await.ok_or_else(|| {
        api_err(
            "auth",
            "No client created. Call create_client first.".to_string(),
        )
    })?;

    let started = std::time::Instant::now();
    let login_result = client
        .matrix_auth()
        .login_username(&username, &password)
        .request_refresh_token()
        .initial_device_display_name("Matter")
        .await;
    match login_result {
        Ok(response) => {
            let request_elapsed_ms = started.elapsed().as_millis();
            app_log(
                "info",
                "auth",
                format!(
                    "Password login response accepted for {} after {} ms; \
                     device={}, starting local finalization",
                    response.user_id, request_elapsed_ms, response.device_id,
                ),
            );
            // Auto-finalize: migrate pending client to per-user store
            drop(client);
            let finalization_started = std::time::Instant::now();
            let finalized = finalize_pending().await.map_err(|e| {
                api_err(
                    "auth",
                    format!(
                        "Password login local finalization failed after {} ms: {e}",
                        finalization_started.elapsed().as_millis(),
                    ),
                )
            })?;
            app_log(
                "info",
                "auth",
                format!(
                    "Account finalized after password login: {} \
                     (request={} ms, finalization={} ms)",
                    finalized,
                    request_elapsed_ms,
                    finalization_started.elapsed().as_millis(),
                ),
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
        Err(e) => {
            let raw_error = format!("{e}");
            let friendly_error = friendly_auth_error(&raw_error, "登录失败，请稍后重试");
            app_log(
                "error",
                "auth",
                format!(
                    "Password login request or local SDK activation failed after {} ms: {}",
                    started.elapsed().as_millis(),
                    friendly_error,
                ),
            );
            Ok(AuthResult {
                success: false,
                user_id: None,
                device_id: None,
                access_token: None,
                refresh_token: None,
                error: Some(friendly_error),
                needs_uiaa: false,
                session: None,
                flows: None,
            })
        }
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
    let client = get_client().await.ok_or_else(|| {
        api_err(
            "auth",
            "No client created. Call create_client first.".to_string(),
        )
    })?;

    let parsed_user_id = matrix_sdk::ruma::UserId::parse(&user_id).map_err(|e| {
        api_err(
            "auth",
            friendly_auth_error(&format!("无效的用户 ID: {e}"), "用户 ID 格式无效"),
        )
    })?;
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
            api_err(
                "auth",
                friendly_auth_error(
                    &format!("Restore session failed: {e}"),
                    "Token 登录失败，请检查输入信息",
                ),
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
        .ok_or_else(|| api_err("auth", "Token 登录成功，但无法获取最终会话".to_string()))?;

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
    let client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "No client created.".to_string()))?;
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("auth", "Not logged in.".to_string()))?;

    let account = client.account();
    let display_name = account
        .get_display_name()
        .await
        .map_err(|e| api_err("auth", format!("Failed to fetch display name: {e}")))?
        .unwrap_or_default();
    let avatar_url = account
        .get_avatar_url()
        .await
        .map_err(|e| api_err("auth", format!("Failed to fetch avatar: {e}")))?
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
    let client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "No client created.".to_string()))?;
    let account = client.account();
    let trimmed = name.trim();
    account
        .set_display_name(if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        })
        .await
        .map_err(|e| api_err("auth", format!("Failed to set display name: {e}")))?;
    Ok(())
}

/// Update the current user's avatar. `mxc` is an `mxc://` URI obtained from
/// `upload_avatar`. Pass an empty string to remove the avatar.
#[frb]
pub async fn set_avatar_url(mxc: String) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "No client created.".to_string()))?;
    let account = client.account();
    let trimmed = mxc.trim();
    if trimmed.is_empty() {
        account
            .set_avatar_url(None)
            .await
            .map_err(|e| api_err("auth", format!("Failed to remove avatar: {e}")))?;
    } else {
        use std::convert::TryFrom;
        let mxc_uri = matrix_sdk::ruma::OwnedMxcUri::try_from(trimmed)
            .map_err(|e| api_err("auth", format!("Invalid mxc URI: {e}")))?;
        account
            .set_avatar_url(Some(&mxc_uri))
            .await
            .map_err(|e| api_err("auth", format!("Failed to set avatar: {e}")))?;
    }
    Ok(())
}

/// Upload raw image bytes as avatar media and return the resulting `mxc://`
/// URI. Call `set_avatar_url` afterwards to actually apply it. Split into two
/// steps so the UI can show progress if needed and a failed upload won't leave
/// a half-set profile.
#[frb]
pub async fn upload_avatar(content_type: String, data: Vec<u8>) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("auth", "No client created.".to_string()))?;
    let account = client.account();
    let mime: mime::Mime = content_type.parse().map_err(|e| {
        api_err(
            "auth",
            format!("Invalid content type '{content_type}': {e}"),
        )
    })?;
    let mxc = account
        .upload_avatar(&mime, data)
        .await
        .map_err(|e| api_err("auth", format!("Failed to upload avatar: {e}")))?;
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
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
    let clients = CLIENTS.read().await;
    if clients.contains_key(&user_id) {
        drop(clients);
        set_subscription_user(None).await;
        stop_sync_task(None, false).await;
        let previous_user = {
            let mut active = ACTIVE_USER.write().await;
            let previous = active.clone();
            *active = Some(user_id.clone());
            previous
        };
        set_subscription_user(Some(user_id.clone())).await;
        clear_verification_session().await;
        // Drop only the previously active account's timelines: a global
        // clear would also tear down the timelines of the account being
        // switched to (the one the user is currently in), forcing an
        // avoidable rebuild. With no previously active account, fall back
        // to the target's own cache to keep the old defensive clear.
        clear_timeline_cache_for(previous_user.as_deref().unwrap_or(&user_id)).await;
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
#[derive(Clone, Debug)]
pub struct AccountRemovalResult {
    /// The account is already removed when this is set; only stale local SDK
    /// files may remain and can be cleaned on a later app start.
    pub cleanup_error: Option<String>,
    /// Local removal completed, but the homeserver did not confirm logout.
    /// The server-side device session may still be valid.
    pub remote_logout_pending: bool,
}

#[frb]
pub async fn logout() -> Result<AccountRemovalResult, String> {
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
    let active_user = {
        let active = ACTIVE_USER.read().await;
        active.clone()
    };

    let user_id =
        active_user.ok_or_else(|| api_err("auth", "No active account to logout".to_string()))?;
    clear_verification_session().await;
    set_subscription_user(None).await;
    stop_sync_task(None, false).await;
    clear_timeline_cache_for(&user_id).await;

    let entry = {
        let mut clients = CLIENTS.write().await;
        clients
            .remove(&user_id)
            .ok_or_else(|| api_err("auth", "Active account missing from store".to_string()))?
    };
    let (client, data_dir) = entry.into_client_and_data_dir().await;

    let mut remote_logout_pending = false;
    if client.matrix_auth().logged_in() {
        // Bound the remote logout: the server may be unreachable and the SDK
        // has no HTTP timeout, which would otherwise freeze account removal
        // (this runs under the SYNC_LIFECYCLE write lock) indefinitely. A
        // timeout or failure still proceeds with local cleanup below, so the
        // account can be logged out locally and retried on the server later.
        match tokio::time::timeout(
            std::time::Duration::from_secs(15),
            client.matrix_auth().logout(),
        )
        .await
        {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                remote_logout_pending = true;
                // The token may still be valid on the server: remember it so
                // the next login of this account can retry the remote logout
                // (see finalize_pending) instead of leaving a ghost session.
                if let Some(session) = client.matrix_auth().session() {
                    PENDING_REMOTE_LOGOUTS.write().await.insert(
                        user_id.clone(),
                        (
                            session.tokens.access_token.to_string(),
                            client.homeserver().to_string(),
                        ),
                    );
                }
                app_log(
                    "warn",
                    "auth",
                    format!("Remote logout failed for {}: {e}", user_id),
                );
                warn!("Remote logout failed for {}: {e}", user_id);
            }
            Err(_) => {
                remote_logout_pending = true;
                if let Some(session) = client.matrix_auth().session() {
                    PENDING_REMOTE_LOGOUTS.write().await.insert(
                        user_id.clone(),
                        (
                            session.tokens.access_token.to_string(),
                            client.homeserver().to_string(),
                        ),
                    );
                }
                app_log(
                    "warn",
                    "auth",
                    format!(
                        "Remote logout timed out for {}, continuing locally",
                        user_id
                    ),
                );
                warn!(
                    "Remote logout timed out for {}, continuing locally",
                    user_id
                );
            }
        }
    }

    clear_account_runtime_state(&user_id).await;
    drop(client);
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let store_delete_result = delete_account_sdk_store(&data_dir, &user_id).await;

    // Update active user to another available account, or None
    let clients = CLIENTS.write().await;
    let mut active = ACTIVE_USER.write().await;
    let next_user_id = clients.iter().next().map(|(id, _)| id.clone());
    if let Some(next_id) = next_user_id.as_ref() {
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
    drop(active);
    drop(clients);
    // A start_sync already building when logout began can install itself
    // after the first stop while ACTIVE_USER still names this account. Stop
    // once more after changing ACTIVE_USER, before new routes may subscribe.
    stop_sync_task(None, false).await;
    set_subscription_user(next_user_id).await;

    Ok(AccountRemovalResult {
        cleanup_error: store_delete_result.err(),
        remote_logout_pending,
    })
}

/// Remove a specific account by user_id (logout + delete data).
#[frb]
pub async fn remove_account(user_id: String) -> Result<AccountRemovalResult, String> {
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
    let removing_active = ACTIVE_USER.read().await.as_ref() == Some(&user_id);
    if removing_active {
        clear_verification_session().await;
        set_subscription_user(None).await;
    }
    // Drop the removed account's timelines regardless of whether it is
    // active: the cache is keyed per account and holds Arc<Timeline>
    // instances bound to the removed client (whose SQLite store is about
    // to be deleted) — re-logging into the account later must build fresh
    // timelines, not reuse dead ones. Scoped to THIS account: a global
    // clear would also tear down the timelines of the account the user is
    // currently in.
    clear_timeline_cache_for(&user_id).await;
    if removing_active {
        stop_sync_task(None, false).await;
    } else {
        stop_sync_task(Some(&user_id), false).await;
    }

    let entry = {
        let mut clients = CLIENTS.write().await;
        clients
            .remove(&user_id)
            .ok_or_else(|| api_err("auth", "Account not found".to_string()))?
    };
    let (client, data_dir) = entry.into_client_and_data_dir().await;

    let mut remote_logout_pending = false;
    if client.matrix_auth().logged_in() {
        // Bounded remote logout: see logout() — an unreachable server must
        // not freeze account removal, which runs under the write lock.
        match tokio::time::timeout(
            std::time::Duration::from_secs(15),
            client.matrix_auth().logout(),
        )
        .await
        {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                remote_logout_pending = true;
                // The token may still be valid on the server: remember it so
                // the next login of this account can retry the remote logout
                // (see finalize_pending) instead of leaving a ghost session.
                if let Some(session) = client.matrix_auth().session() {
                    PENDING_REMOTE_LOGOUTS.write().await.insert(
                        user_id.clone(),
                        (
                            session.tokens.access_token.to_string(),
                            client.homeserver().to_string(),
                        ),
                    );
                }
                app_log(
                    "warn",
                    "auth",
                    format!("Remote logout failed while removing {}: {e}", user_id),
                );
                warn!("Remote logout failed while removing {}: {e}", user_id);
            }
            Err(_) => {
                remote_logout_pending = true;
                if let Some(session) = client.matrix_auth().session() {
                    PENDING_REMOTE_LOGOUTS.write().await.insert(
                        user_id.clone(),
                        (
                            session.tokens.access_token.to_string(),
                            client.homeserver().to_string(),
                        ),
                    );
                }
                app_log(
                    "warn",
                    "auth",
                    format!(
                        "Remote logout timed out while removing {}, continuing locally",
                        user_id
                    ),
                );
                warn!(
                    "Remote logout timed out while removing {}, continuing locally",
                    user_id
                );
            }
        }
    }

    clear_account_runtime_state(&user_id).await;
    drop(client);
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let store_delete_result = delete_account_sdk_store(&data_dir, &user_id).await;

    // If this was the active account, switch to another or clear
    let mut active = ACTIVE_USER.write().await;
    let mut next_user_id = active.clone();
    if active.as_ref() == Some(&user_id) {
        let clients = CLIENTS.read().await;
        next_user_id = clients.iter().next().map(|(id, _)| id.clone());
        *active = next_user_id.clone();
    }
    drop(active);
    if removing_active {
        // Close the same start_sync installation race as logout().
        stop_sync_task(None, false).await;
        set_subscription_user(next_user_id).await;
    }

    Ok(AccountRemovalResult {
        cleanup_error: store_delete_result.err(),
        remote_logout_pending,
    })
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
    let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
    if CLIENTS.read().await.contains_key(&session.user_id) {
        return Ok(());
    }
    stop_sync_task(Some(&session.user_id), false).await;
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
        .request_config(bounded_request_config())
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
        let msg = format!("无效的用户 ID: {e}");
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
    let instance_id = NEXT_CLIENT_INSTANCE_ID.fetch_add(1, Ordering::Relaxed);
    let identity = ClientIdentity {
        user_id: session.user_id.clone(),
        instance_id,
    };
    install_verification_event_handler(&client, identity.clone());
    install_live_update_event_handlers(&client, identity.clone());
    let room_key_task = install_room_key_event_handler(&client, identity);

    // Add to multi-account store, dropping any runtime state bound to a
    // previous client for this account (e.g. after an engine rebuild).
    set_subscription_user(None).await;
    stop_sync_task(None, false).await;
    clear_account_runtime_state(&session.user_id).await;
    {
        let mut clients = CLIENTS.write().await;
        clients.insert(
            session.user_id.clone(),
            ClientEntry {
                client,
                data_dir: data_dir.clone(),
                instance_id,
                room_key_task,
            },
        );
    }

    // Set as active while closing the installation window for a sync builder
    // that started against the previously active account.
    {
        let mut active = ACTIVE_USER.write().await;
        *active = Some(session.user_id.clone());
    }
    stop_sync_task(None, false).await;
    set_subscription_user(Some(session.user_id.clone())).await;

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
        .ok_or_else(|| api_err("verification", "No active Matrix session".to_string()))?;
    Ok((
        session.meta.user_id.to_string(),
        session.meta.device_id.to_string(),
    ))
}

async fn current_verification_session() -> Result<(ClientLease, VerificationSession), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("verification", "No active client".to_string()))?;
    let session = VERIFICATION_SESSION
        .read()
        .await
        .clone()
        .ok_or_else(|| api_err("verification", "No active verification".to_string()))?;
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
    let client = get_client()
        .await
        .ok_or_else(|| api_err("verification", "No active client".to_string()))?;
    let (user_id, current_device_id) = active_session_meta(&client)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;

    // Refresh the identity first so the device list isn't limited to stale local data.
    client
        .encryption()
        .request_user_identity(&user_id)
        .await
        .map_err(|e| {
            api_err(
                "verification",
                format!("Failed to refresh encryption identity: {e}"),
            )
        })?;
    let devices = client
        .encryption()
        .get_user_devices(&user_id)
        .await
        .map_err(|e| api_err("verification", format!("Failed to load devices: {e}")))?;

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
    let client = get_client()
        .await
        .ok_or_else(|| api_err("verification", "No active client".to_string()))?;
    let (user_id, current_device_id) = active_session_meta(&client)?;
    if device_id == current_device_id {
        return Err(api_err(
            "verification",
            "Cannot verify the current device with itself".to_string(),
        ));
    }
    let user_id = matrix_sdk::ruma::UserId::parse(user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;
    let device_id = matrix_sdk::ruma::OwnedDeviceId::from(device_id);
    let device = client
        .encryption()
        .get_device(&user_id, &device_id)
        .await
        .map_err(|e| api_err("verification", format!("Failed to load device: {e}")))?
        .ok_or_else(|| api_err("verification", "Device is no longer available".to_string()))?;
    let request = device
        .request_verification_with_methods(vec![VerificationMethod::SasV1])
        .await
        .map_err(|e| {
            api_err(
                "verification",
                format!("Failed to request verification: {e}"),
            )
        })?;

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
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;
    let request = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await
        .ok_or_else(|| {
            api_err(
                "verification",
                "Verification request is no longer available".to_string(),
            )
        })?;
    request
        .accept_with_methods(vec![VerificationMethod::SasV1])
        .await
        .map_err(|e| {
            api_err(
                "verification",
                format!("Failed to accept verification: {e}"),
            )
        })?;
    if let Some(active) = VERIFICATION_SESSION.write().await.as_mut() {
        active.accepted = true;
    }
    Ok(())
}

#[frb]
pub async fn get_device_verification_status() -> Result<Option<DeviceVerificationStatus>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("verification", "No active client".to_string()))?;
    let Some(session) = VERIFICATION_SESSION.read().await.clone() else {
        return Ok(None);
    };
    let user_id = matrix_sdk::ruma::UserId::parse(&session.user_id)
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;

    let request = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await;

    if session.accepted {
        if let Some(request) = request.as_ref() {
            if request.is_ready() && request.we_started() {
                request.start_sas().await.map_err(|e| {
                    api_err(
                        "verification",
                        format!("Failed to start emoji verification: {e}"),
                    )
                })?;
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
            sas.accept().await.map_err(|e| {
                api_err(
                    "verification",
                    format!("Failed to accept emoji verification: {e}"),
                )
            })?;
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
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;
    let sas = client
        .encryption()
        .get_verification(&user_id, &session.flow_id)
        .await
        .and_then(Verification::sas)
        .ok_or_else(|| {
            api_err(
                "verification",
                "Emoji verification is not ready".to_string(),
            )
        })?;
    sas.confirm().await.map_err(|e| {
        api_err(
            "verification",
            format!("Failed to confirm verification: {e}"),
        )
    })?;

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
        .map_err(|e| api_err("verification", format!("无效的用户 ID: {e}")))?;
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
        .map_err(|e| {
            api_err(
                "verification",
                format!("Failed to cancel verification: {e}"),
            )
        })?;
    } else if let Some(request) = client
        .encryption()
        .get_verification_request(&user_id, &session.flow_id)
        .await
    {
        request.cancel().await.map_err(|e| {
            api_err(
                "verification",
                format!("Failed to cancel verification: {e}"),
            )
        })?;
    }
    clear_verification_session_if(&session.flow_id).await;
    Ok(())
}

#[frb]
pub async fn get_encryption_recovery_info() -> Result<EncryptionRecoveryInfo, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("encryption", "No active client".to_string()))?;
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
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let value = recovery_key_or_passphrase.trim();
    if value.is_empty() {
        return Err(api_err(
            "encryption",
            "Recovery key or passphrase is empty".to_string(),
        ));
    }
    let client = get_client()
        .await
        .ok_or_else(|| api_err("encryption", "No active client".to_string()))?;
    client
        .encryption()
        .recovery()
        .recover(value)
        .await
        .map_err(|e| {
            api_err(
                "encryption",
                format!("Failed to recover encryption data: {e}"),
            )
        })?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn enable_encryption_recovery(passphrase: Option<String>) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("encryption", "No active client".to_string()))?;
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
    result.map_err(|e| {
        api_err(
            "encryption",
            format!("Failed to enable encryption recovery: {e}"),
        )
    })
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
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    if !sync_generation_is_active(generation, &user_id).await {
        return Err(api_err(
            "sync",
            "Active account changed before syncing.".to_string(),
        ));
    }
    let hs = client.homeserver().to_string();
    app_log(
        "info",
        "sync",
        format!(
            "sync_once: starting for user {} (homeserver: {hs})",
            user_id
        ),
    );
    set_connection_status_for_generation(generation, ConnectionStatus::Connecting);

    if let Err(error) = client.event_cache().subscribe() {
        set_connection_status_for_generation(generation, ConnectionStatus::Disconnected);
        return Err(api_err(
            "sync",
            format!("Failed to subscribe to the event cache: {error}"),
        ));
    }

    let result = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        SYNC_EVENT_GENERATION.scope(
            generation,
            client.sync_once(matrix_sdk::config::SyncSettings::default()),
        ),
    )
    .await;

    if !sync_generation_is_active(generation, &user_id).await {
        return Err(api_err(
            "sync",
            "Active account changed while syncing.".to_string(),
        ));
    }

    match result {
        Ok(Ok(_)) => {
            app_log(
                "info",
                "sync",
                format!("sync_once: completed for user {}", user_id),
            );
            set_connection_status_for_generation(generation, ConnectionStatus::Connected);
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
            Ok(())
        }
        Ok(Err(e)) => {
            let msg = format!("sync_once: failed for user {}: {e}", user_id);
            app_log("error", "sync", msg.clone());
            set_connection_status_for_generation(generation, ConnectionStatus::Disconnected);
            Err(format!("同步失败: {e}"))
        }
        Err(_) => {
            let msg = format!(
                "sync_once: timed out after 10s for user {} (homeserver: {hs})",
                user_id
            );
            app_log("error", "sync", msg.clone());
            set_connection_status_for_generation(generation, ConnectionStatus::Disconnected);
            Err("同步超时（10 秒），请检查网络连接与服务器地址。".to_string())
        }
    }
}

/// Start a Sliding Sync loop for real-time updates.
/// Falls back to traditional sync_once loop if Sliding Sync is unavailable.
#[frb]
pub async fn start_sync() -> Result<(), String> {
    // A fresh, explicit start (app launch, manual reconnect) resets any
    // earlier degrade decision so a recovered server can use Sliding Sync
    // again. In-session upgrades from the traditional loop do not clear it.
    {
        let mut degraded = SYNC_DEGRADED_ACCOUNTS.write().await;
        degraded.clear();
    }
    start_sync_internal(false).await
}

/// Shared implementation behind [`start_sync`]. `force_traditional` is used
/// by the sync loops themselves when they decide to switch modes at runtime:
/// a Sliding Sync loop that fails repeatedly degrades to the traditional
/// loop, and the traditional loop re-probes for MSC3575 support and upgrades
/// back — the probe (and the /versions request it makes) is skipped when
/// forcing the traditional mode to avoid a pointless round-trip.
fn start_sync_internal(
    force_traditional: bool,
) -> std::pin::Pin<Box<dyn futures_util::Future<Output = Result<(), String>> + Send + 'static>> {
    Box::pin(async move {
        let client = get_client().await.ok_or_else(|| {
            app_log("error", "sync", "start_sync: no client created".to_string());
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

        let generation = stop_sync_task(None, true).await;
        if !sync_generation_is_active(generation, &user_id).await {
            return Err(api_err(
                "sync",
                "Active account changed while starting sync.".to_string(),
            ));
        }
        if let Err(error) = client.event_cache().subscribe() {
            set_connection_status_for_generation(generation, ConnectionStatus::Disconnected);
            return Err(api_err(
                "sync",
                format!("Failed to subscribe to the event cache: {error}"),
            ));
        }

        // Try Sliding Sync first
        let pending = if force_traditional {
            Err("Traditional sync mode forced by the running sync loop".to_string())
        } else {
            try_start_sliding_sync(client.clone(), generation, user_id.clone()).await
        };
        let pending = match pending {
            Ok(pending) => {
                app_log(
                    "info",
                    "sync",
                    format!("start_sync: Sliding Sync started for user {}", user_id),
                );
                pending
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
                // Spawn with a bare `Client` (Deref'd out of the lease): the
                // lease holds the SYNC_LIFECYCLE read lock, and this loop can
                // outlive start_sync_internal — holding the guard here would
                // deadlock every account switch/logout/removal (they take the
                // write lock) until the loop exits.
                let loop_client = client.clone();
                let (start, start_rx) = tokio::sync::oneshot::channel();
                let handle = tokio::spawn(async move {
                    if start_rx.await.is_err() {
                        return;
                    }
                    SYNC_EVENT_GENERATION
                        .scope(generation, async move {
                            app_log(
                                "info",
                                "sync",
                                format!("Traditional sync loop started for user {}", loop_user_id),
                            );
                            // Re-probe for MSC3575 after a few successful syncs.
                            // The initial probe may have failed because /versions
                            // was unreachable (server up but network flaky at
                            // startup); upgrading back to Sliding Sync restores
                            // receipt push and the room subscription extension.
                            let mut successful_syncs: u32 = 0;
                            loop {
                                if !sync_generation_is_active(generation, &loop_user_id).await {
                                    break;
                                }
                                set_connection_status_for_generation(
                                    generation,
                                    ConnectionStatus::Updating,
                                );
                                match loop_client
                                    .sync_once(matrix_sdk::config::SyncSettings::default())
                                    .await
                                {
                                    Ok(_) => {
                                        if !sync_generation_is_active(generation, &loop_user_id)
                                            .await
                                        {
                                            break;
                                        }
                                        app_log(
                                            "info",
                                            "sync",
                                            "Traditional sync completed".to_string(),
                                        );
                                        set_connection_status_for_generation(
                                            generation,
                                            ConnectionStatus::Connected,
                                        );
                                        notify_sync_event_for_generation(
                                            generation,
                                            SyncEvent::SyncCompleted,
                                        );
                                        successful_syncs += 1;
                                        // Only upgrade back to Sliding Sync when
                                        // this session never degraded away from it
                                        // (the probe was flaky at startup). After
                                        // an explicit degrade, re-probing would
                                        // ping-pong: fail 5x -> traditional ->
                                        // probe OK -> sliding -> fail 5x -> ...
                                        let degraded = SYNC_DEGRADED_ACCOUNTS
                                            .read()
                                            .await
                                            .contains(&loop_user_id);
                                        if successful_syncs >= 10
                                            && !degraded
                                            && !loop_client
                                                .available_sliding_sync_versions()
                                                .await
                                                .is_empty()
                                        {
                                            app_log(
                                                "info",
                                                "sync",
                                                "Sliding Sync support detected; upgrading loop"
                                                    .to_string(),
                                            );
                                            // Switch mode by restarting the whole
                                            // sync task (this task ends first, so
                                            // the restart is not self-aborting).
                                            // Fire-and-forget: the restarted task
                                            // stops this one via stop_sync_task.
                                            let _handle = tokio::spawn(async move {
                                                let _ = start_sync_internal(false).await;
                                            });
                                            break;
                                        }
                                    }
                                    Err(e) => {
                                        if !sync_generation_is_active(generation, &loop_user_id)
                                            .await
                                        {
                                            break;
                                        }
                                        app_log(
                                            "error",
                                            "sync",
                                            format!("Traditional sync error: {e}"),
                                        );
                                        set_connection_status_for_generation(
                                            generation,
                                            ConnectionStatus::Disconnected,
                                        );
                                        successful_syncs = 0;
                                        interruptible_retry_sleep(
                                            generation,
                                            &loop_user_id,
                                            std::time::Duration::from_secs(5),
                                        )
                                        .await;
                                    }
                                }
                            }
                        })
                        .await;
                });
                PendingSyncTask { handle, start }
            }
        };

        if !sync_generation_is_active(generation, &user_id).await {
            pending.handle.abort();
            clear_published_sync(generation).await;
            return Err(api_err(
                "sync",
                "Active account changed while starting sync.".to_string(),
            ));
        }

        let mut current_task = SYNC_TASK.lock().await;
        if !sync_generation_is_active(generation, &user_id).await {
            pending.handle.abort();
            drop(current_task);
            clear_published_sync(generation).await;
            return Err(api_err(
                "sync",
                "Active account changed while starting sync.".to_string(),
            ));
        }
        if let Some(running) = current_task.take() {
            running.handle.abort();
        }
        *current_task = Some(SyncTask {
            user_id,
            generation,
            handle: pending.handle,
        });
        let _ = pending.start.send(());
        Ok(())
    })
}

/// Try to set up Sliding Sync with the SDK's built-in support.
async fn try_start_sliding_sync(
    client: Client,
    generation: u64,
    user_id: String,
) -> Result<PendingSyncTask, String> {
    use futures_util::StreamExt;
    use matrix_sdk::ruma::events::StateEventType as RoomStateType;
    use matrix_sdk::sliding_sync::{SlidingSync, SlidingSyncList, SlidingSyncMode, Version};

    // Probe the server before committing to Sliding Sync. `build()` below is
    // purely local and `Version::Native` skips the version check, so without
    // this probe a server without MSC3575 (matrix.org, mozilla.org, …) would
    // fail on the first sync request and then retry forever in the rebuild
    // loop instead of falling back to the traditional sync loop. The probe
    // also returns empty when /versions is unreachable, in which case the
    // traditional loop is the safer choice anyway.
    if client.available_sliding_sync_versions().await.is_empty() {
        return Err("Homeserver does not advertise Sliding Sync (MSC3575) support".to_string());
    }

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
                        // Keep normal member state lazy; knock approvals query
                        // the authoritative /members endpoint on demand.
                        (RoomStateType::RoomMember, "$LAZY".to_owned()),
                        (RoomStateType::RoomMember, "$ME".to_owned()),
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

    // The loop waits until start_sync installs its handle in SYNC_TASK. This
    // makes every response-processing task reachable by account transitions.
    let (start, start_rx) = tokio::sync::oneshot::channel();
    let handle = tokio::spawn(async move {
        if start_rx.await.is_err() {
            return;
        }
        SYNC_EVENT_GENERATION
            .scope(generation, async move {
                app_log("info", "sync", "Sliding Sync loop started".to_string());
                let mut consecutive_failures: u32 = 0;
                'rebuild: loop {
                    if !sync_generation_is_active(generation, &user_id).await {
                        break;
                    }
                    let sliding_sync = match build_sliding_sync(&client).await {
                        Ok(sync) => sync,
                        Err(e) => {
                            if !sync_generation_is_active(generation, &user_id).await {
                                break;
                            }
                            app_log("error", "sync", format!("Sliding Sync rebuild failed: {e}"));
                            set_connection_status_for_generation(
                                generation,
                                ConnectionStatus::Disconnected,
                            );
                            consecutive_failures += 1;
                            if consecutive_failures >= DEGRADE_AFTER_FAILURES {
                                degrade_to_traditional_sync(generation, &user_id).await;
                                break;
                            }
                            interruptible_retry_sleep(
                                generation,
                                &user_id,
                                std::time::Duration::from_secs(5),
                            )
                            .await;
                            continue;
                        }
                    };
                    if !sync_generation_is_active(generation, &user_id).await {
                        break;
                    }
                    // Atomically publish the live instance and replay mounted rooms'
                    // subscriptions onto it. The old instance (and its sticky
                    // subscriptions) is gone after a reconnect, so without replay the
                    // mounted rooms would stop receiving receipt deltas until re-entry.
                    // subscribe_to_rooms is synchronous, so we do it
                    // under the same lock to keep desired/active consistent.
                    let mut sub_state = ROOM_SUBSCRIPTION.lock().await;
                    if !sync_generation_is_active(generation, &user_id).await {
                        drop(sub_state);
                        break;
                    }
                    sub_state.active = Some(sliding_sync.clone());
                    sub_state.active_generation = Some(generation);
                    for room_id in sub_state.desired.keys() {
                        if let Ok(parsed) = matrix_sdk::ruma::RoomId::parse(room_id.as_str()) {
                            sliding_sync.subscribe_to_rooms(
                                &[&parsed],
                                Some(live_room_subscription()),
                                false,
                            );
                        }
                    }
                    drop(sub_state);

                    let stream = sliding_sync.sync();
                    futures_util::pin_mut!(stream);
                    let mut received_update = false;
                    while let Some(update) = stream.next().await {
                        if !sync_generation_is_active(generation, &user_id).await {
                            clear_published_sync(generation).await;
                            return;
                        }
                        match update {
                            Ok(summary) => {
                                received_update = true;
                                app_log(
                                    "info",
                                    "sync",
                                    format!("Sliding Sync update: {} rooms", summary.rooms.len()),
                                );
                                set_connection_status_for_generation(
                                    generation,
                                    ConnectionStatus::Connected,
                                );
                                notify_sync_event_for_generation(
                                    generation,
                                    SyncEvent::SyncCompleted,
                                );
                                consecutive_failures = 0;
                            }
                            Err(e) => {
                                app_log("error", "sync", format!("Sliding Sync error: {e}"));
                                set_connection_status_for_generation(
                                    generation,
                                    ConnectionStatus::Disconnected,
                                );
                                // The instance has failed; drop the published handle
                                // so subscribe/unsubscribe calls during the retry
                                // delay don't mutate a stale, soon-discarded instance.
                                clear_published_sync(generation).await;
                                consecutive_failures += 1;
                                if consecutive_failures >= DEGRADE_AFTER_FAILURES {
                                    degrade_to_traditional_sync(generation, &user_id).await;
                                    break 'rebuild;
                                }
                                interruptible_retry_sleep(
                                    generation,
                                    &user_id,
                                    std::time::Duration::from_secs(5),
                                )
                                .await;
                                continue 'rebuild;
                            }
                        }
                    }
                    if !sync_generation_is_active(generation, &user_id).await {
                        clear_published_sync(generation).await;
                        break;
                    }
                    app_log(
                        "warn",
                        "sync",
                        "Sliding Sync stream ended; restarting".to_string(),
                    );
                    set_connection_status_for_generation(
                        generation,
                        ConnectionStatus::Disconnected,
                    );
                    // The stream ended (e.g. server closed the connection); the
                    // instance is no longer live, so clear the handle before the
                    // retry delay to avoid routing room subscriptions to it.
                    clear_published_sync(generation).await;
                    consecutive_failures =
                        failures_after_stream_end(consecutive_failures, received_update);
                    if consecutive_failures >= DEGRADE_AFTER_FAILURES {
                        degrade_to_traditional_sync(generation, &user_id).await;
                        break;
                    }
                    interruptible_retry_sleep(
                        generation,
                        &user_id,
                        std::time::Duration::from_secs(1),
                    )
                    .await;
                }
                clear_published_sync(generation).await;
            })
            .await;
    });

    Ok(PendingSyncTask { handle, start })
}

/// Hand the sync loop over to the traditional mode by restarting the whole
/// sync task. Called from inside the running loop, so it must not touch the
/// loop's own generation bookkeeping; the restarted `start_sync_internal`
/// stops the current task via `stop_sync_task` and installs a fresh
/// traditional loop.
async fn degrade_to_traditional_sync(generation: u64, user_id: &str) {
    app_log(
        "warn",
        "sync",
        format!(
            "Sliding Sync failing repeatedly (generation {generation}); degrading to traditional sync"
        ),
    );
    {
        let mut degraded = SYNC_DEGRADED_ACCOUNTS.write().await;
        degraded.insert(user_id.to_string());
    }
    clear_published_sync(generation).await;
    // Fire-and-forget: the restarted task stops this one via stop_sync_task.
    // Re-check the active account inside the spawn: if the user switched
    // accounts while this degrade was in flight, restarting sync now would
    // stop the NEW account's (possibly healthy) loop and pin it to
    // traditional mode. The degraded marker stays — the next explicit
    // start_sync() clears it and re-probes Sliding Sync for that account.
    let degraded_user_id = user_id.to_string();
    let _handle = tokio::spawn(async move {
        let active_user = ACTIVE_USER.read().await.clone();
        if active_user.as_deref() != Some(degraded_user_id.as_str()) {
            app_log(
                "info",
                "sync",
                format!(
                    "Skipping degrade restart for {degraded_user_id}: the account is no longer active"
                ),
            );
            return;
        }
        let _ = start_sync_internal(true).await;
    });
}

// Consecutive stream/rebuild failures above this threshold
// degrade to the traditional sync loop instead of retrying
// forever: a server that advertises MSC3575 but fails every
// request (or a proxy mangling the endpoint) must not pin the
// app to an unusable sync path for the whole session.
const DEGRADE_AFTER_FAILURES: u32 = 5;

/// Failure accounting for a Sliding Sync stream that ended on its own
/// (the server closed the connection without an error). A round that
/// delivered at least one update counts as a success — the Ok branch
/// already reset the counter — while a stream that ended without any
/// update counts as a failure, like the Err branch.
fn failures_after_stream_end(consecutive_failures: u32, received_update: bool) -> u32 {
    if received_update {
        consecutive_failures
    } else {
        consecutive_failures + 1
    }
}

fn lagged_sync_event() -> SyncEvent {
    SyncEvent::FullRefreshRequired
}

#[cfg(test)]
mod sync_event_tests {
    use super::{
        failures_after_stream_end, lagged_sync_event, SyncEvent, DEGRADE_AFTER_FAILURES,
        SYNC_EVENT_GENERATION,
    };

    #[test]
    fn lagged_receivers_request_a_full_refresh() {
        assert!(matches!(
            lagged_sync_event(),
            SyncEvent::FullRefreshRequired
        ));
    }

    #[test]
    fn stream_end_without_updates_accumulates_failures_until_degrade() {
        let mut consecutive_failures = 0;
        for expected in 1..=DEGRADE_AFTER_FAILURES {
            consecutive_failures = failures_after_stream_end(consecutive_failures, false);
            assert_eq!(consecutive_failures, expected);
        }
        // After DEGRADE_AFTER_FAILURES dataless stream ends, the loop's
        // degrade check fires and hands over to traditional sync.
        assert!(consecutive_failures >= DEGRADE_AFTER_FAILURES);
    }

    #[test]
    fn stream_end_after_updates_keeps_the_reset_counter() {
        // The Ok(summary) branch already reset the counter this round, so a
        // stream that delivered updates and then ended is not a failure.
        assert_eq!(failures_after_stream_end(0, true), 0);
    }

    #[tokio::test]
    async fn sync_event_generation_is_bound_to_the_processing_future() {
        assert!(SYNC_EVENT_GENERATION.try_with(|_| ()).is_err());

        let generation = SYNC_EVENT_GENERATION
            .scope(42, async {
                SYNC_EVENT_GENERATION
                    .try_with(|generation| *generation)
                    .unwrap()
            })
            .await;

        assert_eq!(generation, 42);
        assert!(SYNC_EVENT_GENERATION.try_with(|_| ()).is_err());
    }
}

/// Stream real-time sync events from Rust → Dart.
/// Call this once on app start and listen for updates.
/// `FullRefreshRequired` means specific events were dropped and all
/// interested views must refresh.
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
                    if sink.add(lagged_sync_event()).is_err() {
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
    subscription_id: String,
    handle: tokio::task::JoinHandle<()>,
}

static TYPING_TASK: Lazy<tokio::sync::Mutex<Option<TypingTask>>> =
    Lazy::new(|| tokio::sync::Mutex::new(None));
static NEXT_TYPING_SUBSCRIPTION_ID: AtomicU64 = AtomicU64::new(1);

fn take_typing_task_for_owner(
    task: &mut Option<TypingTask>,
    room_id: &str,
    subscription_id: &str,
) -> Option<TypingTask> {
    if task.as_ref().is_some_and(|active| {
        active.room_id == room_id && active.subscription_id == subscription_id
    }) {
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
    std::thread::spawn(move || loop {
        match rx.blocking_recv() {
            Ok(event) => {
                if sink.add(event).is_err() {
                    break; // Dart side disconnected
                }
            }
            // A slow Dart side can overflow the broadcast buffer; drop the
            // stale backlog and keep listening instead of dying.
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    });
}

/// Begin listening for typing notifications in `room_id`. Any previous
/// subscription for another room is cancelled first (only one room is
/// tracked at a time). Call `unsubscribe_typing` when leaving the room.
#[frb]
pub async fn subscribe_typing_for_room(
    room_id: String,
    account_user_id: Option<String>,
) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("typing", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    let subscription_id = NEXT_TYPING_SUBSCRIPTION_ID
        .fetch_add(1, Ordering::Relaxed)
        .to_string();
    let (_subscription_user, mut task) = lock_subscription_state(
        &SUBSCRIPTION_USER,
        &TYPING_TASK,
        account_user_id.as_deref(),
        "Typing subscription belongs to an inactive account",
    )
    .await?;
    if let Some(prev) = task.take() {
        prev.handle.abort();
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

    *task = Some(TypingTask {
        room_id,
        subscription_id: subscription_id.clone(),
        handle,
    });
    Ok(subscription_id)
}

/// Stop tracking typing notifications (e.g. when leaving the room screen).
#[frb]
pub async fn unsubscribe_typing(room_id: String, subscription_id: String) {
    let mut task = TYPING_TASK.lock().await;
    if let Some(task) = take_typing_task_for_owner(&mut task, &room_id, &subscription_id) {
        task.handle.abort();
    }
}

#[cfg(test)]
mod typing_subscription_tests {
    use super::{take_typing_task_for_owner, TypingTask};

    #[tokio::test]
    async fn stale_unsubscribe_does_not_cancel_a_newer_owner() {
        let handle = tokio::spawn(std::future::pending());
        let mut task = Some(TypingTask {
            room_id: "!current:example.org".to_string(),
            subscription_id: "new-owner".to_string(),
            handle,
        });

        assert!(
            take_typing_task_for_owner(&mut task, "!current:example.org", "old-owner",).is_none()
        );
        assert_eq!(task.as_ref().unwrap().room_id, "!current:example.org");
        assert_eq!(task.as_ref().unwrap().subscription_id, "new-owner",);

        task.take().unwrap().handle.abort();
    }
}

fn live_room_subscription(
) -> matrix_sdk::ruma::api::client::sync::sync_events::v5::request::RoomSubscription {
    use matrix_sdk::ruma::{events::StateEventType, UInt};

    let mut subscription =
        matrix_sdk::ruma::api::client::sync::sync_events::v5::request::RoomSubscription::default();
    subscription.timeline_limit = UInt::from(50u32);
    subscription.required_state = vec![(StateEventType::RoomPinnedEvents, String::new())];
    subscription
}

#[cfg(test)]
mod live_room_subscription_tests {
    use super::live_room_subscription;
    use matrix_sdk::ruma::events::StateEventType;

    #[test]
    fn requests_pinned_event_state() {
        let subscription = live_room_subscription();

        assert_eq!(
            subscription.required_state,
            vec![(StateEventType::RoomPinnedEvents, String::new())]
        );
    }
}

/// Subscribe to the given room in the Sliding Sync instance so that it is
/// included in every sync roundtrip, ensuring read-receipt deltas and pinned
/// state are always delivered. Call when entering a room screen.
///
/// If Sliding Sync is not yet ready (startup race / account switch), the
/// desire is recorded and applied automatically once the sync loop publishes
/// an instance; this function never fails for that reason.
///
/// `desired`/`active` are updated under a single lock so concurrent calls
/// can't interleave (a late-finishing old subscribe can't overwrite a newer
/// room).
#[frb]
pub async fn subscribe_room_for_receipts(
    room_id: String,
    account_user_id: Option<String>,
) -> Result<String, String> {
    let parsed = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| api_err("sync", format!("无效的房间 ID: {e}")))?;
    let subscription_id = NEXT_ROOM_SUBSCRIPTION_ID
        .fetch_add(1, Ordering::Relaxed)
        .to_string();
    let (_subscription_user, mut state) = lock_subscription_state(
        &SUBSCRIPTION_USER,
        &ROOM_SUBSCRIPTION,
        account_user_id.as_deref(),
        "Room subscription belongs to an inactive account",
    )
    .await?;
    let first_subscriber = state.add_desired(&room_id, subscription_id.clone());
    if first_subscriber {
        if let Some(sliding_sync) = state.active.as_ref() {
            sliding_sync.subscribe_to_rooms(&[&parsed], Some(live_room_subscription()), true);
        }
    }
    Ok(subscription_id)
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
pub async fn unsubscribe_room_for_receipts(
    room_id: String,
    subscription_id: String,
) -> Result<(), String> {
    let parsed = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| api_err("sync", format!("无效的房间 ID: {e}")))?;
    let mut state = ROOM_SUBSCRIPTION.lock().await;
    let last_subscriber = state.remove_desired(&room_id, &subscription_id);
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
    let mut server_name = url.host_str()?.to_owned();
    // Keep the port (e.g. media.example:8448): self-hosted media servers on
    // non-default ports would otherwise resolve to a URL that 404s.
    if let Some(port) = url.port() {
        server_name.push(':');
        server_name.push_str(&port.to_string());
    }
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
    let mut server_name = url.host_str()?.to_owned();
    // Keep the port (e.g. media.example:8448): self-hosted media servers on
    // non-default ports would otherwise resolve to a URL that 404s.
    if let Some(port) = url.port() {
        server_name.push(':');
        server_name.push_str(&port.to_string());
    }
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
#[derive(Clone, Debug)]
struct MediaClientIdentity {
    user_id: String,
    instance_id: u64,
}

async fn media_client_identity(client: &Client) -> Result<MediaClientIdentity, String> {
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("media", "No active user".to_string()))?
        .to_string();
    let instance_id = CLIENTS
        .read()
        .await
        .get(&user_id)
        .map(|entry| entry.instance_id)
        .ok_or_else(|| api_err("media", "Active account is no longer available".to_string()))?;
    Ok(MediaClientIdentity {
        user_id,
        instance_id,
    })
}

async fn reacquire_media_client(identity: &MediaClientIdentity) -> Result<ClientLease, String> {
    let client = get_client().await.ok_or_else(|| {
        api_err(
            "media",
            "Media transfer completed, but the account is logged out.".to_string(),
        )
    })?;
    ensure_account_matches(&client, &identity.user_id).map_err(|_| {
        api_err(
            "media",
            "Media transfer completed, but the active account changed.".to_string(),
        )
    })?;
    let current_instance_id = CLIENTS
        .read()
        .await
        .get(&identity.user_id)
        .map(|entry| entry.instance_id);
    if current_instance_id != Some(identity.instance_id) {
        return Err(api_err(
            "media",
            "Media transfer completed, but the account session changed.".to_string(),
        ));
    }
    Ok(client)
}

#[frb]
pub async fn download_media_bytes(mxc_url: String) -> Option<Vec<u8>> {
    let client = get_client().await?;
    let source = matrix_sdk::ruma::events::room::MediaSource::Plain(
        matrix_sdk::ruma::OwnedMxcUri::try_from(mxc_url.as_str()).ok()?,
    );
    let url = media_download_url(&client, &source).ok()?;
    let identity = media_client_identity(&client).await.ok()?;
    let session = client.matrix_auth().session()?;
    let http_client = client.http_client().clone();
    drop(client);

    match tokio::time::timeout(MEDIA_DOWNLOAD_TOTAL_TIMEOUT, async move {
        http_client
            .get(url)
            .bearer_auth(session.tokens.access_token)
            .send()
            .await?
            .error_for_status()?
            .bytes()
            .await
    })
    .await
    {
        Ok(Ok(response)) => {
            reacquire_media_client(&identity).await.ok()?;
            app_log(
                "info",
                "media",
                format!(
                    "download_media_bytes: {} bytes for {}",
                    response.len(),
                    mxc_url
                ),
            );
            Some(response.to_vec())
        }
        Ok(Err(e)) => {
            app_log(
                "error",
                "media",
                format!("download_media_bytes failed: {e}"),
            );
            None
        }
        Err(_) => {
            app_log(
                "error",
                "media",
                format!("download_media_bytes timed out for {mxc_url}"),
            );
            None
        }
    }
}

fn media_download_limit(max_size_bytes: i32) -> Result<usize, String> {
    usize::try_from(max_size_bytes)
        .ok()
        .filter(|limit| *limit > 0)
        .ok_or_else(|| {
            api_err(
                "media",
                "Media download limit must be positive.".to_string(),
            )
        })
}

fn ensure_media_content_length(content_length: Option<u64>, limit: usize) -> Result<(), String> {
    if content_length.is_some_and(|length| length > limit as u64) {
        return Err(api_err(
            "media",
            format!("Media exceeds the {limit}-byte download limit."),
        ));
    }
    Ok(())
}

fn append_media_chunk(content: &mut Vec<u8>, chunk: &[u8], limit: usize) -> Result<(), String> {
    let next_length = content
        .len()
        .checked_add(chunk.len())
        .ok_or_else(|| api_err("media", "Media download is too large.".to_string()))?;
    if next_length > limit {
        return Err(api_err(
            "media",
            format!("Media exceeds the {limit}-byte download limit."),
        ));
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
    let mxc_url = url::Url::parse(&mxc_url)
        .map_err(|e| api_err("media", format!("Invalid media URL: {e}")))?;
    if mxc_url.scheme() != "mxc" {
        return Err(api_err(
            "media",
            "Media URL must use the mxc scheme.".to_string(),
        ));
    }
    let server_name = mxc_url
        .host_str()
        .filter(|server_name| !server_name.is_empty())
        .ok_or_else(|| api_err("media", "Media URL is missing a server name.".to_string()))?;
    let server_name = match mxc_url.port() {
        Some(port) => format!("{server_name}:{port}"),
        None => server_name.to_string(),
    };
    let media_id = mxc_url.path().trim_start_matches('/');
    if media_id.is_empty() {
        return Err(api_err(
            "media",
            "Media URL is missing a media ID.".to_string(),
        ));
    }

    let mut url = client.homeserver();
    url.set_query(None);
    url.set_fragment(None);
    let mut segments = url.path_segments_mut().map_err(|_| {
        api_err(
            "media",
            "Homeserver URL cannot contain path segments.".to_string(),
        )
    })?;
    segments.pop_if_empty();
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
        .map_err(|e| api_err("media", format!("Invalid encrypted media: {e}")))?;
    let mut decrypted = Vec::with_capacity(capacity);
    decryptor
        .by_ref()
        .take(limit as u64 + 1)
        .read_to_end(&mut decrypted)
        .map_err(|e| api_err("media", format!("Media decryption failed: {e}")))?;
    if decrypted.len() > limit {
        return Err(api_err(
            "media",
            format!("Media exceeds the {limit}-byte download limit."),
        ));
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

    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    let source: matrix_sdk::ruma::events::room::MediaSource =
        serde_json::from_str(&media_source_json)
            .map_err(|e| api_err("media", format!("Invalid media source: {e}")))?;
    let limit = media_download_limit(max_size_bytes)?;
    let url = media_download_url(&client, &source)?;
    let identity = media_client_identity(&client).await?;
    let session = client
        .matrix_auth()
        .session()
        .ok_or_else(|| api_err("media", "No authenticated session.".to_string()))?;
    let http_client = client.http_client().clone();
    drop(client);
    let content = tokio::time::timeout(MEDIA_DOWNLOAD_TOTAL_TIMEOUT, async move {
        let response = http_client
            .get(url)
            .bearer_auth(session.tokens.access_token)
            .send()
            .await
            .map_err(|e| api_err("media", format!("Media download failed: {e}")))?
            .error_for_status()
            .map_err(|e| api_err("media", format!("Media download failed: {e}")))?;
        ensure_media_content_length(response.content_length(), limit)?;

        let mut encrypted = Vec::new();
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk =
                chunk.map_err(|e| api_err("media", format!("Media download failed: {e}")))?;
            append_media_chunk(&mut encrypted, &chunk, limit)?;
        }

        match source {
            matrix_sdk::ruma::events::room::MediaSource::Encrypted(file) => {
                decrypt_media_bytes(encrypted, *file, limit)
            }
            matrix_sdk::ruma::events::room::MediaSource::Plain(_) => Ok(encrypted),
        }
    })
    .await
    .map_err(|_| {
        api_err(
            "media",
            "Media download timed out. Please retry.".to_string(),
        )
    })??;
    reacquire_media_client(&identity).await?;
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
        .ok_or_else(|| api_err("encryption", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    Ok(room
        .latest_encryption_state()
        .await
        .map(|state| state.is_encrypted())
        .unwrap_or(true))
}

#[frb]
pub async fn get_chat_rooms(
    ignored_user_ids: Option<Vec<String>>,
    authoritative: bool,
) -> Result<Vec<ChatRoom>, String> {
    let client = get_client().await.ok_or_else(|| {
        app_log(
            "error",
            "rooms",
            "get_chat_rooms: no client created".to_string(),
        );
        "No client created.".to_string()
    })?;
    let ignored_user_ids =
        ignored_user_ids.map(|ids| ids.into_iter().collect::<std::collections::HashSet<_>>());

    // Bounded like the other P0 reads: the room scan touches the shared
    // notification-settings instance while holding the client lease (the
    // instance itself is a local store read — push rules arrive via sync —
    // but the whole list build must stay bounded for the lease's sake).
    run_bounded(async move {
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

            let mut chat_room =
                room_to_chat_room(&room, ignored_user_ids.as_ref(), authoritative).await;
            if !room.is_space() {
                // `is_direct` covers both joined rooms (m.direct account data)
                // and invited rooms (the invite event's is_direct flag), so it
                // is the primary signal. Only fall back to a member-count
                // heuristic for JOINED rooms whose m.direct entry is absent —
                // and use members_no_sync (a pure store read): `members()`
                // would trigger a serial HTTP /members request per room,
                // stalling the whole room list behind the network. Invited and
                // knocked rooms never fall back: their cache holds only
                // stripped state (~1-2 members), so a large group invite would
                // be misclassified as a DM.
                let is_dm = if room.state() == matrix_sdk::RoomState::Joined {
                    match room.is_direct().await {
                        Ok(true) => true,
                        Ok(false) | Err(_) => is_dm_by_members(&room).await,
                    }
                } else {
                    room.is_direct().await.unwrap_or(false)
                };
                if is_dm {
                    chat_room.room_type = "dm".to_string();
                } else if room.state() == matrix_sdk::RoomState::Joined {
                    chat_room.room_type = "group".to_string();
                }
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
    })
    .await
}

fn get_last_message_info(room: &matrix_sdk::Room) -> (String, Option<String>, String, String) {
    let mut last_msg = "(暂无消息)".to_string();
    let mut last_time = String::new();
    let mut last_event_id = String::new();

    let latest_value = room.latest_event();
    if let matrix_sdk::latest_events::LatestEventValue::Remote(latest) = latest_value {
        let raw = latest.raw();
        if let Ok(any_ev) = raw.deserialize() {
            // Always record the latest event's timestamp for sorting, so that
            // rooms whose newest event isn't a text message (e.g. a reaction or
            // a state change) don't sink to the bottom of the list. The event
            // ID is the room's revision token: timestamps are millisecond
            // resolution and can collide between events.
            last_time = u64::from(any_ev.origin_server_ts().0).to_string();
            last_event_id = any_ev.event_id().to_string();

            if latest.kind.is_utd() {
                return (
                    "无法解密此消息".to_string(),
                    Some(any_ev.sender().to_string()),
                    last_time,
                    last_event_id,
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
                return (last_msg, Some(sender_id), last_time, last_event_id);
            }
        }
    }

    (last_msg, None, last_time, last_event_id)
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
            if let Some(rest) = after_first_line.strip_prefix('\n') {
                return rest.to_string();
            }
            if let Some(after_crlf) = after_first_line.strip_prefix("\r\n") {
                if let Some(rest) = after_crlf.strip_prefix('\n') {
                    return rest.to_string();
                }
                if let Some(rest) = after_crlf.strip_prefix("\r\n") {
                    return rest.to_string();
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
        matrix_sdk::ruma::html::HtmlSanitizerMode::Compat,
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
        matrix_sdk::ruma::html::HtmlSanitizerMode::Compat,
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
    fn matrix_links_survive_outgoing_and_incoming_sanitization() {
        let html = r#"<a href="matrix:u/alice:example.org">Alice</a>"#;
        let content = build_text_content(FormattedMessageInput {
            body: "Alice".to_string(),
            formatted_body: Some(html.to_string()),
            mentioned_user_ids: vec![],
            mentions_room: false,
        })
        .unwrap();
        let json = serde_json::to_value(&content).unwrap();
        assert!(json["formatted_body"]
            .as_str()
            .unwrap()
            .contains(r#"href="matrix:u/alice:example.org""#));

        let formatted = FormattedBody::html(html.to_string());
        let (_, incoming_html, _, _) = text_message_parts("Alice", Some(&formatted), None, false);
        assert!(incoming_html
            .as_deref()
            .unwrap()
            .contains(r#"href="matrix:u/alice:example.org""#));
    }

    #[test]
    fn spoilers_survive_outgoing_sanitization() {
        let content = build_text_content(FormattedMessageInput {
            body: "[Spoiler for plot twist]".to_string(),
            formatted_body: Some(
                r#"<span data-mx-spoiler="plot twist" onclick="bad()">Alice wins</span>"#
                    .to_string(),
            ),
            mentioned_user_ids: vec![],
            mentions_room: false,
        })
        .unwrap();
        let json = serde_json::to_value(&content).unwrap();
        let formatted = json["formatted_body"].as_str().unwrap();

        assert!(formatted.contains(r#"data-mx-spoiler="plot twist""#));
        assert!(formatted.contains("Alice wins"));
        assert!(!formatted.contains("onclick"));
    }

    #[test]
    fn formatting_without_visible_content_falls_back_to_plain_text() {
        let content = build_text_content(FormattedMessageInput {
            body: "image".to_string(),
            formatted_body: Some(r#"<p><img src="https://example.org/cat.png"></p>"#.to_string()),
            mentioned_user_ids: vec![],
            mentions_room: false,
        })
        .unwrap();
        let json = serde_json::to_value(&content).unwrap();

        assert_eq!(json["body"], "image");
        assert!(json.get("formatted_body").is_none(), "{json}");
    }

    #[test]
    fn mxc_images_remain_visible_formatted_content() {
        let content = build_text_content(FormattedMessageInput {
            body: "a cat".to_string(),
            formatted_body: Some(
                r#"<p><img src="mxc://example.org/cat" alt="a cat"></p>"#.to_string(),
            ),
            mentioned_user_ids: vec![],
            mentions_room: false,
        })
        .unwrap();
        let json = serde_json::to_value(&content).unwrap();

        assert_eq!(
            json["formatted_body"],
            r#"<p><img alt="a cat" src="mxc://example.org/cat"></p>"#
        );
    }

    #[test]
    fn matrix_links_survive_reply_fallback_removal() {
        let formatted = FormattedBody::html(
            r#"<mx-reply><blockquote>Earlier</blockquote></mx-reply><a href="matrix:u/alice:example.org">Alice</a>"#
                .to_string(),
        );
        let (_, html, _, _) = text_message_parts("Alice", Some(&formatted), None, true);

        let html = html.unwrap();
        assert!(!html.contains("mx-reply"));
        assert!(html.contains(r#"href="matrix:u/alice:example.org""#));
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
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    // Bounded like the other P0 calls: the load holds the client lease
    // (blocking logout/account switch) and pagination can run several
    // network attempts.
    run_bounded(async move { sdk_timeline::get_messages(&client, &room).await }).await
}

#[frb]
pub async fn get_sticker_packs(room_id: String) -> Result<Vec<StickerPack>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;

    let parsed_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| api_err("media", format!("无效的房间 ID: {e}")))?;
    let room = client
        .get_room(&parsed_room_id)
        .ok_or_else(|| api_err("media", format!("房间不存在: {room_id}")))?;

    let imported_room_packs = client
        .account()
        .account_data::<ruma::events::image_pack::ImagePackRoomsEventContent>()
        .await
        .map_err(|e| {
            api_err(
                "media",
                format!("Failed to load image-pack room mapping: {e}"),
            )
        })?
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
        .map_err(|e| api_err("media", format!("Failed to load user sticker pack: {e}")))?
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
            matrix_sdk::ruma::UserId::parse(user_id).map_err(|e| {
                api_err("rooms", format!("Invalid mentioned user ID {user_id}: {e}"))
            })?,
        );
    }
    Ok(mentions)
}

fn sanitized_html_has_visible_content(html: &str) -> bool {
    fn node_has_visible_content(node: matrix_sdk::ruma::html::NodeRef) -> bool {
        match node.data() {
            matrix_sdk::ruma::html::NodeData::Text(text) if !text.borrow().trim().is_empty() => {
                return true;
            }
            matrix_sdk::ruma::html::NodeData::Element(element) => {
                let name = element.name.local.as_ref();
                let attrs = element.attrs.borrow();
                if name == "hr"
                    || (name == "img" && attrs.iter().any(|attr| attr.name.local.as_ref() == "src"))
                    || attrs.iter().any(|attr| {
                        attr.name.local.as_ref() == "data-mx-maths" && !attr.value.trim().is_empty()
                    })
                {
                    return true;
                }
            }
            _ => {}
        }
        node.children().any(node_has_visible_content)
    }

    matrix_sdk::ruma::html::Html::parse(html)
        .children()
        .any(node_has_visible_content)
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
                matrix_sdk::ruma::html::HtmlSanitizerMode::Compat,
                matrix_sdk::ruma::html::RemoveReplyFallback::No,
            )
        })
        .filter(|html| sanitized_html_has_visible_content(html));
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
    account_user_id: String,
    room_id: String,
    message: FormattedMessageInput,
) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    let content = build_text_content(message)?;

    let response = room
        .send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send failed: {e}")))?;

    app_log("info", "rooms", format!("Message sent to {}", room_id));
    info!("Message sent to {}", room_id);
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(response.response.event_id.to_string())
}

fn poll_start_for_forward(
    content: &matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent,
) -> Result<matrix_sdk::ruma::events::poll::unstable_start::NewUnstablePollStartEventContent, String>
{
    use matrix_sdk::ruma::events::poll::unstable_start::UnstablePollStartEventContent;

    let UnstablePollStartEventContent::New(content) = content else {
        return Err(api_err(
            "rooms",
            "无法将投票编辑事件作为新投票转发".to_string(),
        ));
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
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let source_room = get_room_by_id(&client, &source_room_id)?;
    let target_room = get_room_by_id(&client, &target_room_id)?;
    let event_id = matrix_sdk::ruma::EventId::parse(event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;
    let timeline_event = source_room
        .event(&event_id, None)
        .await
        .map_err(|e| api_err("rooms", format!("Load message failed: {e}")))?;

    if timeline_event.kind.is_utd() {
        return Err(api_err("rooms", "无法转发未解密的消息".to_string()));
    }

    let event = timeline_event
        .raw()
        .deserialize()
        .map_err(|e| api_err("rooms", format!("Read message failed: {e}")))?;

    let event_id = match event {
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::RoomMessage(message),
        ) => {
            let Some(original) = message.as_original() else {
                return Err(api_err("rooms", "无法转发已撤回的消息".to_string()));
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
                .map_err(|e| api_err("rooms", format!("Forward failed: {e}")))?
                .response
                .event_id
                .to_string()
        }
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::Sticker(sticker),
        ) => {
            let Some(original) = sticker.as_original() else {
                return Err(api_err("rooms", "无法转发已撤回的贴纸".to_string()));
            };
            let mut content = original.content.clone();
            content.relates_to = None;
            target_room
                .send(content)
                .await
                .map_err(|e| api_err("rooms", format!("Forward failed: {e}")))?
                .response
                .event_id
                .to_string()
        }
        matrix_sdk::ruma::events::AnySyncTimelineEvent::MessageLike(
            matrix_sdk::ruma::events::AnySyncMessageLikeEvent::UnstablePollStart(poll),
        ) => {
            let Some(original) = poll.as_original() else {
                return Err(api_err("rooms", "无法转发已撤回的投票".to_string()));
            };
            let content = poll_start_for_forward(&original.content)?;
            target_room
                .send(content)
                .await
                .map_err(|e| api_err("rooms", format!("Forward failed: {e}")))?
                .response
                .event_id
                .to_string()
        }
        _ => return Err(api_err("rooms", "该消息类型暂不支持转发".to_string())),
    };

    app_log(
        "info",
        "rooms",
        format!("Message forwarded to {}", target_room_id),
    );
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: target_room_id,
        },
    );
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
        .map_err(|error| api_err("media", format!("Invalid MIME type: {error}")))
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
        return Err(api_err(
            "media",
            format!("Expected an image MIME type, got {mime_type}"),
        ));
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
        return Err(api_err(
            "media",
            format!("Expected a video MIME type, got {mime_type}"),
        ));
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

async fn upload_media_source(
    client: Client,
    encrypted: bool,
    mime_type: mime::Mime,
    data: Vec<u8>,
) -> Result<matrix_sdk::ruma::events::room::MediaSource, String> {
    use matrix_sdk::ruma::events::room::MediaSource;

    tokio::time::timeout(MEDIA_SEND_TOTAL_TIMEOUT, async move {
        if encrypted {
            let mut reader = Cursor::new(data.as_slice());
            let encrypted_file =
                client
                    .upload_encrypted_file(&mut reader)
                    .await
                    .map_err(|error| {
                        api_err("media", format!("Encrypted media upload failed: {error}"))
                    })?;
            Ok(MediaSource::Encrypted(Box::new(encrypted_file)))
        } else {
            let upload = client
                .media()
                .upload(&mime_type, data, None)
                .await
                .map_err(|error| api_err("media", format!("Media upload failed: {error}")))?;
            Ok(MediaSource::Plain(upload.content_uri))
        }
    })
    .await
    .map_err(|_| api_err("media", "Media upload timed out. Please retry.".to_string()))?
}

fn image_message_content(
    filename: String,
    mime_type: &mime::Mime,
    size: Option<matrix_sdk::ruma::UInt>,
    width: Option<matrix_sdk::ruma::UInt>,
    height: Option<matrix_sdk::ruma::UInt>,
    source: matrix_sdk::ruma::events::room::MediaSource,
) -> matrix_sdk::ruma::events::room::message::RoomMessageEventContent {
    use matrix_sdk::ruma::events::room::{
        message::{ImageMessageEventContent, MessageType, RoomMessageEventContent},
        ImageInfo,
    };

    let mut info = ImageInfo::new();
    info.mimetype = Some(mime_type.to_string());
    info.size = size;
    info.width = width;
    info.height = height;
    RoomMessageEventContent::new(MessageType::Image(
        ImageMessageEventContent::new(filename, source).info(Box::new(info)),
    ))
}

#[allow(clippy::too_many_arguments)]
fn video_message_content(
    filename: String,
    mime_type: &mime::Mime,
    size: Option<matrix_sdk::ruma::UInt>,
    width: Option<matrix_sdk::ruma::UInt>,
    height: Option<matrix_sdk::ruma::UInt>,
    duration: Option<matrix_sdk::ruma::time::Duration>,
    source: matrix_sdk::ruma::events::room::MediaSource,
) -> matrix_sdk::ruma::events::room::message::RoomMessageEventContent {
    use matrix_sdk::ruma::events::room::message::{
        MessageType, RoomMessageEventContent, VideoInfo, VideoMessageEventContent,
    };

    let mut info = VideoInfo::new();
    info.mimetype = Some(mime_type.to_string());
    info.size = size;
    info.width = width;
    info.height = height;
    info.duration = duration;
    RoomMessageEventContent::new(MessageType::Video(
        VideoMessageEventContent::new(filename, source).info(Box::new(info)),
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
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    let mime_type = image_mime_type(&filename, mime_type)?;
    let identity = media_client_identity(&client).await?;
    let encrypted = room
        .latest_encryption_state()
        .await
        .map_err(|error| api_err("media", format!("Check room encryption failed: {error}")))?
        .is_encrypted();
    let upload_client = client.client.clone();
    drop(room);
    drop(client);

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

    let image_size = matrix_sdk::ruma::UInt::new(image_data.len() as u64);
    let image_width = width
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64));
    let image_height = height
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64));
    let source =
        upload_media_source(upload_client, encrypted, mime_type.clone(), image_data).await?;
    let client = reacquire_media_client(&identity).await.map_err(|error| {
        api_err(
            "media",
            format!("Image uploaded, but the message was not sent: {error}"),
        )
    })?;
    let room = get_room_by_id(&client, &room_id).map_err(|error| {
        api_err(
            "media",
            format!("Image uploaded, but the room is unavailable: {error}"),
        )
    })?;
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let content = image_message_content(
        filename,
        &mime_type,
        image_size,
        image_width,
        image_height,
        source,
    );
    tokio::time::timeout(MEDIA_EVENT_SEND_TIMEOUT, room.send(content))
        .await
        .map_err(|_| {
            api_err(
                "media",
                "Image uploaded, but sending the message timed out.".to_string(),
            )
        })?
        .map_err(|e| api_err("media", format!("Send image message failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Image message sent to {}", room_id),
    );
    info!("Image message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
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
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    let mime_type = parse_supplied_mime_type(mime_type)?.unwrap_or(mime::APPLICATION_OCTET_STREAM);
    let file_size = size
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64))
        .or_else(|| matrix_sdk::ruma::UInt::new(file_data.len() as u64));
    let identity = media_client_identity(&client).await?;
    let encrypted = room
        .latest_encryption_state()
        .await
        .map_err(|error| api_err("media", format!("Check room encryption failed: {error}")))?
        .is_encrypted();
    let upload_client = client.client.clone();
    drop(room);
    drop(client);

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

    let source =
        upload_media_source(upload_client, encrypted, mime_type.clone(), file_data).await?;
    let client = reacquire_media_client(&identity).await.map_err(|error| {
        api_err(
            "media",
            format!("File uploaded, but the message was not sent: {error}"),
        )
    })?;
    let room = get_room_by_id(&client, &room_id).map_err(|error| {
        api_err(
            "media",
            format!("File uploaded, but the room is unavailable: {error}"),
        )
    })?;
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let content = file_message_content(filename, &mime_type, file_size, source);
    tokio::time::timeout(MEDIA_EVENT_SEND_TIMEOUT, room.send(content))
        .await
        .map_err(|_| {
            api_err(
                "media",
                "File uploaded, but sending the message timed out.".to_string(),
            )
        })?
        .map_err(|e| api_err("media", format!("Send file message failed: {e}")))?;

    app_log("info", "rooms", format!("File message sent to {}", room_id));
    info!("File message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
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
    let client = get_client()
        .await
        .ok_or_else(|| api_err("media", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    let mime_type = video_mime_type(&filename, mime_type)?;
    let identity = media_client_identity(&client).await?;
    let encrypted = room
        .latest_encryption_state()
        .await
        .map_err(|error| api_err("media", format!("Check room encryption failed: {error}")))?
        .is_encrypted();
    let upload_client = client.client.clone();
    drop(room);
    drop(client);

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

    let video_width = width
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64));
    let video_height = height
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64));
    let video_duration = duration_ms
        .filter(|value| *value > 0)
        .map(|value| matrix_sdk::ruma::time::Duration::from_millis(value as u64));
    let video_size = size
        .filter(|value| *value > 0)
        .and_then(|value| matrix_sdk::ruma::UInt::new(value as u64))
        .or_else(|| matrix_sdk::ruma::UInt::new(video_data.len() as u64));
    let source =
        upload_media_source(upload_client, encrypted, mime_type.clone(), video_data).await?;
    let client = reacquire_media_client(&identity).await.map_err(|error| {
        api_err(
            "media",
            format!("Video uploaded, but the message was not sent: {error}"),
        )
    })?;
    let room = get_room_by_id(&client, &room_id).map_err(|error| {
        api_err(
            "media",
            format!("Video uploaded, but the room is unavailable: {error}"),
        )
    })?;
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);
    let content = video_message_content(
        filename,
        &mime_type,
        video_size,
        video_width,
        video_height,
        video_duration,
        source,
    );
    tokio::time::timeout(MEDIA_EVENT_SEND_TIMEOUT, room.send(content))
        .await
        .map_err(|_| {
            api_err(
                "media",
                "Video uploaded, but sending the message timed out.".to_string(),
            )
        })?
        .map_err(|e| api_err("media", format!("Send video message failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Video message sent to {}", room_id),
    );
    info!("Video message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}

/// Validate the RFC 5870 subset supported by the attachment composer.
fn validated_geo_uri(value: &str) -> Result<String, String> {
    let value = value.trim();
    let uri = url::Url::parse(value)
        .map_err(|error| api_err("media", format!("Invalid geo URI: {error}")))?;
    if uri.scheme() != "geo" || uri.query().is_some() || uri.fragment().is_some() {
        return Err(api_err(
            "media",
            "Location must be a geo: URI without a query or fragment.".to_string(),
        ));
    }

    let coordinate_part = uri.path().split(';').next().unwrap_or_default();
    let coordinates = coordinate_part.split(',').collect::<Vec<_>>();
    if !(2..=3).contains(&coordinates.len()) {
        return Err(api_err(
            "media",
            "Location must contain latitude and longitude.".to_string(),
        ));
    }
    if coordinates
        .iter()
        .any(|coordinate| coordinate.contains(['e', 'E']))
    {
        return Err(api_err(
            "media",
            "Location coordinates must use decimal notation.".to_string(),
        ));
    }
    let latitude = coordinates[0]
        .parse::<f64>()
        .map_err(|_| api_err("media", "Invalid latitude.".to_string()))?;
    let longitude = coordinates[1]
        .parse::<f64>()
        .map_err(|_| api_err("media", "Invalid longitude.".to_string()))?;
    if !latitude.is_finite() || !(-90.0..=90.0).contains(&latitude) {
        return Err(api_err(
            "media",
            "Latitude must be between -90 and 90.".to_string(),
        ));
    }
    if !longitude.is_finite() || !(-180.0..=180.0).contains(&longitude) {
        return Err(api_err(
            "media",
            "Longitude must be between -180 and 180.".to_string(),
        ));
    }
    if coordinates.len() == 3
        && coordinates[2]
            .parse::<f64>()
            .ok()
            .filter(|altitude| altitude.is_finite())
            .is_none()
    {
        return Err(api_err("media", "Invalid altitude.".to_string()));
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
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let content = location_message_content(&body, &geo_uri)?;

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send location failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Location message sent to {}", room_id),
    );
    info!("Location message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
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
        return Err(api_err(
            "rooms",
            "A poll question cannot be empty.".to_string(),
        ));
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
        return Err(api_err(
            "rooms",
            "A poll needs between 2 and 20 answers.".to_string(),
        ));
    }
    if !(1..=answer_list.len()).contains(&max_selections) {
        return Err(api_err(
            "rooms",
            "A poll's maximum selections must match its answers.".to_string(),
        ));
    }
    let mut fallback = question.to_owned();
    for (index, answer) in answer_list.iter().enumerate() {
        fallback.push_str(&format!("\n{}. {}", index + 1, answer.text));
    }
    let poll_answers = UnstablePollAnswers::try_from(answer_list).map_err(|_| {
        api_err(
            "rooms",
            "A poll needs between 2 and 20 answers.".to_string(),
        )
    })?;

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
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let max_selections = usize::try_from(max_selections).map_err(|_| {
        api_err(
            "rooms",
            "A poll's maximum selections must be positive.".to_string(),
        )
    })?;
    let content = poll_start_content(&question, answers, disclosed, max_selections)?;

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send poll failed: {e}")))?;

    app_log("info", "rooms", format!("Poll message sent to {}", room_id));
    info!("Poll message sent to {}", room_id);

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}

fn validate_poll_answer_ids(answer_ids: &[String]) -> Result<(), String> {
    if answer_ids.is_empty()
        || answer_ids.len() > 20
        || answer_ids.iter().any(|answer_id| answer_id.is_empty())
        || answer_ids.iter().collect::<BTreeSet<_>>().len() != answer_ids.len()
    {
        return Err(api_err(
            "rooms",
            "A poll response needs 1 to 20 unique answer ids.".to_string(),
        ));
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
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    use matrix_sdk::ruma::events::poll::unstable_response::UnstablePollResponseEventContent;

    validate_poll_answer_ids(&answer_ids)?;
    let event_id = matrix_sdk::ruma::EventId::parse(poll_start_event_id.as_str())
        .map_err(|e| api_err("rooms", format!("Invalid poll event id: {e}")))?;

    let content = UnstablePollResponseEventContent::new(answer_ids, event_id);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Send poll response failed: {e}")))?;

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}

/// Close a poll so no further votes are accepted.
#[frb]
pub async fn end_poll(room_id: String, poll_start_event_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    use matrix_sdk::ruma::events::poll::unstable_end::UnstablePollEndEventContent;

    let event_id = matrix_sdk::ruma::EventId::parse(poll_start_event_id.as_str())
        .map_err(|e| api_err("rooms", format!("Invalid poll event id: {e}")))?;

    let content = UnstablePollEndEventContent::new("结束投票", event_id);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    room.send(content)
        .await
        .map_err(|e| api_err("rooms", format!("End poll failed: {e}")))?;

    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}

#[cfg(test)]
mod attachment_message_tests {
    use super::{
        file_message_content, image_message_content, image_mime_type, location_message_content,
        poll_start_content, poll_start_for_forward, room_message_preview, unstable_poll_preview,
        validate_poll_answer_ids, video_message_content, video_mime_type,
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
    fn manually_built_image_and_video_content_preserves_attachment_metadata() {
        let image = image_message_content(
            "photo.jpg".to_owned(),
            &"image/jpeg".parse().unwrap(),
            UInt::new(12),
            UInt::new(640),
            UInt::new(480),
            MediaSource::Plain(mxc_uri()),
        );
        let image_json = serde_json::to_value(image).unwrap();
        assert_eq!(image_json["msgtype"], "m.image");
        assert_eq!(image_json["url"], "mxc://example.org/media");
        assert_eq!(image_json["info"]["mimetype"], "image/jpeg");
        assert_eq!(image_json["info"]["w"], 640);
        assert_eq!(image_json["info"]["h"], 480);

        let video = video_message_content(
            "clip.mp4".to_owned(),
            &"video/mp4".parse().unwrap(),
            UInt::new(34),
            UInt::new(1920),
            UInt::new(1080),
            Some(std::time::Duration::from_millis(1500)),
            MediaSource::Plain(mxc_uri()),
        );
        let video_json = serde_json::to_value(video).unwrap();
        assert_eq!(video_json["msgtype"], "m.video");
        assert_eq!(video_json["url"], "mxc://example.org/media");
        assert_eq!(video_json["info"]["mimetype"], "video/mp4");
        assert_eq!(video_json["info"]["duration"], 1500);
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
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;

    let room = client
        .get_room(
            &matrix_sdk::ruma::RoomId::parse(room_id.clone())
                .map_err(|e| api_err("rooms", format!("无效的房间 ID: {e}")))?,
        )
        .ok_or_else(|| api_err("rooms", format!("房间不存在: {room_id}")))?;

    let content_uri = matrix_sdk::ruma::OwnedMxcUri::try_from(image_url.trim())
        .map_err(|e| api_err("rooms", format!("Invalid sticker MXC URI: {e}")))?;

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
        .map_err(|e| api_err("rooms", format!("Send sticker message failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Sticker message sent to {}", room_id),
    );
    info!("Sticker message sent to {}", room_id);
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
    Ok(())
}

/// Upper bound on DM-reuse candidates scanned with a `members()` call in
/// `create_dm`. Each candidate can fetch /members over the network (worst
/// case ~93s under `bounded_request_config`), so an account with many
/// DM-shaped rooms could otherwise keep the scan running for a very long
/// time. Hitting the cap fails closed (a clear, retryable error) rather
/// than risking a duplicate DM.
const DM_REUSE_SCAN_MAX_CANDIDATES: usize = 50;

/// Elapsed-time bound for the same scan. create_dm runs undroppable (see
/// `run_bounded_mutation_undroppable`), so this — together with the
/// candidate cap above and the per-request HTTP bound — is what keeps the
/// operation's total duration bounded. Hitting it fails closed like the
/// candidate cap: the remaining candidates are unverifiable.
const DM_REUSE_SCAN_MAX_ELAPSED_SECS: u64 = 150;

/// Create a new direct chat room with a user.
#[frb]
pub async fn create_dm(account_user_id: String, user_id: String) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let invited_user = matrix_sdk::ruma::UserId::parse(&user_id)
        .map_err(|e| api_err("rooms", format!("无效的用户 ID: {e}")))?;

    // Serialize per (account, target) pair: two concurrent calls could both
    // scan before either create lands, each decide "no DM exists" and
    // create a duplicate room (same read-modify-write discipline as the
    // other queued writes). The account is part of the key — DM creation is
    // account-private, unlike `pinned:{room_id}` shared state, so one
    // account's slow scan must not stall another account's create.
    // Capture the account's current client instance id: the queued scan may
    // execute after a logout+relogin replaced the client (deep predecessor
    // chains), and creating a room under a stale session's token would
    // leave a duplicate DM the new session cannot see (same discipline as
    // `set_room_muted`). `account_user_id` is the LOGGED-IN account — the
    // `user_id` parameter is the DM target, which is not in CLIENTS.
    let expected_instance_id = CLIENTS
        .read()
        .await
        .get(&account_user_id)
        .map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = client.clone();
    let mutation_invited_user = invited_user.clone();
    run_bounded_mutation_undroppable(
        format!("dm:{account_user_id}:{user_id}"),
        lifecycle_protection,
        async move {
            // Fail fast when the account was logged out (its token may have
            // been revoked server-side while the CLIENTS entry survived) or
            // its client was replaced while this operation was queued: the
            // stale session's token may still be valid server-side, but
            // creating under it would orphan the room from the new session.
            let mutation_client = mutation_client;
            if !mutation_client.matrix_auth().logged_in() {
                return Err(api_err("rooms", "当前账号已登出，请重新登录。".to_string()));
            }
            let is_current_client = CLIENTS
                .read()
                .await
                .get(&account_user_id)
                .map(|e| e.instance_id)
                == expected_instance_id;
            if !is_current_client {
                return Err(api_err("rooms", "当前账号已切换，请重试。".to_string()));
            }
            // The reuse scan below calls `members()` per DM candidate, which can
            // fetch /members over the network while holding the client lease.
            // This operation runs UNDROPPABLE (a tail dropped mid-create can
            // orphan a room whose response never arrived, and the retry's
            // reuse scan cannot see it until sync delivers it — a duplicate
            // DM), so the scan is bounded internally: by the candidate cap,
            // by the elapsed-time cap, and by the per-request HTTP bound.
            // Deliberately NOT degrading to members_no_sync:
            // that could miss an existing DM whose member list has not synced
            // yet and silently create a duplicate room.
            let mut members_read_failed = false;
            let scan_started = std::time::Instant::now();
            let mut scanned_candidates = 0usize;
            let mut reused_room_id = None;
            for room in mutation_client.rooms() {
                if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
                    continue;
                }

                let is_direct = matches!(room.is_direct().await, Ok(true));
                // Mirror the room list's DM classification: when the OTHER
                // party created the DM, m.direct lives in their account data and
                // this account's is_direct() is false — skipping such rooms
                // would create a duplicate DM. A room is a DM candidate when it
                // is directly marked, or small per the sync summary (≤2 joined);
                // larger rooms are skipped without the network members() call
                // (which lazy-loaded rooms would otherwise trigger per
                // candidate).
                if !is_direct && room.joined_members_count() > 2 {
                    continue;
                }

                // The DM shape check mirrors `is_dm_by_members` for rooms NOT
                // directly marked: with two joined members there must be no
                // pending invite, or the room is a forming group. Directly
                // marked rooms are DMs by definition (the room list agrees).
                let joined_len = room.joined_members_count();
                if !is_direct {
                    if joined_len == 0 {
                        // No sync summary was ever received for this room: the
                        // member counts are unknown, and the room may be a
                        // large group (reusing it as a "DM" would be wrong —
                        // `is_dm_by_members` classifies the same state
                        // conservatively as a group). Skip until a summary
                        // arrives; the store members() call below would only
                        // re-confirm the unknown.
                        continue;
                    }
                    if joined_len == 1 {
                        if room.invited_members_count() > 1 {
                            continue;
                        }
                    } else if room.invited_members_count() != 0 {
                        continue;
                    }
                }

                // Bound the scan: each remaining candidate costs a `members()`
                // call that can fetch /members over the network (worst ~93s
                // under bounded_request_config), so an unbounded scan could
                // run for a very long time on accounts with many DM-shaped
                // rooms. Past either cap the remaining candidates are
                // unverifiable — fail closed like a members() failure instead
                // of risking a duplicate DM.
                if scanned_candidates >= DM_REUSE_SCAN_MAX_CANDIDATES
                    || scan_started.elapsed()
                        >= std::time::Duration::from_secs(DM_REUSE_SCAN_MAX_ELAPSED_SECS)
                {
                    app_log(
                        "warn",
                        "rooms",
                        "DM reuse scan hit its candidate/elapsed limit; failing closed."
                            .to_string(),
                    );
                    members_read_failed = true;
                    break;
                }
                scanned_candidates += 1;

                let members = match room
                    .members(
                        matrix_sdk::RoomMemberships::JOIN | matrix_sdk::RoomMemberships::INVITE,
                    )
                    .await
                {
                    Ok(members) => members,
                    Err(_) => {
                        // A candidate's membership could not be verified: it may
                        // be the existing DM with the target. Fail closed (the
                        // user can retry) instead of silently creating a
                        // duplicate DM room.
                        members_read_failed = true;
                        continue;
                    }
                };

                let own_user_id = mutation_client.user_id().map(|id| id.to_string());
                let is_self_dm = own_user_id.as_deref() == Some(mutation_invited_user.as_str());
                let matched = if is_self_dm {
                    // A self-DM is the room that contains ONLY the caller
                    // (1 joined, no invitees): matching "any room the caller is
                    // in" would silently navigate into an unrelated
                    // conversation, while a bare membership exclusion would
                    // never match anything and create a duplicate on every tap.
                    joined_len == 1
                        && room.invited_members_count() == 0
                        && members.iter().all(|m| m.user_id() == mutation_invited_user)
                } else {
                    members.iter().any(|member| {
                        member.user_id() == mutation_invited_user
                            && own_user_id.as_deref() != Some(member.user_id().as_str())
                    })
                };
                if matched {
                    app_log(
                        "info",
                        "rooms",
                        format!(
                            "Reusing existing DM room {} for {}",
                            room.room_id(),
                            user_id
                        ),
                    );
                    reused_room_id = Some(room.room_id().to_string());
                    break;
                }
            }
            if let Some(room_id) = reused_room_id {
                return Ok(room_id);
            }
            if members_read_failed {
                return Err(api_err(
                    "rooms",
                    "无法确认是否已有私聊，请重试。".to_string(),
                ));
            }

            let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
            request.invite = vec![mutation_invited_user];
            request.is_direct = true;

            let response = mutation_client
                .create_room(request)
                .await
                .map_err(|e| api_err("rooms", format!("创建房间失败: {e}")))?;

            app_log(
                "info",
                "rooms",
                format!("Created DM room: {}", response.room_id()),
            );
            info!("Created DM room: {}", response.room_id());
            Ok(response.room_id().to_string())
        },
    )
    .await
}

/// Create a group room with a name and optional topic.
#[frb]
pub async fn create_group_room(
    account_user_id: String,
    name: String,
    topic: Option<String>,
) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    // Mirror update_room_details: an empty name would create a nameless
    // room (the Dart callers already intercept, this is defense in depth).
    let name = name.trim().to_owned();
    if name.is_empty() {
        return Err(api_err("rooms", "房间名称不能为空。".to_string()));
    }
    // Mirror update_room_details: trim the topic too (the Dart callers
    // already pass trimmed values; this is defense in depth).
    let topic = topic.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty());

    // Bounded like the other P0 writes: the create request holds the client
    // lease.
    run_bounded(async move {
        let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
        request.name = Some(name);
        request.topic = topic;

        let response = client
            .create_room(request)
            .await
            .map_err(|e| api_err("rooms", format!("创建房间失败: {e}")))?;

        app_log(
            "info",
            "rooms",
            format!("Created group room: {}", response.room_id()),
        );
        info!("Created group room: {}", response.room_id());
        Ok(response.room_id().to_string())
    })
    .await
}

/// Create a space room with a name and optional topic.
#[frb]
pub async fn create_space(
    account_user_id: String,
    name: String,
    topic: Option<String>,
) -> Result<String, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    // Mirror update_room_details / create_group_room: an empty name would
    // create a nameless space (the Dart callers already intercept, this is
    // defense in depth).
    let name = name.trim().to_owned();
    if name.is_empty() {
        return Err(api_err("rooms", "空间名称不能为空。".to_string()));
    }
    // Mirror update_space_details: trim the topic too (the Dart callers
    // already pass trimmed values; this is defense in depth).
    let topic = topic.map(|t| t.trim().to_owned()).filter(|t| !t.is_empty());

    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.name = Some(name);
    request.topic = topic;
    let mut creation_content =
        matrix_sdk::ruma::api::client::room::create_room::v3::CreationContent::default();
    creation_content.room_type = Some(matrix_sdk::ruma::room::RoomType::Space);
    request.creation_content = Some(
        matrix_sdk::ruma::serde::Raw::new(&creation_content)
            .map_err(|e| api_err("rooms", format!("空间创建内容编码失败: {e}")))?,
    );

    // Bounded like the other P0 writes: the create request holds the client
    // lease.
    run_bounded(async move {
        let response = client
            .create_room(request)
            .await
            .map_err(|e| api_err("rooms", format!("创建空间失败: {e}")))?;

        app_log(
            "info",
            "rooms",
            format!("Created space: {}", response.room_id()),
        );
        info!("Created space: {}", response.room_id());
        Ok(response.room_id().to_string())
    })
    .await
}

/// Join a room or space by room ID or alias.
#[frb]
pub async fn join_room(account_user_id: String, identifier: String) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let id_or_alias = matrix_sdk::ruma::RoomOrAliasId::parse(identifier.clone())
        .map_err(|e| api_err("rooms", format!("无效的房间或空间标识: {e}")))?;

    // Bounded like the other P0 writes: joining is a network operation
    // holding the client lease.
    let room_id = run_bounded(async move {
        let room = client
            .join_room_by_id_or_alias(&id_or_alias, &[])
            .await
            .map_err(|e| api_err("rooms", format!("加入房间失败: {e}")))?;
        app_log("info", "rooms", format!("Joined room: {}", room.room_id()));
        info!("Joined room: {}", room.room_id());
        Ok(room.room_id().to_string())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(room_id)
}

#[frb]
pub async fn accept_room_invite(account_user_id: String, room_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Invited {
        return Err(api_err("rooms", format!("该房间不是邀请状态: {room_id}")));
    }
    run_bounded(async move {
        room.join()
            .await
            .map_err(|e| api_err("rooms", format!("接受邀请失败: {e}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn reject_room_invite(account_user_id: String, room_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Invited {
        return Err(api_err("rooms", format!("该房间不是邀请状态: {room_id}")));
    }
    run_bounded(async move {
        room.leave()
            .await
            .map_err(|e| api_err("rooms", format!("拒绝邀请失败: {e}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn withdraw_room_knock(account_user_id: String, room_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;
    if room.state() != matrix_sdk::RoomState::Knocked {
        return Err(api_err(
            "rooms",
            format!("该房间不是加入请求状态: {room_id}"),
        ));
    }
    run_bounded(async move {
        room.leave()
            .await
            .map_err(|e| api_err("rooms", format!("撤回加入请求失败: {e}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

fn joined_non_space_room(client: &Client, room_id: &str) -> Result<Room, String> {
    let room = get_room_by_id(client, room_id)?;
    if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
        return Err(api_err(
            "rooms",
            format!("该房间不是已加入的非空间房间: {room_id}"),
        ));
    }
    Ok(room)
}

/// Member-count heuristic for whether a joined room without an `m.direct`
/// entry is a 1:1. Shared by the room list classification and unmute (the
/// latter must install the DM default rule, all-messages, on a real 1:1).
/// Uses the sync summary counts, which are accurate even while lazy-loaded
/// members are missing; without a summary the room is classified as a group
/// (the stored member list would be an unreliable sliding-window subset).
/// DM iff at most two joined members, with at most one pending invite
/// alongside a single joined member (a 1:1 the other party has not accepted
/// yet) and none for an accepted pair — a fresh room with several invitees
/// is a group.
async fn is_dm_by_members(room: &Room) -> bool {
    let summary_joined = room.joined_members_count();
    if summary_joined > 0 {
        summary_joined <= 2
            && (match summary_joined {
                1 => room.invited_members_count() <= 1,
                _ => room.invited_members_count() == 0,
            })
    } else {
        // No sync summary was ever received (fresh login before the first
        // sync cycle, or a store without room summaries). The member list
        // here is a lazy-loaded sliding-window subset: for a quiet group it
        // can hold as few as one or two members, so it cannot prove a 1:1.
        // Classify conservatively as a group — a wrong DM call flips unmute
        // onto the all-messages default rule for a real group (persistent
        // server noise), while a wrong group call only delays the correct
        // label until the first sync summary arrives.
        false
    }
}

/// Guard a user-initiated P0 write against account switches racing between
/// the Dart-side guard and this call's execution: the operation must run on
/// the account the caller opened it for, never on whatever account became
/// active in between.
fn ensure_account_matches(client: &Client, account_user_id: &str) -> Result<(), String> {
    let active_user_id = client
        .user_id()
        .ok_or_else(|| api_err("account", "No active user".to_string()))?
        .to_string();
    if active_user_id != account_user_id {
        return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
    }
    Ok(())
}

/// Leave a joined non-space room.
#[frb]
pub async fn leave_room(account_user_id: String, room_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    run_bounded(async move {
        room.leave()
            .await
            .map_err(|error| api_err("rooms", format!("退出房间失败: {error}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

/// Return the editable state of a joined non-space room.
#[frb]
pub async fn get_room_details(room_id: String) -> Result<RoomDetails, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = joined_non_space_room(&client, &room_id)?;
    let has_explicit_name = room.name().is_some_and(|name| !name.trim().is_empty());
    let (name_event_id, avatar_event_id, topic_event_id) = tokio::join!(
        room_name_event_id(&room),
        room_avatar_event_id(&room),
        room_topic_event_id(&room)
    );
    Ok(RoomDetails {
        id: room_id,
        name: room_display_name(&room),
        has_explicit_name,
        avatar_url: room.avatar_url().map(|url| url.to_string()),
        name_event_id,
        avatar_event_id,
        topic_event_id,
        topic: room
            .topic()
            .map(|topic| topic.trim().to_string())
            .filter(|topic| !topic.is_empty()),
    })
}

/// Invite a Matrix user to a joined non-space room.
#[frb]
pub async fn invite_user_to_room(
    account_user_id: String,
    room_id: String,
    user_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id.trim())
        .map_err(|error| api_err("rooms", format!("无效的用户 ID: {error}")))?;
    run_bounded(async move {
        room.invite_user_by_id(&user_id)
            .await
            .map_err(|error| api_err("rooms", format!("邀请用户失败: {error}")))?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

/// Update a joined non-space room's name and topic.
#[frb]
pub async fn update_room_details(
    account_user_id: String,
    room_id: String,
    name: String,
    update_name: bool,
    update_topic: bool,
    topic: Option<String>,
) -> Result<RoomDetailsUpdate, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let name = name.trim().to_owned();
    run_bounded(async move {
        let (name_event_id, name_error) = if update_name {
            if name.is_empty() {
                (None, Some("房间名称不能为空。".to_string()))
            } else {
                match room.set_name(name.clone()).await {
                    Ok(response) => (Some(response.event_id.to_string()), None),
                    Err(error) => (None, Some(error.to_string())),
                }
            }
        } else {
            (None, None)
        };
        let (topic_event_id, topic_error) = if update_topic {
            let new_topic = topic.unwrap_or_default().trim().to_owned();
            // Dart already sends update_topic only for an edited value. Do
            // not compare against room.topic(): the SDK snapshot may still
            // predate a just-completed write, which would drop a quick
            // A -> B -> A change.
            match room.set_room_topic(&new_topic).await {
                Ok(response) => (Some(response.event_id.to_string()), None),
                Err(error) => (None, Some(error.to_string())),
            }
        } else {
            (None, None)
        };
        if name_event_id.is_some() || topic_event_id.is_some() {
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        }
        Ok(RoomDetailsUpdate {
            name_event_id,
            topic_event_id,
            name_error,
            topic_error,
        })
    })
    .await
}

/// Upload and apply a new avatar for a joined non-space room.
#[frb]
pub async fn upload_room_avatar(
    account_user_id: String,
    room_id: String,
    content_type: String,
    data: Vec<u8>,
) -> Result<RoomAvatarUpdate, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    // Only validates the room exists and is joined; the room used for the
    // state event is re-fetched under a fresh lease after the upload.
    joined_non_space_room(&client, &room_id)?;
    let mime: mime::Mime = content_type
        .parse()
        .map_err(|error| api_err("rooms", format!("无效的内容类型 '{content_type}': {error}")))?;
    if mime.type_() != mime::IMAGE {
        return Err(api_err("rooms", format!("不是图片格式: {mime}")));
    }
    let media = client.media();
    // The upload can legitimately take minutes (the SDK sizes its own
    // timeout by the payload, at least 5 minutes per attempt), so release
    // the client lease for its duration — holding the SYNC_LIFECYCLE read
    // lock for that long would freeze logout/account switch. A generous
    // total bound still caps the multi-retry worst case.
    let upload = {
        drop(client);
        tokio::time::timeout(
            std::time::Duration::from_secs(600),
            media.upload(&mime, data, None),
        )
        .await
        .map_err(|_| api_err("rooms", "上传超时，请重试。".to_string()))?
        .map_err(|error| api_err("rooms", format!("上传房间头像失败: {error}")))?
    };
    // Re-acquire the lease for the state-event step (short, bounded by
    // run_bounded) and re-verify the account: the account may have switched
    // or logged out entirely during the upload. Either way the upload
    // already landed — say so (the Dart catch passes "已上传" messages
    // through verbatim).
    let client = get_client().await.ok_or_else(|| {
        api_err(
            "rooms",
            "头像已上传，但当前账号已登出，无法应用。请重新登录后重试。".to_string(),
        )
    })?;
    ensure_account_matches(&client, &account_user_id)
        .map_err(|_| "头像已上传，但当前账号已切换，未应用。请重新选择图片以应用。".to_string())?;
    let room = joined_non_space_room(&client, &room_id).map_err(|_| {
        // The upload already landed: a room-state change on another device
        // (left / removed) must not surface as a bare failure that hides
        // the "已上传" passthrough.
        "头像已上传，但房间状态已变化（可能已退出该房间），未能应用。".to_string()
    })?;
    run_bounded(async move {
        let mut info = matrix_sdk::ruma::events::room::avatar::ImageInfo::new();
        info.mimetype = Some(mime.to_string());
        info.blurhash = upload.blurhash;
        // The upload already succeeded: a timeout here means the image is
        // uploaded but not applied — say so (a retry re-applies cheaply,
        // while "刷新确认" would have nothing to confirm).
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(60),
            room.set_avatar_url(&upload.content_uri, Some(info)),
        )
        .await
        .map_err(|_| {
            api_err(
                "rooms",
                "头像已上传，但应用失败（请求超时），请重试。".to_string(),
            )
        })?
        .map_err(|error| api_err("rooms", format!("更新房间头像失败: {error}")))?;
        notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        Ok(RoomAvatarUpdate {
            avatar_url: upload.content_uri.to_string(),
            event_id: response.event_id.to_string(),
        })
    })
    .await
}

/// Return whether a room has an explicit mute push rule.
#[frb]
pub async fn is_room_muted(room_id: String) -> Result<bool, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = joined_non_space_room(&client, &room_id)?;
    // Bounded like the other P0 calls: the notification-settings read holds
    // the client lease for the call's duration (the settings instance is a
    // local store read — push rules arrive via sync — but consistency with
    // the other bounded P0 calls keeps the lease hold bounded).
    run_bounded(async move {
        let user_id = client
            .user_id()
            .map(|id| id.to_string())
            .unwrap_or_default();
        let settings = notification_settings_for(&client, &user_id, None).await;
        Ok(settings
            .get_user_defined_room_notification_mode(room.room_id())
            .await
            == Some(matrix_sdk::notification_settings::RoomNotificationMode::Mute))
    })
    .await
}

/// Create or remove an explicit mute push rule for a room.
#[frb]
pub async fn set_room_muted(
    account_user_id: String,
    room_id: String,
    muted: bool,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("rooms", "No active user".to_string()))?
        .to_string();
    // Capture the account's current client instance id: the queued write
    // must fail fast when a logout+relogin replaced the client before it
    // executes — rebuilding the shared NotificationSettings cache entry
    // with the stale client would shadow the fresh session's instance.
    let expected_instance_id = CLIENTS.read().await.get(&user_id).map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = client.clone();
    run_bounded_mutation(
        format!("muted:{user_id}:{room_id}"),
        lifecycle_protection,
        async move {
            // The write may execute long after the caller enqueued it (deep
            // predecessor chains): if the account was logged out meanwhile, the
            // client's token is dead — fail fast instead of rebuilding a stale
            // NotificationSettings instance (keyed by this user_id, it would
            // shadow a fresh session's settings entry).
            if !mutation_client.matrix_auth().logged_in() {
                return Err(api_err("rooms", "当前账号已登出，请重新登录。".to_string()));
            }
            // `logged_in()` can still pass when the remote logout failed/timed
            // out server-side (the local session kept its token while the
            // server revoked it). Rebuilds of the shared cache entry must also
            // be blocked when this client is no longer the account's CURRENT
            // one — a logout+relogin replaced it, and the stale instance would
            // shadow the fresh session's entry until the next logout.
            let is_current_client =
                CLIENTS.read().await.get(&user_id).map(|e| e.instance_id) == expected_instance_id;
            if !is_current_client {
                return Err(api_err("rooms", "当前账号已切换，请重试。".to_string()));
            }
            // Push-rule updates are read-modify-write server calls; serialize per
            // room so rapid toggles apply in click order instead of racing. The
            // shared per-account instance applies its own writes to its internal
            // ruleset, so a re-toggle right after the previous write cannot
            // misread the pre-write state from the store and no-op.
            let settings = notification_settings_for(
                &mutation_client,
                &user_id,
                // The instance id this closure's guard captured: the cache key
                // must bind to the client the settings are built from, never a
                // re-read of the mapping table (a logout+relogin between the
                // guard and this call must not key the stale handle under the
                // NEW session's id).
                expected_instance_id,
            )
            .await;
            if muted {
                settings
                    .set_room_notification_mode(
                        room.room_id(),
                        matrix_sdk::notification_settings::RoomNotificationMode::Mute,
                    )
                    .await
                    .map_err(|error| api_err("rooms", format!("更新通知设置失败: {error}")))?;
            } else {
                // Unknown encryption state (room joined but `m.room.encryption`
                // not synced yet) must default to encrypted: unmuting with
                // "not encrypted" would downgrade the rule to all-messages in a
                // room that is actually encrypted, leaking notification noise
                // (and hinting the room content to the push gateway).
                let is_encrypted = !matches!(
                    room.latest_encryption_state().await,
                    Ok(state) if !state.is_encrypted()
                );
                // A 1:1 must be classified correctly or unmuting installs the
                // group default rule (mention-only) on it, silencing ordinary
                // messages on every device until the user re-mutes. `is_direct()`
                // only reflects `m.direct` account data (often absent for
                // invites), so fall back to the same member-count heuristic the
                // room list uses (shared predicate, see `is_dm_by_members`).
                let is_one_to_one =
                    room.is_direct().await.unwrap_or(false) || is_dm_by_members(&room).await;
                settings
                    .unmute_room(
                        room.room_id(),
                        matrix_sdk::notification_settings::IsEncrypted::from(is_encrypted),
                        matrix_sdk::notification_settings::IsOneToOne::from(is_one_to_one),
                    )
                    .await
                    .map_err(|error| api_err("rooms", format!("更新通知设置失败: {error}")))?;
            }
            // Broadcast from inside the queued operation: even when the caller
            // times out (90s bound) and this tail keeps running, the room list
            // still learns about the change (like set_pinned_message).
            notify_sync_event_for_generation(generation, SyncEvent::RoomListChanged);
            Ok(())
        },
    )
    .await?;
    Ok(())
}

/// Lightweight authoritative read of the room's pinned event ids (no event
/// loading). Used by the message long-press menu to decide whether "置顶" or
/// "取消置顶" applies; failures must be retried instead of falling back to a
/// local state-store snapshot that may lag the server in either direction.
#[frb]
pub async fn get_pinned_event_ids(
    account_user_id: String,
    room_id: String,
) -> Result<Vec<String>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("pinned", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    run_bounded(async move {
        // Bound the server read more tightly than the client default (the
        // SDK's RequestConfig already caps a single request at 30s, but
        // with 3 retries a dead network could still stall the long-press
        // menu well past the 90s outer bound).
        let ids = tokio::time::timeout(
            std::time::Duration::from_secs(15),
            room.load_pinned_events(),
        )
        .await
        .map_err(|_| api_err("pinned", "加载置顶状态超时，请重试".to_string()))?
        .map_err(|error| api_err("pinned", format!("加载置顶状态失败，请重试: {error}")))?
        .unwrap_or_default();
        Ok(ids.into_iter().map(|id| id.to_string()).collect())
    })
    .await
}

/// Set a message's membership in `m.room.pinned_events` to the requested
/// state. Idempotent: applying an already-held state is a no-op, so a retry
/// after a caller-side timeout (the first attempt may still be running
/// server-side, driven by the queue's background task) cannot flip the pin a
/// second time — a toggle would, and the UI would then contradict the
/// server state.
#[frb]
pub async fn set_pinned_message(
    account_user_id: String,
    room_id: String,
    event_id: String,
    pinned: bool,
) -> Result<bool, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("pinned", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let event_id = matrix_sdk::ruma::EventId::parse(event_id)
        .map_err(|error| api_err("pinned", format!("无效的事件 ID: {error}")))?;
    // Capture the account's current client instance id: the queued write
    // may execute after a logout+relogin replaced the client (deep
    // predecessor chains). Same discipline as `set_room_muted` /
    // `create_dm` / `set_user_ignored`.
    let expected_instance_id = CLIENTS
        .read()
        .await
        .get(&account_user_id)
        .map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let pinned_result = Arc::new(AtomicBool::new(false));
    let queued_result = pinned_result.clone();
    run_bounded_mutation(
        format!("pinned:{room_id}"),
        lifecycle_protection,
        async move {
            // Fail fast when the account was logged out or its client was
            // replaced while this write was queued (the pinned list is
            // room-shared state, but writing under a stale session's token
            // would mislead with an unrelated error).
            let mutation_client = room.client();
            if !mutation_client.matrix_auth().logged_in() {
                return Err(api_err(
                    "pinned",
                    "当前账号已登出，请重新登录。".to_string(),
                ));
            }
            let is_current_client = CLIENTS
                .read()
                .await
                .get(&account_user_id)
                .map(|e| e.instance_id)
                == expected_instance_id;
            if !is_current_client {
                return Err(api_err("pinned", "当前账号已切换，请重试。".to_string()));
            }
            // RMW against the authoritative server state: the SDK's in-memory
            // room state lags our own writes until the sync echo, so rapid
            // pin/unpin sequences would otherwise overwrite each other.
            // load_pinned_events is a server read that maps a missing
            // m.room.pinned_events state (first-ever pin) to an empty list.
            // The key is room-scoped (not per account): the pinned list is
            // room-shared state, so two accounts toggling the same room must
            // serialize or their read-modify-writes would clobber each other.
            let mut pinned_ids = room
                .load_pinned_events()
                .await
                .map_err(|error| api_err("pinned", format!("加载置顶状态失败: {error}")))?
                .unwrap_or_default();
            let already_pinned = pinned_ids.iter().any(|id| id == &event_id);
            let changed = if pinned {
                if !already_pinned {
                    // Matrix clients append newly pinned events. The pinned
                    // timeline also reads the bounded cache from the tail,
                    // so preserving that order keeps the newest 128 cached.
                    pinned_ids.push(event_id.to_owned());
                    true
                } else {
                    false
                }
            } else if already_pinned {
                pinned_ids.retain(|id| id != &event_id);
                true
            } else {
                false
            };
            if changed {
                room.send_state_event(
                matrix_sdk::ruma::events::room::pinned_events::RoomPinnedEventsEventContent::new(
                    pinned_ids,
                ),
            )
            .await
            .map_err(|error| api_err("pinned", format!("更新置顶消息失败: {error}")))?;
                // Broadcast from inside the queued operation: even when the
                // caller times out (90s bound) and this tail keeps running, the
                // pinned page still learns about the change.
                notify_sync_event_for_generation(
                    generation,
                    SyncEvent::PinnedMessagesChanged { room_id },
                );
            }
            queued_result.store(pinned, Ordering::Relaxed);
            Ok(())
        },
    )
    .await?;
    let pinned = pinned_result.load(Ordering::Relaxed);
    Ok(pinned)
}

/// Load every accessible pinned message in display order.
#[frb]
pub async fn get_pinned_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("pinned", "No client created.".to_string()))?;
    let room = joined_non_space_room(&client, &room_id)?;
    // The load holds the client lease (SYNC_LIFECYCLE read lock) for its
    // whole duration, blocking logout/account switch, which need the write
    // lock. The internal stages are individually bounded (15s list read +
    // 20s cache wait + 10s pinned-timeline build + 25s focused fetch =
    // 70s; cache setup steps before them are unbounded, so headroom is
    // kept generous), and the total bound below exceeds that sum so the
    // inner stage timeouts (which degrade to partial results) fire before
    // the outer one (which fails the whole page) even when several expire
    // in the same tick.
    tokio::time::timeout(
        std::time::Duration::from_secs(90),
        sdk_timeline::get_pinned_messages(&room),
    )
    .await
    .map_err(|_| api_err("pinned", "加载置顶消息超时。".to_string()))?
}

/// Explicitly mark all currently loaded messages in a room as read.
/// Returns whether the marked-unread flag was actually cleared (the auto
/// path skips the clear when one is already in flight for this room).
#[frb]
pub async fn mark_room_as_read(
    account_user_id: String,
    room_id: String,
    explicit: bool,
) -> Result<bool, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("account", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("account", "No active user".to_string()))?
        .to_string();
    let override_key = marked_unread_override_key(&client, &room)
        .ok_or_else(|| api_err("account", "No active user".to_string()))?;
    // Capture the account's current client instance id: the queued clear
    // may execute after a logout+relogin replaced the client (deep
    // predecessor chains). Same discipline as the other queued writes.
    let expected_instance_id = CLIENTS.read().await.get(&user_id).map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = client.clone();
    // The clear closure below is `move`; the outer function still needs
    // `user_id` for the queue key, so give the closure its own copy.
    let clear_user_id = user_id.clone();
    // The receipts are not a read-modify-write (the Timeline guards against
    // moving either marker backwards), so they are sent outside the queue —
    // an explicit read must not starve behind a flood of sync-driven
    // auto-reads. The marked-unread clear and the unread-override
    // bookkeeping DO mutate the same account-data event the unread-marker
    // write uses, so they run on the shared `read:{user}:{room}` key (the
    // same one mark_room_unread uses) to stay serialized with it.
    // The receipt step still holds the client lease (initial window
    // pagination can run several network attempts), so it is bounded — and
    // it runs CONCURRENTLY with the clear queue below (they touch disjoint
    // state: receipts vs account data), so the whole call is bounded by the
    // longer of the two (~90s; ~15s for the auto path, which bounds both
    // sides like the receipt send), not their sum.
    let receipt_future = {
        let receipt_room = room.clone();
        let receipt_client = mutation_client.clone();
        run_bounded(async move {
            sdk_timeline::send_read_receipts(&receipt_client, &receipt_room).await
        })
    };
    let clear_operation = async move {
        // Fail fast when the account was logged out or its client was
        // replaced while this clear was queued: writing the account-data
        // flag under a stale session would either 401 (misleading wording)
        // or land on a dead session's data (same discipline as the other
        // queued writes).
        let mutation_client = room.client();
        if !mutation_client.matrix_auth().logged_in() {
            return Err(api_err(
                "account",
                "当前账号已登出，请重新登录。".to_string(),
            ));
        }
        let is_current_client = CLIENTS
            .read()
            .await
            .get(&clear_user_id)
            .map(|e| e.instance_id)
            == expected_instance_id;
        if !is_current_client {
            return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
        }
        let baseline = synced_marked_unread(&room).await;
        let had_pending_unread_override = MARKED_UNREAD_OVERRIDES
            .read()
            .await
            .get(&override_key)
            .is_some_and(|local| {
                // Same TTL semantics as `resolve_marked_unread`: an expired
                // override no longer proves a pending local write — a
                // `true` echo arriving after the TTL is a NEW cross-device
                // mark that must not be suppressed.
                local.desired && local.created_at.elapsed() <= MARKED_UNREAD_OVERRIDE_TTL
            });
        // The store-checked clear below clears the server flag whenever
        // the room is being viewed (its marked_unread has synced
        // locally). That check can lag our own write: `marked_unread
        // = true` was set but its echo has not synced yet, so the store
        // still reads false and the clear is skipped. An explicit read
        // action clears the server flag even then — it must win over a
        // marked-unread state set on any device, including one that has
        // not echoed here yet — while the auto path only clears for our
        // own pending override (avoiding a per-message write
        // amplification).
        // The store-checked clear covers the flag once its echo has landed;
        // the outer clear then only needs to fire when the inner one did not
        // (explicit action against a flag whose echo has not landed here
        // yet, or our own pending unread override). This avoids double
        // writes based on the freshly read store state, not a stale sample.
        let inner_cleared = sdk_timeline::clear_marked_unread_if_set(&room)
            .await
            .map_err(|clear_error| {
                // The receipt ran concurrently (tokio::join!) and may
                // already have been sent: say so instead of a bare clear
                // failure — a retry re-sends both idempotently.
                api_err(
                    "account",
                    format!("已读回执可能已发送，但清除未读标记失败: {clear_error}，请重试。"),
                )
            })?;
        // The explicit branch is deliberately NOT gated on the locally
        // visible marker (baseline or our own pending override): a `false`
        // baseline is ambiguous — it can mean the room has no marker, or
        // that a marker set on another device has not echoed here yet.
        // Gating would silently defeat the explicit action in that window
        // (the flag survives and the room re-shows as unread). Writing
        // `false` when no marker exists is an idempotent no-op, and
        // explicit actions are rare user-initiated operations, so the
        // extra write is negligible. Only the auto path is gated, where
        // per-message write amplification is a real concern. This gating
        // applies to the clear WRITE; the suppression override below is
        // gated separately (only created when the flag was actually set).
        let explicit_clear =
            (explicit && !inner_cleared) || (had_pending_unread_override && !baseline);
        if explicit_clear {
            // A failed clear must still surface as an error (a retry
            // re-sends both idempotently) rather than promising success
            // while the server flag survives. The wording is
            // order-independent: the receipt may or may not have been
            // sent yet.
            sdk_timeline::clear_marked_unread(&room)
                .await
                .map_err(|clear_error| {
                    api_err(
                        "account",
                        format!("清除未读标记失败: {clear_error}，请重试。"),
                    )
                })?;
        }
        // The override suppresses the flag until the clear's echo
        // arrives. When a clear was just issued (explicit action, or our
        // own pending unread override) or the store already held the
        // flag, treat the flag as "was set, now clearing": with
        // baseline=true the override stays effective while a stale `true`
        // echo lands (showing read), and is removed once the `false`
        // echo arrives (showing the cleared store). Without this, a
        // pending `true` echo — including our own mark-unread write whose
        // echo has not landed yet — would briefly resurrect the unread
        // marker. A clean room with no clear intent gets no override.
        // The override is created ONLY when the flag was actually set
        // (visible baseline, or our own pending mark-unread write) — NOT
        // for an explicit read of a room that locally shows no marker: a
        // `{baseline:true, desired:false}` override suppresses any *new*
        // cross-device mark for the whole 30s TTL, swallowing an unread
        // flag the user never handled here. The clear itself is still
        // written unconditionally (an explicit read must win over an
        // un-echoed remote mark), but without an override the stale
        // `true` echo can briefly flash the room unread until the `false`
        // echo lands — that flicker is the accepted price for not hiding a
        // fresh remote mark.
        // Note: while the room keeps being viewed (auto-reads renew this
        // override with a fresh created_at), the suppression is effectively
        // extended — viewing IS the "handled now" signal, so this is
        // intended. Auto-reads only run while the room is viewed (they are
        // gated on the viewer/owner), so the 30s TTL bound starts as soon
        // as viewing stops, and the override cannot suppress a new
        // cross-device mark beyond that.
        let override_baseline = had_pending_unread_override || baseline;
        if override_baseline {
            set_marked_unread_override(override_key, override_baseline, false).await;
        }
        // Broadcast from inside the queued operation (like mute/pin): even
        // when the caller times out and this tail keeps running, the room
        // list still learns about the change. Only broadcast when a clear
        // actually happened: a plain auto-read with no flag set must not
        // invalidate the room list on every incoming message.
        if inner_cleared || explicit_clear {
            notify_sync_event_for_generation(generation, SyncEvent::RoomListChanged);
        }
        Ok(())
    };
    let clear_key = format!("read:{user_id}:{room_id}");
    // `Ok(true)` = the clear ran (or had nothing to clear); `Ok(false)` =
    // the auto path skipped enqueueing because a clear for this room is
    // already in flight (it re-reads the store at execution and covers the
    // current flag state). The receipt-failure wording must tell the two
    // apart: "已清除" would be wrong for a skipped clear.
    let clear_future: std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<bool, String>> + Send>,
    > = if explicit {
        Box::pin(async move {
            run_bounded_mutation(clear_key, lifecycle_protection, clear_operation)
                .await
                .map(|()| true)
        })
    } else {
        Box::pin(async move {
            // Auto-reads are background housekeeping that fire on every
            // message refresh; a backlogged clear queue must not hold the
            // client lease for the full 90s bound (it blocks logout/account
            // switch). Bound the auto path like the receipt side (15s): the
            // queued operation keeps running in its background tail after
            // the timeout, and the next refresh re-checks the store.
            // Explicit reads keep the full budget — they are rare and must
            // win.
            //
            // Under a message flood with a failing clear, the queue tail
            // for this room can chain (each clear waits behind its
            // predecessor's HTTP retries). A queued clear re-reads the
            // store at execution and covers the current flag state, so a
            // duplicate auto-clear adds nothing — skip the enqueue while
            // one is already in flight (the next refresh re-checks).
            if let Ok(tails) = MUTATION_TAILS.lock() {
                if tails.contains_key(&clear_key) {
                    return Ok(false);
                }
            }
            tokio::time::timeout(
                std::time::Duration::from_secs(15),
                run_bounded_mutation(clear_key, lifecycle_protection, clear_operation),
            )
            .await
            .unwrap_or_else(|_| Err(api_err("account", MUTATION_TIMEOUT_MESSAGE.to_string())))
            .map(|()| true)
        })
    };
    let (clear_result, receipt_result) = tokio::join!(clear_future, receipt_future);
    // `Ok(true)` = the marked-unread clear actually ran (or had nothing to
    // clear); `Ok(false)` = the auto path skipped it because a clear for
    // this room is already in flight (it re-reads the store at execution).
    // Dart uses the flag to decide whether a local unread:false override is
    // warranted — a skipped clear whose tail later fails must not leave a
    // stale "已读" override masking the server's marked-unread flag.
    let cleared = match clear_result {
        Ok(cleared) => {
            if cleared {
                receipt_result.map_err(|error| {
                    // The marked-unread clear succeeded (or had nothing to
                    // do); only the receipt send failed. Say so instead of
                    // claiming the whole action failed — a retry re-sends
                    // the receipt only.
                    api_err(
                        "account",
                        format!("未读标记已清除，但已读回执发送失败: {error}"),
                    )
                })?;
            } else {
                // The clear was skipped (one is already in flight and
                // covers this flag state); only the receipt failed.
                receipt_result.map_err(|error| {
                    api_err(
                        "account",
                        format!("已读回执发送失败: {error}（未读标记清除已在后台进行）"),
                    )
                })?;
            }
            cleared
        }
        Err(clear_error) => {
            if receipt_result.is_ok() {
                // The read receipt (the primary action) reached the server;
                // only the marked-unread bookkeeping is unsettled. Say so
                // instead of claiming the whole action failed. A queue-wait
                // timeout is not a failure: the clear never ran and keeps
                // running in its background tail, so neither "失败" nor
                // "请重试" applies.
                if clear_error == MUTATION_TIMEOUT_MESSAGE {
                    return Err(api_err(
                        "account",
                        "已读回执已发送；清除未读标记的操作仍在后台执行，请稍后刷新确认。"
                            .to_string(),
                    ));
                }
                return Err(api_err(
                    "account",
                    format!("已读回执已发送，但清除未读标记失败: {clear_error}，请重试。"),
                ));
            }
            // Both sides failed. When the clear side timed out (its
            // background tail keeps running), the receipt — the primary
            // action — has definitely failed: a hard receipt failure (e.g.
            // a rejected token) means the room stays unread on other
            // devices, so the generic "may have taken effect" line would
            // be wrong. (The receipt error can never equal
            // MUTATION_TIMEOUT_MESSAGE — its own bounded call resolves
            // with its own wording — so no receipt-side "may have been
            // delivered" branch is needed here.)
            if clear_error == MUTATION_TIMEOUT_MESSAGE {
                let receipt_error = receipt_result.unwrap_err();
                return Err(api_err(
                    "account",
                    format!("已读回执发送失败: {receipt_error}；清除未读标记的操作仍在后台执行，请稍后刷新确认。"),
                ));
            }
            // The receipt (the primary action) failed too: surface both
            // errors instead of hiding the receipt failure behind the clear.
            let receipt_error = receipt_result.unwrap_err();
            return Err(api_err(
                "account",
                format!(
                    "已读回执发送失败: {receipt_error}；清除未读标记失败: {clear_error}，请重试。"
                ),
            ));
        }
    };
    Ok(cleared)
}

/// Persist an explicit unread marker for a room in room account data.
#[frb]
pub async fn mark_room_unread(account_user_id: String, room_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    use matrix_sdk::ruma::events::marked_unread::MarkedUnreadEventContent;

    let client = get_client()
        .await
        .ok_or_else(|| api_err("account", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = client
        .user_id()
        .ok_or_else(|| api_err("account", "No active user".to_string()))?
        .to_string();
    let mutation_key = format!("read:{user_id}:{room_id}");
    let override_key = marked_unread_override_key(&client, &room)
        .ok_or_else(|| api_err("account", "No active user".to_string()))?;
    // Capture the account's current client instance id: the queued write
    // shares `read:{user}:{room}` with the clear path and may execute after
    // a logout+relogin replaced the client (deep predecessor chains). Same
    // discipline as the clear path and the other queued writes.
    let expected_instance_id = CLIENTS.read().await.get(&user_id).map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = room.client().clone();
    let clear_user_id = user_id.clone();
    run_bounded_mutation(mutation_key, lifecycle_protection, async move {
        // Fail fast when the account was logged out or its client was
        // replaced while this write was queued: a stale session must not
        // apply a late unread marker (and its wording would otherwise
        // mislead).
        if !mutation_client.matrix_auth().logged_in() {
            return Err(api_err(
                "account",
                "当前账号已登出，请重新登录。".to_string(),
            ));
        }
        let is_current_client = CLIENTS
            .read()
            .await
            .get(&clear_user_id)
            .map(|e| e.instance_id)
            == expected_instance_id;
        if !is_current_client {
            return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
        }
        let baseline = synced_marked_unread(&room).await;
        room.set_account_data(MarkedUnreadEventContent::new(true))
            .await
            .map(|_| ())
            .map_err(|error| api_err("account", format!("标记房间为未读失败: {error}")))?;
        set_marked_unread_override(override_key, baseline, true).await;
        // Broadcast from inside the queued operation (like mute/pin/read):
        // even when the caller times out and this tail keeps running, the
        // room list still learns about the change.
        notify_sync_event_for_generation(generation, SyncEvent::RoomListChanged);
        Ok(())
    })
    .await?;
    Ok(())
}

/// The account's ignored-user list, tagged with its source freshness.
#[frb]
#[derive(Clone)]
pub struct IgnoredUsers {
    pub user_ids: Vec<String>,
    /// True when fetched from the server; false when served from the local
    /// state store (offline fallback). Pending confirmed local writes are
    /// applied to the fallback, but it can still lag remote changes unless
    /// the caller is handling a completed sync notification.
    pub from_server: bool,
}

/// List the Matrix user IDs in the current account's ignored-user list.
#[frb]
pub async fn get_ignored_users() -> Result<IgnoredUsers, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("account", "No client created.".to_string()))?;
    let account = client.account();
    // Bounded like the other P0 calls: the server read holds the client
    // lease (blocking logout/account switch).
    run_bounded(async move {
        // Prefer the server copy, but fall back to the local state store so
        // an offline client still filters ignored senders after its first
        // sync.
        let (raw, from_server) = match account
            .fetch_account_data_static::<IgnoredUserListEventContent>()
            .await
        {
            Ok(raw) => (raw, true),
            Err(network_error) => (
                account
                    .account_data::<IgnoredUserListEventContent>()
                    .await
                    .map_err(|error| {
                        api_err(
                            "account",
                            format!(
                                "加载忽略用户列表失败: {network_error}；本地缓存读取失败: {error}"
                            ),
                        )
                    })?,
                false,
            ),
        };
        let mut content = raw
            .map(|raw| raw.deserialize())
            .transpose()
            .map_err(|error| api_err("account", format!("解析忽略用户列表失败: {error}")))?
            .unwrap_or_default();
        if !from_server {
            merge_current_account_ignored_user_overrides(&client, &mut content).await;
        }
        Ok(IgnoredUsers {
            user_ids: content
                .ignored_users
                .into_keys()
                .map(|user_id| user_id.to_string())
                .collect(),
            from_server,
        })
    })
    .await
}

/// Add or remove one user from the account's ignored-user list.
///
/// Returns the complete post-write list so callers can persist the
/// authoritative snapshot instead of merging a delta into a possibly
/// unknown local baseline.
#[frb]
pub async fn set_user_ignored(
    account_user_id: String,
    user_id: String,
    ignored: bool,
) -> Result<Vec<String>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("account", "No client created.".to_string()))?;
    let active_user_id = client
        .user_id()
        .ok_or_else(|| api_err("account", "No active user".to_string()))?
        .to_string();
    if active_user_id != account_user_id {
        return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
    }
    let user_id = matrix_sdk::ruma::UserId::parse(user_id.trim())
        .map_err(|error| api_err("account", format!("无效的用户 ID: {error}")))?
        .to_owned();
    // Capture the account's current client instance id: the queued write may
    // execute after a logout+relogin replaced the client (deep predecessor
    // chains). Same discipline as `set_room_muted` / `create_dm`.
    let expected_instance_id = CLIENTS
        .read()
        .await
        .get(&account_user_id)
        .map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = client.clone();
    run_bounded_mutation(
        format!("ignored:{active_user_id}"),
        lifecycle_protection,
        async move {
            // Fail fast when the account was logged out or its client was
            // replaced while this write was queued: a stale session must not
            // apply a late ignored-list edit (and its wording would otherwise
            // mislead).
            if !mutation_client.matrix_auth().logged_in() {
                return Err(api_err(
                    "account",
                    "当前账号已登出，请重新登录。".to_string(),
                ));
            }
            let is_current_client = CLIENTS
                .read()
                .await
                .get(&account_user_id)
                .map(|e| e.instance_id)
                == expected_instance_id;
            if !is_current_client {
                return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
            }
            let account = mutation_client.account();
            let mut content = account
                .fetch_account_data_static::<IgnoredUserListEventContent>()
                .await
                .map_err(|error| api_err("account", format!("加载忽略用户列表失败: {error}")))?
                .map(|raw| raw.deserialize())
                .transpose()
                .map_err(|error| api_err("account", format!("解析忽略用户列表失败: {error}")))?
                .unwrap_or_default();
            if ignored {
                content
                    .ignored_users
                    .insert(user_id.clone(), IgnoredUser::new());
            } else {
                content.ignored_users.remove(&user_id);
            }
            let updated = content
                .ignored_users
                .keys()
                .map(|user_id| user_id.to_string())
                .collect();
            // Baseline of the local store before the write: the store only
            // advances on the sync echo, and previews consult it until then.
            let synced_baseline = mutation_client.is_user_ignored(&user_id).await;
            let override_key = ignored_user_override_key(&mutation_client, &user_id);
            account
                .set_account_data(content)
                .await
                .map_err(|error| api_err("account", format!("更新忽略用户列表失败: {error}")))?;
            if let Some(key) = override_key {
                set_ignored_user_override(key, synced_baseline, ignored).await;
            }
            // No IgnoredUsersChanged here: the Dart caller write-throughs the
            // returned list and revalidates itself, and the genuine account-data
            // echo arrives via the sync event handler. Notifying a local write
            // through the same event would race the FFI future on a different
            // channel — if it landed after the write-through, it would demote
            // the just-confirmed list and bump the generation as if a
            // cross-device change had happened.
            Ok(updated)
        },
    )
    .await
}

/// List current requests to join a knock-enabled room.
fn knock_member_events_request(
    room_id: matrix_sdk::ruma::OwnedRoomId,
) -> matrix_sdk::ruma::api::client::membership::get_member_events::v3::Request {
    use matrix_sdk::ruma::events::room::member::MembershipState;

    let mut request =
        matrix_sdk::ruma::api::client::membership::get_member_events::v3::Request::new(room_id);
    request.membership = Some(MembershipState::Knock);
    request
}

#[frb]
pub async fn get_room_knock_requests(room_id: String) -> Result<Vec<KnockRequest>, String> {
    use matrix_sdk::ruma::events::room::member::{MembershipState, RoomMemberEvent};

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = joined_non_space_room(&client, &room_id)?;
    let request = knock_member_events_request(room.room_id().to_owned());
    let response = run_bounded(async move {
        client
            .send(request)
            .await
            .map_err(|error| api_err("rooms", format!("无法加载加入请求列表: {error}")))
    })
    .await?;
    let mut requests = Vec::with_capacity(response.chunk.len());
    for raw in response.chunk {
        let event: RoomMemberEvent = raw
            .deserialize()
            .map_err(|error| api_err("rooms", format!("无法解析加入请求数据: {error}")))?;
        let RoomMemberEvent::Original(event) = event else {
            continue;
        };
        if event.content.membership != MembershipState::Knock {
            continue;
        }
        let user_id = event.state_key.to_string();
        requests.push(KnockRequest {
            display_name: event.content.displayname.unwrap_or_else(|| user_id.clone()),
            avatar_url: event.content.avatar_url.map(|url| url.to_string()),
            reason: event.content.reason,
            user_id,
        });
    }
    Ok(requests)
}

#[cfg(test)]
mod knock_request_tests {
    use super::knock_member_events_request;
    use matrix_sdk::ruma::{events::room::member::MembershipState, room_id};

    #[test]
    fn knock_member_query_is_filtered_authoritatively() {
        let request = knock_member_events_request(room_id!("!room:example.org").to_owned());

        assert_eq!(request.membership, Some(MembershipState::Knock));
    }
}

/// Map a knock pre-verification read failure: a 404 (the member event was
/// never synced, or was redacted after another admin handled the request)
/// is the same "state already changed" outcome as a non-knock membership —
/// the page hides the request and refreshes, so the generic "请重试"
/// wording would mislead. Other errors fail closed with a retryable
/// wording.
fn knock_state_read_failure(error: &matrix_sdk::HttpError) -> String {
    let text = format!("{error}");
    // A missing member event surfaces as a 404 with the standard
    // M_NOT_FOUND error kind; match either marker.
    if text.contains("M_NOT_FOUND") || text.contains("404") {
        return api_err("rooms", "该用户已不再是此房间的加入请求。".to_string());
    }
    api_err("rooms", format!("无法确认加入请求状态，请重试: {error}"))
}

/// Accept a knock request by inviting the requester to the room.
#[frb]
pub async fn approve_room_knock(
    account_user_id: String,
    room_id: String,
    user_id: String,
) -> Result<(), String> {
    use matrix_sdk::ruma::api::client::state::get_state_event_for_key;
    use matrix_sdk::ruma::events::room::member::{MembershipState, RoomMemberEventContent};
    use matrix_sdk::ruma::events::StateEventType;

    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id.trim())
        .map_err(|error| api_err("rooms", format!("无效的用户 ID: {error}")))?;
    // Symmetric with reject_room_knock: the knock list can lag the server
    // (the user withdrew the request, or another admin handled it). Inviting
    // on stale data would add a member who is no longer knocking, so
    // re-verify the current membership from the server first. Fail closed
    // when the state cannot be read.
    let request = get_state_event_for_key::v3::Request::new(
        room.room_id().to_owned(),
        StateEventType::RoomMember,
        user_id.to_string(),
    );
    let client_for_verify = client.clone();
    run_bounded(async move {
        let response = client_for_verify
            .send(request)
            .await
            .map_err(|error| knock_state_read_failure(&error))?;
        // Spec-compliant servers return the bare event content; some return
        // the full state event instead. Try the content-only form first,
        // then extract the `content` field. Either way the decode failure
        // fails closed (no invite/kick on unverifiable state).
        let raw = response.event_or_content.get();
        let content: RoomMemberEventContent = match serde_json::from_str(raw) {
            Ok(content) => content,
            Err(_) => serde_json::from_str::<serde_json::Value>(raw)
                .ok()
                .and_then(|value| value.get("content").cloned())
                .and_then(|value| serde_json::from_value(value).ok())
                .ok_or_else(|| api_err("rooms", "无法确认加入请求状态，请重试。".to_string()))?,
        };
        if content.membership != MembershipState::Knock {
            return Err(api_err(
                "rooms",
                "该用户已不再是此房间的加入请求。".to_string(),
            ));
        }
        room.invite_user_by_id(&user_id).await.map_err(|error| {
            // The membership was verified as knock moments ago, but another
            // admin may have rejected the request (or the user withdrew it)
            // in between, turning the invite into a failed action on a
            // stale request. Tell the user the state may have changed
            // instead of a bare failure.
            api_err(
                "rooms",
                format!("批准加入请求失败: {error}（该用户可能已被其他管理员处理）"),
            )
        })?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

/// Decline a knock request by removing the requester from the room.
#[frb]
pub async fn reject_room_knock(
    account_user_id: String,
    room_id: String,
    user_id: String,
) -> Result<(), String> {
    use matrix_sdk::ruma::api::client::state::get_state_event_for_key;
    use matrix_sdk::ruma::events::room::member::{MembershipState, RoomMemberEventContent};
    use matrix_sdk::ruma::events::StateEventType;

    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = joined_non_space_room(&client, &room_id)?;
    let user_id = matrix_sdk::ruma::UserId::parse(user_id.trim())
        .map_err(|error| api_err("rooms", format!("无效的用户 ID: {error}")))?;
    // The knock list can lag the server (another admin may have approved the
    // request, or the user withdrew it): re-verify the current membership
    // from the server before kicking, since `kick_user` would otherwise
    // eject a member who is no longer knocking. Fail closed when the state
    // cannot be read — never kick on stale data.
    let request = get_state_event_for_key::v3::Request::new(
        room.room_id().to_owned(),
        StateEventType::RoomMember,
        user_id.to_string(),
    );
    let client_for_verify = client.clone();
    run_bounded(async move {
        let response = client_for_verify
            .send(request)
            .await
            .map_err(|error| knock_state_read_failure(&error))?;
        // Spec-compliant servers return the bare event content; some return
        // the full state event instead. Try the content-only form first,
        // then extract the `content` field. Either way the decode failure
        // fails closed (no invite/kick on unverifiable state).
        let raw = response.event_or_content.get();
        let content: RoomMemberEventContent = match serde_json::from_str(raw) {
            Ok(content) => content,
            Err(_) => serde_json::from_str::<serde_json::Value>(raw)
                .ok()
                .and_then(|value| value.get("content").cloned())
                .and_then(|value| serde_json::from_value(value).ok())
                .ok_or_else(|| api_err("rooms", "无法确认加入请求状态，请重试。".to_string()))?,
        };
        if content.membership != MembershipState::Knock {
            return Err(api_err(
                "rooms",
                "该用户已不再是此房间的加入请求。".to_string(),
            ));
        }
        room.kick_user(&user_id, None).await.map_err(|error| {
            // The membership was verified as knock moments ago, but another
            // admin may have approved it in between, turning the kick into a
            // failed removal of a joined member. Tell the user the state may
            // have changed instead of a bare failure.
            api_err(
                "rooms",
                format!("拒绝加入请求失败: {error}（该用户可能已被其他管理员处理）"),
            )
        })?;
        Ok(())
    })
    .await?;
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn get_spaces() -> Result<Vec<Space>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;

    // Bounded like the other P0 reads: the scan (room_to_chat_room per
    // room, including the notification-settings reads) holds the client
    // lease for its whole duration.
    run_bounded(async move {
        let mut spaces = Vec::new();
        for room in client.rooms() {
            if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
                continue;
            }
            let chat_room = room_to_chat_room(&room, None, false).await;
            spaces.push(Space {
                id: chat_room.id,
                name: chat_room.name,
                avatar_url: chat_room.avatar_url,
            });
        }

        spaces.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        Ok(spaces)
    })
    .await
}

#[frb]
pub async fn get_space_details(space_id: String) -> Result<SpaceDetails, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;

    if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
        return Err(api_err(
            "spaces",
            format!("该空间不是已加入状态: {space_id}"),
        ));
    }

    let chat_room = room_to_chat_room(&room, None, false).await;
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

/// Extract the child room ID from an `m.space.child` state event. Events
/// without any `via` server cannot be joined reliably, so per the spec they
/// do not count as space children — this is the single predicate both
/// `get_space_children` and `get_ungrouped_rooms` use to decide that.
fn space_child_room_id(
    child_event: matrix_sdk::deserialized_responses::SyncOrStrippedState<
        matrix_sdk::ruma::events::space::child::SpaceChildEventContent,
    >,
) -> Option<matrix_sdk::ruma::OwnedRoomId> {
    match child_event {
        matrix_sdk::deserialized_responses::SyncOrStrippedState::Sync(
            matrix_sdk::ruma::events::SyncStateEvent::Original(event),
        ) if !event.content.via.is_empty() => Some(event.state_key),
        matrix_sdk::deserialized_responses::SyncOrStrippedState::Stripped(event)
            if event
                .content
                .via
                .as_ref()
                .is_some_and(|via| !via.is_empty()) =>
        {
            Some(event.state_key)
        }
        _ => None,
    }
}

#[cfg(test)]
mod space_child_tests {
    use matrix_sdk::{
        deserialized_responses::SyncOrStrippedState,
        ruma::events::space::child::SpaceChildEventContent,
    };

    use super::space_child_room_id;

    fn sync_child_event(content: serde_json::Value) -> SyncOrStrippedState<SpaceChildEventContent> {
        SyncOrStrippedState::Sync(
            serde_json::from_value(serde_json::json!({
                "type": "m.space.child",
                "state_key": "!child:example.org",
                "sender": "@admin:example.org",
                "event_id": "$event:example.org",
                "origin_server_ts": 1,
                "content": content,
            }))
            .unwrap(),
        )
    }

    fn stripped_child_event(
        content: serde_json::Value,
    ) -> SyncOrStrippedState<SpaceChildEventContent> {
        SyncOrStrippedState::Stripped(
            serde_json::from_value(serde_json::json!({
                "type": "m.space.child",
                "state_key": "!child:example.org",
                "sender": "@admin:example.org",
                "content": content,
            }))
            .unwrap(),
        )
    }

    #[test]
    fn child_with_via_is_grouped() {
        let expected = matrix_sdk::ruma::RoomId::parse("!child:example.org").unwrap();
        assert_eq!(
            space_child_room_id(sync_child_event(
                serde_json::json!({ "via": ["example.org"] })
            )),
            Some(expected.clone())
        );
        assert_eq!(
            space_child_room_id(stripped_child_event(
                serde_json::json!({ "via": ["example.org"] })
            )),
            Some(expected)
        );
    }

    #[test]
    fn child_without_via_stays_ungrouped() {
        // Empty or missing via: the room must NOT be treated as grouped, so it
        // remains visible in get_ungrouped_rooms (and out of get_space_children).
        assert_eq!(
            space_child_room_id(sync_child_event(serde_json::json!({ "via": [] }))),
            None
        );
        assert_eq!(
            space_child_room_id(stripped_child_event(serde_json::json!({ "via": [] }))),
            None
        );
        assert_eq!(
            space_child_room_id(stripped_child_event(serde_json::json!({}))),
            None
        );
    }
}

#[frb]
pub async fn get_space_children(
    space_id: String,
    ignored_user_ids: Option<Vec<String>>,
    authoritative: bool,
) -> Result<Vec<ChatRoom>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    let ignored_user_ids =
        ignored_user_ids.map(|ids| ids.into_iter().collect::<std::collections::HashSet<_>>());

    // Bounded like the other P0 reads: the per-child room_to_chat_room
    // (notification settings, members_no_sync) holds the client lease for
    // the whole scan.
    run_bounded(async move {
        let space_room = client
            .get_room(
                &matrix_sdk::ruma::RoomId::parse(space_id.clone())
                    .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?,
            )
            .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;

        let child_events = space_room
            .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
            .await
            .map_err(|e| api_err("spaces", format!("加载空间子房间失败: {e}")))?;

        let mut child_rooms = Vec::new();
        for raw_child in child_events {
            let Ok(child_event) = raw_child.deserialize() else {
                continue;
            };
            let Some(child_room_id) = space_child_room_id(child_event) else {
                continue;
            };

            let Some(child_room) = client.get_room(&child_room_id) else {
                continue;
            };
            if child_room.state() != matrix_sdk::RoomState::Joined {
                continue;
            }

            let mut chat_room =
                room_to_chat_room(&child_room, ignored_user_ids.as_ref(), authoritative).await;
            if !child_room.is_space() {
                // Mirror the main chat list's DM classification (m.direct OR
                // the member-count heuristic): a DM created by the other
                // party has no m.direct entry here and would otherwise show
                // as a group inside the space.
                chat_room.room_type = if matches!(child_room.is_direct().await, Ok(true))
                    || is_dm_by_members(&child_room).await
                {
                    "dm".to_string()
                } else {
                    "group".to_string()
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
    })
    .await
}

#[frb]
pub async fn update_space_details(
    account_user_id: String,
    space_id: String,
    name: String,
    topic: Option<String>,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;

    if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
        return Err(api_err(
            "spaces",
            format!("该空间不是已加入状态: {space_id}"),
        ));
    }

    let trimmed_name = name.trim().to_string();
    if trimmed_name.is_empty() {
        return Err(api_err("spaces", "空间名称不能为空。".to_string()));
    }

    // Bounded like the other P0 writes: two sequential state writes hold the
    // client lease.
    run_bounded(async move {
        room.set_name(trimmed_name)
            .await
            .map_err(|e| api_err("spaces", format!("更新空间名称失败: {e}")))?;
        notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);

        let normalized_topic = topic.unwrap_or_default().trim().to_string();
        // Write unconditionally: comparing against room.topic() would use
        // the SDK snapshot, which may still predate a just-completed write
        // and silently drop a quick A -> B -> A change (same decision as
        // `update_room_details`). The write is an idempotent state event.
        room.set_room_topic(&normalized_topic).await.map_err(|e| {
            // The name write above already landed: say so instead of
            // reporting a plain whole-action failure.
            api_err("spaces", format!("空间名称已更新，但主题更新失败: {e}"))
        })?;
        notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);

        app_log(
            "info",
            "rooms",
            format!("Updated space details: {}", space_id),
        );
        info!("Updated space details: {}", space_id);
        Ok(())
    })
    .await?;
    Ok(())
}

/// Add a room to a space, and advertise the reciprocal parent relation.
#[frb]
pub async fn add_room_to_space(
    account_user_id: String,
    space_id: String,
    room_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let child_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的房间 ID: {e}")))?;

    let space_room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;
    let child_room = client
        .get_room(&child_room_id)
        .ok_or_else(|| api_err("spaces", format!("房间不存在: {room_id}")))?;

    let via = vec![client
        .user_id()
        .ok_or_else(|| api_err("spaces", "No active user.".to_string()))?
        .server_name()
        .to_owned()];
    let current_user_id = client
        .user_id()
        .ok_or_else(|| api_err("spaces", "No active user.".to_string()))?
        .to_owned();

    // Bounded like the other P0 writes: two sequential state writes hold the
    // client lease.
    run_bounded(async move {
        let can_set_parent = match child_room.power_levels().await {
            Ok(power_levels) => {
                power_levels.user_can_send_state(&current_user_id, StateEventType::SpaceParent)
            }
            Err(error) => {
                app_log(
                    "warn",
                    "rooms",
                    format!(
                        "Unable to check child-room power levels; skipping parent link: {error}"
                    ),
                );
                false
            }
        };
        space_room
            .send_state_event_for_key(
                &child_room_id,
                matrix_sdk::ruma::events::space::child::SpaceChildEventContent::new(via.clone()),
            )
            .await
            .map_err(|e| api_err("spaces", format!("将房间加入空间失败: {e}")))?;
        notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);

        if can_set_parent {
            child_room
                .send_state_event_for_key(
                    &space_room_id,
                    matrix_sdk::ruma::events::space::parent::SpaceParentEventContent::new(via),
                )
                .await
                .map_err(|e| {
                    // The child relation already landed: say so instead of
                    // reporting a plain whole-action failure (same
                    // partial-success discipline as update_space_details; a
                    // retry converges — the child write is done).
                    api_err("spaces", format!("已加入空间，但设置空间父级失败: {e}"))
                })?;
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        }

        app_log(
            "info",
            "rooms",
            format!("Added room {} to space {}", room_id, space_id),
        );
        info!("Added room {} to space {}", room_id, space_id);
        Ok(())
    })
    .await?;
    Ok(())
}

#[frb]
pub async fn remove_room_from_space(
    account_user_id: String,
    space_id: String,
    room_id: String,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let child_room_id = matrix_sdk::ruma::RoomId::parse(room_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的房间 ID: {e}")))?;

    let space_room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;
    let child_room = client
        .get_room(&child_room_id)
        .ok_or_else(|| api_err("spaces", format!("房间不存在: {room_id}")))?;
    let current_user_id = client
        .user_id()
        .ok_or_else(|| api_err("spaces", "No active user.".to_string()))?
        .to_owned();

    // Bounded like the other P0 writes: the state reads and writes hold
    // the client lease.
    run_bounded(async move {
        let child_events = space_room
            .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
            .await
            .map_err(|e| api_err("spaces", format!("加载空间子房间失败: {e}")))?;
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
            .map_err(|e| api_err("spaces", format!("加载空间父级失败: {e}")))?;
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

        let can_remove_parent = match child_room.power_levels().await {
            Ok(power_levels) => {
                power_levels.user_can_send_state(&current_user_id, StateEventType::SpaceParent)
            }
            Err(error) => {
                app_log(
                    "warn",
                    "rooms",
                    format!(
                        "Unable to check child-room power levels; skipping parent cleanup: {error}"
                    ),
                );
                false
            }
        };

        let relationship_found = space_child_event_id.is_some() || space_parent_event_id.is_some();
        let mut child_removed = false;
        if space_child_event_id.is_some() {
            space_room
                .send_state_event_raw(
                    "m.space.child",
                    child_room_id.as_str(),
                    serde_json::json!({}),
                )
                .await
                .map_err(|e| api_err("spaces", format!("将房间移出空间失败: {e}")))?;
            child_removed = true;
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        }

        if space_parent_event_id.is_some() && can_remove_parent {
            child_room
                .send_state_event_raw(
                    "m.space.parent",
                    space_room_id.as_str(),
                    serde_json::json!({}),
                )
                .await
                .map_err(|e| {
                    // The child side may already be gone: say so instead of
                    // reporting a plain whole-action failure (same
                    // partial-success discipline as update_space_details;
                    // a retry converges — the child link is already empty).
                    if child_removed {
                        api_err("spaces", format!("已从空间移除，但父级关系清理失败: {e}"))
                    } else {
                        api_err("spaces", format!("移除空间父级关系失败: {e}"))
                    }
                })?;
            notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
        } else if space_parent_event_id.is_some() {
            app_log(
                "warn",
                "rooms",
                "Skipping parent cleanup without child-room permission.".to_string(),
            );
        }

        if !relationship_found {
            // Neither direction of the relationship is known locally: the
            // child/parent events may not have synced here yet (created on
            // another device, or one-directional). Fail closed like the
            // knock actions — the UI must not claim "已从空间移除" while
            // the server relationship survives.
            return Err(api_err("spaces", "未能找到空间关系，请刷新后重试".to_string()));
        }

        app_log(
            "info",
            "rooms",
            format!("Removed room {} from space {}", room_id, space_id),
        );
        info!("Removed room {} from space {}", room_id, space_id);
        Ok(())
    })
    .await?;
    Ok(())
}

#[frb]
pub async fn leave_space(account_user_id: String, space_id: String) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;

    let space_room_id = matrix_sdk::ruma::RoomId::parse(space_id.clone())
        .map_err(|e| api_err("spaces", format!("无效的空间 ID: {e}")))?;
    let room = client
        .get_room(&space_room_id)
        .ok_or_else(|| api_err("spaces", format!("空间不存在: {space_id}")))?;

    if !room.is_space() {
        return Err(api_err("spaces", format!("该房间不是空间: {space_id}")));
    }

    run_bounded(async move {
        room.leave()
            .await
            .map_err(|e| api_err("spaces", format!("退出空间失败: {e}")))?;
        Ok(())
    })
    .await?;

    app_log("info", "rooms", format!("Left space: {}", space_id));
    info!("Left space: {}", space_id);
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

#[frb]
pub async fn get_ungrouped_rooms(
    ignored_user_ids: Option<Vec<String>>,
    authoritative: bool,
) -> Result<Vec<ChatRoom>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("spaces", "No client created.".to_string()))?;
    let ignored_user_ids =
        ignored_user_ids.map(|ids| ids.into_iter().collect::<std::collections::HashSet<_>>());

    // Bounded like the other P0 reads: the double room scan (space children
    // state reads + per-room room_to_chat_room) holds the client lease for
    // its whole duration.
    run_bounded(async move {
        let mut grouped_room_ids = std::collections::HashSet::new();
        for room in client.rooms() {
            if room.state() != matrix_sdk::RoomState::Joined || !room.is_space() {
                continue;
            }

            let child_events = room
                .get_state_events_static::<matrix_sdk::ruma::events::space::child::SpaceChildEventContent>()
                .await
                .map_err(|e| api_err("spaces", format!("加载空间子房间失败: {e}")))?;

            for raw_child in child_events {
                let Ok(child_event) = raw_child.deserialize() else {
                    continue;
                };
                // Same predicate as get_space_children: a child event without
                // any `via` server doesn't group the room, so the room stays
                // visible in this ungrouped list.
                if let Some(child_room_id) = space_child_room_id(child_event) {
                    grouped_room_ids.insert(child_room_id);
                }
            }
        }

        let mut rooms = Vec::new();
        for room in client.rooms() {
            if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
                continue;
            }

            // Exclude DMs with the SAME classification the main chat list
            // uses (m.direct OR the member-count heuristic): a DM created
            // by the other party has no m.direct entry here, and would
            // otherwise show up in both the chat list and this ungrouped
            // list.
            if matches!(room.is_direct().await, Ok(true)) || is_dm_by_members(&room).await {
                continue;
            }

            if grouped_room_ids.contains(room.room_id()) {
                continue;
            }

            let mut chat_room =
                room_to_chat_room(&room, ignored_user_ids.as_ref(), authoritative).await;
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
    })
    .await
}

#[frb]
pub async fn get_contacts() -> Result<Vec<Contact>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("contacts", "No client created.".to_string()))?;
    let my_user_id = client.user_id().map(|user_id| user_id.to_string());
    // Bounded like the other P0 reads: each room's `members()` call can
    // fetch /members over the network while holding the client lease, so an
    // unbounded scan would block logout/account switch for N rooms x the
    // request budget on a dead network.
    let contacts_by_id = run_bounded(async move {
        let mut contacts_by_id: HashMap<String, Contact> = HashMap::new();
        for room in client.rooms() {
            if room.state() != matrix_sdk::RoomState::Joined || room.is_space() {
                continue;
            }

            let members = room
                .members(matrix_sdk::RoomMemberships::JOIN)
                .await
                .map_err(|e| api_err("contacts", format!("获取联系人失败: {e}")))?;

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
        Ok(contacts_by_id)
    })
    .await?;

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
    account_user_id: String,
    room_id: String,
    message: FormattedMessageInput,
    reply_to_event_id: String,
    reply_to_user_id: Option<String>,
) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    // Parse the event ID we're replying to
    let event_id = matrix_sdk::ruma::EventId::parse(&reply_to_event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;

    let mut reply_content = build_text_content(message)?;
    if let Some(reply_to_user_id) = reply_to_user_id {
        let reply_to_user_id = matrix_sdk::ruma::UserId::parse(&reply_to_user_id)
            .map_err(|e| api_err("rooms", format!("Invalid reply user ID: {e}")))?;
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
        .map_err(|e| api_err("rooms", format!("Reply failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Reply sent to {} in room {}", reply_to_event_id, room_id),
    );
    info!("Reply sent to {} in room {}", reply_to_event_id, room_id);
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
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
    account_user_id: String,
    room_id: String,
    event_id: String,
    message: FormattedMessageInput,
    previous_mentioned_user_ids: Vec<String>,
    previous_mentions_room: bool,
) -> Result<String, String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;

    use matrix_sdk::ruma::events::room::message::ReplacementMetadata;
    let previous_mentions = build_mentions(&previous_mentioned_user_ids, previous_mentions_room)?;
    let content = build_text_content(message)?.make_replacement(ReplacementMetadata::new(
        parsed_event_id,
        Some(previous_mentions),
    ));

    let response = room
        .send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Edit failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Edited event {} in room {}", event_id, room_id),
    );
    info!("Edited event {} in room {}", event_id, room_id);
    notify_sync_event_for_generation(
        generation,
        SyncEvent::MessageSent {
            room_id: room_id.clone(),
        },
    );
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
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;

    use matrix_sdk::ruma::events::relation::Annotation;
    let content = matrix_sdk::ruma::events::reaction::ReactionEventContent::from(Annotation::new(
        parsed_event_id,
        key.clone(),
    ));

    let handle = room
        .send(content)
        .await
        .map_err(|e| api_err("rooms", format!("Reaction failed: {e}")))?;
    let new_event_id = handle.response.event_id.to_string();

    app_log(
        "info",
        "rooms",
        format!("Reaction '{}' on {} in room {}", key, event_id, room_id),
    );
    info!("Reaction '{}' on {} in room {}", key, event_id, room_id);
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(new_event_id)
}

/// Redact (delete) a message from a room.
#[frb]
pub async fn redact_message(
    room_id: String,
    event_id: String,
    reason: Option<String>,
) -> Result<(), String> {
    let generation = SYNC_GENERATION.load(Ordering::SeqCst);

    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;

    let parsed_event_id = matrix_sdk::ruma::EventId::parse(&event_id)
        .map_err(|e| api_err("rooms", format!("无效的事件 ID: {e}")))?;

    room.redact(&parsed_event_id, reason.as_deref(), None)
        .await
        .map_err(|e| api_err("rooms", format!("Redact failed: {e}")))?;

    app_log(
        "info",
        "rooms",
        format!("Redacted event {} in room {}", event_id, room_id),
    );
    info!("Redacted event {} in room {}", event_id, room_id);
    notify_sync_event_for_generation(generation, SyncEvent::SyncCompleted);
    Ok(())
}

/// Send a typing notice to a room.
#[frb]
pub async fn send_typing_notice(
    account_user_id: String,
    room_id: String,
    typing: bool,
) -> Result<(), String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("typing", "No client created.".to_string()))?;
    ensure_account_matches(&client, &account_user_id)?;
    let room = get_room_by_id(&client, &room_id)?;

    room.typing_notice(typing)
        .await
        .map_err(|e| api_err("typing", format!("Typing notice failed: {e}")))?;
    Ok(())
}

/// Get members of a room.
#[frb]
pub async fn get_room_members(room_id: String) -> Result<Vec<Contact>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    // Bounded like the other P0 calls: `members()` can issue a network
    // /members request (lazy-loaded member list) while holding the client
    // lease.
    run_bounded(async move {
        let members = room
            .members(matrix_sdk::RoomMemberships::JOIN)
            .await
            .map_err(|e| api_err("rooms", format!("获取成员失败: {e}")))?;

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
    })
    .await
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
pub async fn search_rooms(
    query: String,
    ignored_user_ids: Option<Vec<String>>,
    authoritative: bool,
) -> Result<Vec<ChatRoom>, String> {
    let all = get_chat_rooms(ignored_user_ids, authoritative).await?;
    let q = query.to_lowercase();
    let filtered: Vec<ChatRoom> = all
        .into_iter()
        .filter(|r| r.name.to_lowercase().contains(&q))
        .collect();
    Ok(filtered)
}

/// Load a focused slice of the room timeline around one event.
#[frb]
pub async fn get_messages_around(
    room_id: String,
    event_id: String,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    run_bounded(
        async move { sdk_timeline::get_messages_around(&room, &event_id, limit as usize).await },
    )
    .await
}

/// Load more messages (paginated) from before a given event.
#[frb]
pub async fn get_messages_before(
    room_id: String,
    from_event_id: String,
    limit: u32,
) -> Result<Vec<ChatMessage>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("rooms", "No client created.".to_string()))?;
    let room = get_room_by_id(&client, &room_id)?;
    // Bounded like the other P0 calls: pagination holds the client lease.
    run_bounded(async move {
        sdk_timeline::get_messages_before(&client, &room, &from_event_id, limit).await
    })
    .await
}

#[cfg(test)]
mod media_download_tests {
    use super::{
        append_media_chunk, ensure_media_content_length, media_download_limit, media_download_url,
        truncate_utf8,
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

    #[test]
    fn log_truncation_preserves_utf8_boundaries() {
        let value = format!("{}界", "a".repeat(299));
        assert_eq!(truncate_utf8(&value, 300), "a".repeat(299));
        assert_eq!(truncate_utf8("中文", 500), "中文");
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

    #[tokio::test]
    async fn media_download_url_preserves_the_homeserver_path_prefix() {
        let client = Client::new(url::Url::parse("https://example.org/matrix/").unwrap())
            .await
            .unwrap();
        let source = serde_json::from_str(r#"{"url":"mxc://media.example/media-id"}"#).unwrap();

        let url = media_download_url(&client, &source).unwrap();

        assert_eq!(
            url.as_str(),
            "https://example.org/matrix/_matrix/client/v1/media/download/media.example/media-id"
        );
    }
}
