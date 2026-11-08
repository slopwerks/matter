//! Shared runtime ownership; one set of account locks, leases and subscriptions.
use super::*;

// ── Connection state tracking ──────────────────────────────────────
pub(super) static CONNECTION_STATE: Lazy<std::sync::RwLock<ConnectionStatus>> =
    Lazy::new(|| std::sync::RwLock::new(ConnectionStatus::Disconnected));

pub(super) static SYNC_PUBLICATION_LOCK: Lazy<std::sync::Mutex<()>> =
    Lazy::new(|| std::sync::Mutex::new(()));

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(super) enum SessionExpiry {
    Unknown,
    SoftLogout,
    HardLogout,
}

pub(super) static SESSION_EXPIRY: Lazy<std::sync::RwLock<Option<SessionExpiry>>> =
    Lazy::new(|| std::sync::RwLock::new(None));

pub(super) static SYNC_EVENT_TX: Lazy<tokio::sync::broadcast::Sender<SyncEvent>> =
    Lazy::new(|| {
        // Generous capacity: a large catch-up sync (reconnect, cold start) can
        // emit one MessageSent per message-like event, and a lagging Dart side
        // must not force a FullRefreshRequired storm on every such burst.
        let (tx, _rx) = tokio::sync::broadcast::channel(512);
        tx
    });

pub(super) type MutationFuture = Shared<BoxFuture<'static, Result<(), String>>>;

pub(super) type LifecycleProtection = Arc<tokio::sync::RwLockReadGuard<'static, ()>>;

/// The caller-side timeout message of `run_bounded_mutation`. Kept as a
/// single constant because `mark_room_as_read` distinguishes the queue-wait
/// timeout (the clear never ran and keeps running in the background) from a
/// genuine clear failure by comparing against this exact string — a
/// reworded message would otherwise turn "still running" into a bogus
/// "failed, retry".
pub(super) const MUTATION_TIMEOUT_MESSAGE: &str = "操作超时，请稍后查看最终状态。";

/// Error surfaced when a mutation key's queue is already at its depth
/// limit: the operation was rejected outright instead of chaining. Distinct
/// from MUTATION_TIMEOUT_MESSAGE ("still running in the background") so the
/// Dart side can tell the two apart.
pub(super) const MUTATION_QUEUE_FULL_MESSAGE: &str = "操作排队已满，请稍后重试。";

/// Maximum operations chained on a single mutation key (1 running + 2
/// queued). Every chained operation holds a share of the SYNC_LIFECYCLE
/// read lease from enqueue until completion, so an unbounded chain under a
/// bad server (user retries stacking up) would stall logout/account switch
/// — which need the write lock — for minutes. New enqueues are rejected
/// instead of extending the chain beyond this bound.
pub(super) const MUTATION_QUEUE_MAX_DEPTH: usize = 3;

pub(super) struct MutationTail {
    pub(super) id: u64,
    /// Chain depth when this tail was enqueued: 1 for the running
    /// operation, +1 per queued successor. Stays monotonic along the chain
    /// (a completing predecessor does not decrement it), so it is an upper
    /// bound on the remaining chain length — exactly what the depth limit
    /// needs to reject a new enqueue.
    pub(super) depth: usize,
    pub(super) future: MutationFuture,
}

pub(super) static MUTATION_TAILS: Lazy<std::sync::Mutex<HashMap<String, MutationTail>>> =
    Lazy::new(|| std::sync::Mutex::new(HashMap::new()));

pub(super) static NEXT_MUTATION_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy)]
pub(super) struct MarkedUnreadOverride {
    pub(super) baseline: bool,
    pub(super) desired: bool,
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
    pub(super) created_at: std::time::Instant,
}

pub(super) const MARKED_UNREAD_OVERRIDE_TTL: std::time::Duration =
    std::time::Duration::from_secs(30);

pub(super) static MARKED_UNREAD_OVERRIDES: Lazy<RwLock<HashMap<String, MarkedUnreadOverride>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

#[derive(Clone, Copy)]
pub(super) struct IgnoredUserOverride {
    pub(super) baseline: bool,
    pub(super) desired: bool,
    /// Set when an ignored-list event arrived that did not contain this
    /// target. After the TTL the override expires (ABA protection: a
    /// cross-device un-ignore may have coalesced the list back to the
    /// pre-write baseline). None while no event has been seen, so an offline
    /// window — the exact case overrides exist for — never expires them.
    pub(super) event_seen: Option<std::time::Instant>,
}

/// How long an ignore override survives after an account-data event that
/// does not confirm its target, before the authoritative store wins.
pub(super) const IGNORED_OVERRIDE_TTL: std::time::Duration = std::time::Duration::from_secs(30);

