//! Stable FFI declarations expanded into the matrix namespace.
macro_rules! declare_lifecycle_api {
    () => {
        // ── App-wide log system ─────────────────────────────────────────────
        /// A single log entry visible to the user.
        #[frb]
        #[derive(Clone, Debug)]
        pub struct AppLogEntry {
            /// Milliseconds since Unix epoch
            pub timestamp: i64,
            /// info / warn / error / debug
            pub level: String,
            /// What subsystem: sync, auth, rooms, media, etc.
            pub tag: String,
            /// The actual message
            pub message: String,
        }

        /// Initialize persisted logging before startup session discovery begins.
        #[frb(sync)]
        pub fn initialize_log_store(data_dir: String) {
            logging::initialize_log_store(data_dir)
        }

        /// Stream app log entries from Rust → Dart (live).
        #[frb]
        pub fn watch_app_logs(sink: crate::frb_generated::StreamSink<AppLogEntry>) {
            logging::watch_app_logs(sink)
        }

        /// Retrieve all buffered logs (up to 5,000 entries).
        /// Call this once after connecting the stream to show historical logs.
        #[frb(sync)]
        pub fn get_recent_logs() -> Vec<AppLogEntry> {
            logging::get_recent_logs()
        }

        /// Clear the buffered diagnostic logs.
        #[frb(sync)]
        pub fn clear_app_logs() {
            logging::clear_app_logs()
        }

        /// Write a log entry from the Dart side into the same app-wide log system
        /// (ring buffer, persisted file, live stream) used by Rust. Unknown levels
        /// fall back to "info".
        #[frb(sync)]
        pub fn log_app_message(level: String, tag: String, message: String) {
            logging::log_app_message(level, tag, message)
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
            logging::read_log_files().await
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
            /// A message was redacted, including events outside the live window.
            MessageRedacted { room_id: String, event_id: String },
            /// A room's pinned-event state changed.
            PinnedMessagesChanged { room_id: String },
            /// A room's membership state changed.
            RoomMembersChanged { room_id: String },
            /// The account's ignored-user list changed.
            IgnoredUsersChanged,
        }

        #[frb]
        #[derive(Clone, Debug)]
        pub struct SessionTokenUpdate {
            pub user_id: String,
            pub access_token: String,
            pub refresh_token: Option<String>,
        }

        #[frb]
        pub fn watch_session_token_updates(
            sink: crate::frb_generated::StreamSink<SessionTokenUpdate>,
        ) {
            session_tokens::watch_session_token_updates(sink)
        }

        /// Retry SDK-store cleanup for an account whose persisted removal transaction
        /// was interrupted. Called during startup before any sessions are restored.
        #[frb]
        pub async fn cleanup_removed_account_store(
            user_id: String,
            data_dir: String,
        ) -> Result<(), String> {
            account_store::cleanup_removed_account_store(user_id, data_dir).await
        }
    };
}
