//! Stable FFI declarations expanded into the matrix namespace.
macro_rules! declare_sync_crypto_api {
    () => {
        #[frb]
        pub async fn list_own_devices() -> Result<Vec<VerificationDevice>, String> {
            device_verification::list_own_devices().await
        }

        /// List the account's device sessions. This is the homeserver's own list, so it
        /// carries last-seen metadata and reflects what the account really has logged
        /// in; unlike `list_own_devices` it needs connectivity instead of local state.
        #[frb]
        pub async fn list_account_devices() -> Result<Vec<AccountDevice>, String> {
            device_verification::list_account_devices().await
        }

        /// Rename the current device session. An empty name clears the display name.
        #[frb]
        pub async fn rename_account_device(
            device_id: String,
            display_name: String,
        ) -> Result<(), String> {
            device_verification::rename_account_device(device_id, display_name).await
        }

        #[frb]
        pub async fn start_device_verification(device_id: String) -> Result<(), String> {
            device_verification::start_device_verification(device_id).await
        }

        #[frb]
        pub async fn accept_device_verification() -> Result<(), String> {
            device_verification::accept_device_verification().await
        }

        #[frb]
        pub async fn get_device_verification_status(
        ) -> Result<Option<DeviceVerificationStatus>, String> {
            device_verification::get_device_verification_status().await
        }

        #[frb]
        pub async fn confirm_device_verification() -> Result<(), String> {
            device_verification::confirm_device_verification().await
        }

        #[frb]
        pub async fn cancel_device_verification(mismatch: bool) -> Result<(), String> {
            device_verification::cancel_device_verification(mismatch).await
        }

        #[frb]
        pub async fn get_encryption_recovery_info(
            account_user_id: Option<String>,
        ) -> Result<EncryptionRecoveryInfo, String> {
            encryption_recovery::get_encryption_recovery_info(account_user_id).await
        }

        #[frb]
        pub async fn recover_encryption(
            recovery_key_or_passphrase: String,
            account_user_id: Option<String>,
        ) -> Result<(), String> {
            encryption_recovery::recover_encryption(recovery_key_or_passphrase, account_user_id)
                .await
        }

        #[frb]
        pub async fn enable_encryption_recovery(
            passphrase: Option<String>,
            account_user_id: Option<String>,
        ) -> Result<String, String> {
            encryption_recovery::enable_encryption_recovery(passphrase, account_user_id).await
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
            sync_traditional::sync_once().await
        }

        /// Start a Sliding Sync loop for real-time updates.
        /// Falls back to traditional sync_once loop if Sliding Sync is unavailable.
        #[frb]
        pub async fn start_sync() -> Result<(), String> {
            sync_traditional::start_sync().await
        }

        /// Stream real-time sync events from Rust → Dart.
        /// Call this once on app start and listen for updates.
        /// `FullRefreshRequired` means specific events were dropped and all
        /// interested views must refresh.
        #[frb]
        pub fn watch_sync_events(sink: crate::frb_generated::StreamSink<SyncEvent>) {
            sync_events::watch_sync_events(sink)
        }

        // ── Typing notifications ─────────────────────────────────────────────
        /// Ephemeral "who is typing right now" update for a room, pushed to Dart.
        #[frb]
        #[derive(Clone, Debug)]
        pub struct TypingNotification {
            pub room_id: String,
            pub user_ids: Vec<String>,
        }

        /// Stream typing-notification updates (room_id + typing user ids) to Dart.
        /// Mirrors `watch_sync_events`.
        #[frb]
        pub fn watch_typing_notifications(
            sink: crate::frb_generated::StreamSink<TypingNotification>,
        ) {
            typing::watch_typing_notifications(sink)
        }

        /// Begin listening for typing notifications in `room_id`. Any previous
        /// subscription for another room is cancelled first (only one room is
        /// tracked at a time). Call `unsubscribe_typing` when leaving the room.
        #[frb]
        pub async fn subscribe_typing_for_room(
            room_id: String,
            account_user_id: Option<String>,
        ) -> Result<String, String> {
            typing::subscribe_typing_for_room(room_id, account_user_id).await
        }

        /// Stop tracking typing notifications (e.g. when leaving the room screen).
        ///
        /// Verifies the calling route still belongs to the given account, matching
        /// `subscribe_typing_for_room`, so a stale unsubscribe after an account switch
        /// cannot cancel the new account's subscription.
        #[frb]
        pub async fn unsubscribe_typing(
            room_id: String,
            subscription_id: String,
            account_user_id: Option<String>,
        ) -> Result<(), String> {
            typing::unsubscribe_typing(room_id, subscription_id, account_user_id).await
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
            subscriptions::subscribe_room_for_receipts(room_id, account_user_id).await
        }

        /// Unsubscribe the given room from Sliding Sync (e.g. when leaving the room
        /// screen). Receipts for it will still arrive when the room has timeline
        /// activity, but not on every roundtrip. Uses `unsubscribe_to_rooms` (not a
        /// no-op re-subscribe) so the subscription is actually removed, keeping sync
        /// cost bounded as the user visits different rooms.
        ///
        /// The room is removed only after its last mounted owner unsubscribes. The
        /// update runs under the same lock as subscribe, so overlapping routes cannot
        /// cancel each other's subscription. The account check mirrors
        /// `subscribe_room_for_receipts` to prevent a stale unsubscribe from a
        /// pre-switch route from removing the new account's subscription.
        #[frb]
        pub async fn unsubscribe_room_for_receipts(
            room_id: String,
            subscription_id: String,
            account_user_id: Option<String>,
        ) -> Result<(), String> {
            subscriptions::unsubscribe_room_for_receipts(room_id, subscription_id, account_user_id)
                .await
        }

        /// Check if background sync is alive.
        #[frb]
        pub async fn is_connected() -> bool {
            subscriptions::is_connected().await
        }

        // ── Chat functions ───────────────────────────────────────────────────
        #[frb(sync)]
        pub fn get_connection_status() -> ConnectionStatus {
            subscriptions::get_connection_status()
        }

        #[frb]
        pub async fn init_client() -> Result<(), String> {
            subscriptions::init_client().await
        }
    };
}