/// Per-account ignored-user overrides for locally confirmed writes whose
/// account-data echo has not synced yet: `set_account_data` does not update
/// the SDK state store, so `Client::is_user_ignored` would keep serving the
/// pre-write value and room previews would stay visible until the echo (or
/// indefinitely, if connectivity drops first).
pub(super) static IGNORED_USER_OVERRIDES: Lazy<RwLock<HashMap<String, IgnoredUserOverride>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

/// Per-account notification-settings handles. Reusing one instance matters:
/// it applies its own writes to its internal ruleset, while a fresh instance
/// initializes from the local store copy of push rules, which lags the sync
/// echo and can turn a rapid mute/unmute/re-mute sequence into a no-op.
pub(super) static NOTIFICATION_SETTINGS: Lazy<
    RwLock<HashMap<String, matrix_sdk::notification_settings::NotificationSettings>>,
> = Lazy::new(|| RwLock::new(HashMap::new()));

pub(super) const MEDIA_DOWNLOAD_TOTAL_TIMEOUT: std::time::Duration =
    std::time::Duration::from_secs(120);

pub(super) const MEDIA_SEND_TOTAL_TIMEOUT: std::time::Duration =
    std::time::Duration::from_secs(600);

pub(super) const MEDIA_EVENT_SEND_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(90);

pub(super) static SESSION_TOKEN_TX: Lazy<tokio::sync::broadcast::Sender<SessionTokenUpdate>> =
    Lazy::new(|| tokio::sync::broadcast::channel(16).0);

/// Queue-wait timeout for mutations sharing a key (seconds). Test overrides
/// this so they do not wait the real 30s.
pub(super) static MUTATION_WAIT_TIMEOUT_SECS: AtomicU64 = AtomicU64::new(30);

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
pub(super) static MUTATION_EXECUTION_TIMEOUT_SECS: AtomicU64 = AtomicU64::new(300);

/// Accounts whose remote logout failed or timed out (their access token may
/// still be valid on the server): user_id → (access_token, homeserver_url).
/// Retried best-effort when the same account logs in again on the SAME
/// homeserver (`finalize_pending`), so a dead-network logout does not leave
/// a permanently valid ghost session behind.
pub(super) static PENDING_REMOTE_LOGOUTS: Lazy<RwLock<HashMap<String, (String, String)>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

// ── Multi-account store ──────────────────────────────────────────────
pub(super) struct ClientEntry {
    pub(super) client: Client,
    pub(super) data_dir: String,
    pub(super) search_index_dir: std::path::PathBuf,
    pub(super) instance_id: u64,
    pub(super) room_key_task: JoinHandle<()>,
}

impl ClientEntry {
    pub(super) async fn into_client_and_data_dir(self) -> (Client, String) {
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

#[derive(Clone)]
pub(super) struct SessionRelogin {
    pub(super) meta: SessionMeta,
    pub(super) data_dir: String,
    pub(super) homeserver_url: String,
    pub(super) instance_id: u64,
}

pub(super) static SESSION_RELOGIN: Lazy<RwLock<Option<SessionRelogin>>> =
    Lazy::new(|| RwLock::new(None));

pub(super) static SESSION_RELOGIN_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

pub(super) struct PendingEntry {
    pub(super) client: Client,
    pub(super) data_dir: String,
    pub(super) homeserver_url: String,
    pub(super) search_index_key: String,
}

/// All logged-in accounts, keyed by user_id.
pub(super) static CLIENTS: Lazy<Arc<RwLock<HashMap<String, ClientEntry>>>> =
    Lazy::new(|| Arc::new(RwLock::new(HashMap::new())));

pub(super) static NEXT_CLIENT_INSTANCE_ID: AtomicU64 = AtomicU64::new(1);

/// Next EventCache chunk to copy into a newly created persistent index. Each
/// background step is bounded so opening search never waits for a huge cache.
pub(super) static SEARCH_CACHE_BACKFILL_PROGRESS: Lazy<Mutex<HashMap<String, usize>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Serializes on-demand history pagination per account and room. Searches stay
/// responsive by reading the current index while this fills one remote page at
/// a time.
pub(super) static SEARCH_HISTORY_BACKFILLS: Lazy<Mutex<HashMap<String, Arc<Mutex<()>>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Rooms whose EventCache pagination has reached the beginning of history.
pub(super) static SEARCH_HISTORY_COMPLETE: Lazy<Mutex<HashSet<String>>> =
    Lazy::new(|| Mutex::new(HashSet::new()));

/// Latest search request for each account and room scope. Superseded searches
/// stop between room/index batches instead of scanning the remaining rooms.
pub(super) static SEARCH_QUERY_GENERATIONS: Lazy<Mutex<HashMap<String, u64>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Currently active account.
pub(super) static ACTIVE_USER: Lazy<Arc<RwLock<Option<String>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

/// Account allowed to create room-scoped subscriptions.
///
/// Callers pass the account that owns their route. Holding this read lock
/// until the subscription is registered orders an in-flight subscribe before
/// an account switch; the switch then clears it. Calls arriving after the
/// switch observe the new account and are rejected.
pub(super) static SUBSCRIPTION_USER: Lazy<RwLock<Option<String>>> = Lazy::new(|| RwLock::new(None));

pub(super) struct SyncTask {
    pub(super) user_id: String,
    pub(super) generation: u64,
    pub(super) handle: JoinHandle<()>,
}

pub(super) struct PendingSyncTask {
    pub(super) handle: JoinHandle<()>,
    pub(super) start: tokio::sync::oneshot::Sender<()>,
}

/// Exactly one account owns the app-wide background sync task at a time.
pub(super) static SYNC_TASK: Lazy<Mutex<Option<SyncTask>>> = Lazy::new(|| Mutex::new(None));

/// Sync startup and one-shot syncs take a read guard; account transitions take
/// a write guard. This drains untracked sync_once work before a client/store is
/// replaced or deleted and prevents start_sync from installing a task midway
/// through that transition.
pub(super) static SYNC_LIFECYCLE: Lazy<RwLock<()>> = Lazy::new(|| RwLock::new(()));

pub(super) static SYNC_GENERATION: AtomicU64 = AtomicU64::new(0);

pub(super) static NEXT_ROOM_SUBSCRIPTION_ID: AtomicU64 = AtomicU64::new(1);

/// Accounts whose sync loop has been degraded from Sliding Sync to the
/// traditional loop this session. Prevents the two loops from ping-ponging:
/// a degraded loop must not re-probe and upgrade back only to fail again
/// seconds later. Cleared on the next explicit `start_sync()` call so a
/// fresh session (or a recovered server) can retry Sliding Sync.
pub(super) static SYNC_DEGRADED_ACCOUNTS: Lazy<RwLock<HashSet<String>>> =
    Lazy::new(|| RwLock::new(HashSet::new()));

tokio::task_local! {
    pub(super) static SYNC_EVENT_GENERATION: u64;
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
pub(super) struct RoomSubscriptionState {
    /// Mounted chat screens by room, keyed by opaque owner tokens so a stale
    /// route from an old account cannot cancel a newer route for the same ID.
    pub(super) desired: HashMap<String, HashSet<String>>,
    /// The live Sliding Sync instance, present once the sync loop has built
    /// one (and reset to `None` when it's stopped).
    pub(super) active: Option<matrix_sdk::sliding_sync::SlidingSync>,
    pub(super) active_generation: Option<u64>,
}

pub(super) static ROOM_SUBSCRIPTION: Lazy<tokio::sync::Mutex<RoomSubscriptionState>> =
    Lazy::new(|| {
        tokio::sync::Mutex::new(RoomSubscriptionState {
            desired: HashMap::new(),
            active: None,
            active_generation: None,
        })
    });

impl RoomSubscriptionState {
    pub(super) fn add_desired(&mut self, room_id: &str, subscription_id: String) -> bool {
        let subscriptions = self.desired.entry(room_id.to_owned()).or_default();
        subscriptions.insert(subscription_id);
        subscriptions.len() == 1
    }

    pub(super) fn remove_desired(&mut self, room_id: &str, subscription_id: &str) -> bool {
        let Some(subscriptions) = self.desired.get_mut(room_id) else {
            return false;
        };
        if !subscriptions.remove(subscription_id) || !subscriptions.is_empty() {
            return false;
        }
        self.desired.remove(room_id);
        true
    }

    pub(super) fn reset(&mut self, preserve_desired: bool) {
        self.active = None;
        self.active_generation = None;
        if !preserve_desired {
            self.desired.clear();
        }
    }

    pub(super) fn clear_active_for_generation(&mut self, generation: u64) {
        if self.active_generation == Some(generation) {
            self.active = None;
            self.active_generation = None;
        }
    }
}

/// Temporary client during login (before we know the user_id for a per-user dir).
pub(super) static PENDING: Lazy<Arc<RwLock<Option<PendingEntry>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

/// Serializes the pending-login store lifecycle. `create_client` holds it
/// across its staging, client build and install; `cancel_pending_login` holds
/// it across its take-and-delete. Without it a cancel can unlink the
/// `_pending` store while a concurrent `create_client` is still building its
/// client on that path — `create_client` deliberately does not hold
/// `SYNC_LIFECYCLE` for the slow build, so the directory cleanup and the build
/// were previously unordered and the install could resurrect a pending client
/// whose SQLite files had just been unlinked.
///
/// Lock order (never inverted): `PENDING_LIFECYCLE` -> `SYNC_LIFECYCLE`.
pub(super) static PENDING_LIFECYCLE: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

#[derive(Clone, Debug)]
pub(super) struct VerificationSession {
    pub(super) user_id: String,
    pub(super) device_id: String,
    pub(super) flow_id: String,
    pub(super) incoming: bool,
    pub(super) accepted: bool,
}

pub(super) static VERIFICATION_SESSION: Lazy<Arc<RwLock<Option<VerificationSession>>>> =
    Lazy::new(|| Arc::new(RwLock::new(None)));

#[derive(Clone)]
pub(super) struct ClientIdentity {
    pub(super) user_id: String,
    pub(super) instance_id: u64,
}

pub(super) const ENCRYPTED_SEARCH_INDEX_MARKER: &str = ".matter-encrypted-v2";

pub(in crate::api) struct ClientLease {
    pub(super) client: Client,
    pub(super) lifecycle: LifecycleProtection,
}

impl Deref for ClientLease {
    type Target = Client;

    fn deref(&self) -> &Self::Target {
        &self.client
    }
}

impl ClientLease {
    pub(super) fn lifecycle_protection(&self) -> LifecycleProtection {
        self.lifecycle.clone()
    }
}

// Consecutive stream/rebuild failures above this threshold
// degrade to the traditional sync loop instead of retrying
// forever: a server that advertises MSC3575 but fails every
// request (or a proxy mangling the endpoint) must not pin the
// app to an unusable sync path for the whole session.
pub(super) const DEGRADE_AFTER_FAILURES: u32 = 5;

/// Consecutive sync failures above this threshold report `Disconnected`:
/// one dropped long-poll is routine on healthy networks (flaky networks,
/// proxy idle timeouts), so a single failure must not claim the connection
/// is down while everything else works.
pub(super) const SYNC_OFFLINE_AFTER_FAILURES: u32 = 2;

pub(super) static TYPING_TX: Lazy<tokio::sync::broadcast::Sender<TypingNotification>> =
    Lazy::new(|| {
        let (tx, _rx) = tokio::sync::broadcast::channel(64);
        tx
    });

/// Handle to the background task that owns the per-room typing subscription,
/// so we can abort it when switching rooms or leaving.
pub(super) struct TypingTask {
    pub(super) room_id: String,
    pub(super) subscription_id: String,
    pub(super) handle: tokio::task::JoinHandle<()>,
}

pub(super) static TYPING_TASK: Lazy<tokio::sync::Mutex<Option<TypingTask>>> =
    Lazy::new(|| tokio::sync::Mutex::new(None));

pub(super) static NEXT_TYPING_SUBSCRIPTION_ID: AtomicU64 = AtomicU64::new(1);

/// Download media content as raw bytes using the Matrix SDK's HTTP client.
/// This is more reliable than constructing URLs and loading from Flutter.
#[derive(Clone, Debug)]
pub(in crate::api) struct MediaClientIdentity {
    pub(super) user_id: String,
    pub(super) instance_id: u64,
}

#[derive(Clone, Debug)]
pub(super) struct EditedTextContent {
    pub(super) body: String,
}

/// Upper bound on DM-reuse candidates scanned with a `members()` call in
/// `create_dm`. Each candidate can fetch /members over the network (worst
/// case ~93s under `bounded_request_config`), so an account with many
/// DM-shaped rooms could otherwise keep the scan running for a very long
/// time. Hitting the cap fails closed (a clear, retryable error) rather
/// than risking a duplicate DM.
pub(super) const DM_REUSE_SCAN_MAX_CANDIDATES: usize = 50;

/// Elapsed-time bound for the same scan. create_dm runs undroppable (see
/// `run_bounded_mutation_undroppable`), so this — together with the
/// candidate cap above and the per-request HTTP bound — is what keeps the
/// operation's total duration bounded. Hitting it fails closed like the
/// candidate cap: the remaining candidates are unverifiable.
pub(super) const DM_REUSE_SCAN_MAX_ELAPSED_SECS: u64 = 150;

pub(super) const SEARCH_HISTORY_BATCH_SIZE: u16 = 250;

pub(super) const SEARCH_CACHED_INDEX_BATCH_SIZE: usize = 1_000;
