//! Stable FFI declarations expanded into the matrix namespace.
macro_rules! declare_auth_api {
    () => {
        // ── Auth functions ───────────────────────────────────────────────────
        /// Create a Matrix client for the given homeserver URL.
        /// Must be called before any registration / login attempt.
        /// The client is stored as "pending" until a login succeeds,
        /// after which it is automatically migrated to a per-user store.
        ///
        /// `use_in_memory_search_index` bypasses the search-index-key requirement and
        /// keeps the pending client's index in memory. The per-user store created by
        /// `finalize_pending` still uses the encrypted index and the supplied key.
        #[frb]
        pub async fn create_client(
            homeserver_url: String,
            data_dir: String,
            search_index_key: String,
            use_in_memory_search_index: bool,
        ) -> Result<(), String> {
            auth_registration::create_client(
                homeserver_url,
                data_dir,
                search_index_key,
                use_in_memory_search_index,
            )
            .await
        }

        /// Release only the unfinished login; existing account sessions stay intact.
        #[frb]
        pub async fn cancel_pending_login() -> Result<(), String> {
            auth_registration::cancel_pending_login().await
        }

        /// Step 1 of registration: discover UIAA flows.
        #[frb]
        pub async fn register_get_uiaa_session(
            username: String,
            password: String,
        ) -> Result<AuthResult, String> {
            auth_registration::register_get_uiaa_session(username, password).await
        }

        /// Step 2 of registration: complete with token + session.
        #[frb]
        pub async fn register_complete_uiaa(
            username: String,
            password: String,
            registration_token: String,
            session: String,
        ) -> Result<AuthResult, String> {
            auth_registration::register_complete_uiaa(
                username,
                password,
                registration_token,
                session,
            )
            .await
        }

        /// Login with username and password.
        #[frb]
        pub async fn login_with_password(
            username: String,
            password: String,
        ) -> Result<AuthResult, String> {
            auth_login::login_with_password(username, password).await
        }

        /// Login with an existing access token (restore session).
        #[frb]
        pub async fn login_with_token(
            access_token: String,
            user_id: String,
            device_id: String,
            refresh_token: Option<String>,
        ) -> Result<AuthResult, String> {
            auth_login::login_with_token(access_token, user_id, device_id, refresh_token).await
        }

        /// Check if the client is currently logged in.
        #[frb]
        pub async fn is_logged_in() -> bool {
            auth_login::is_logged_in().await
        }

        /// Get the current user ID if logged in.
        #[frb]
        pub async fn get_current_user_id() -> Option<String> {
            auth_login::get_current_user_id().await
        }

        /// Get the currently active user ID (the account being used).
        #[frb]
        pub async fn get_active_user_id() -> Option<String> {
            auth_login::get_active_user_id().await
        }

        /// Fetch the current user's profile (display name + avatar mxc URL) from the
        /// homeserver. Used to populate the profile editor with current values.
        #[frb]
        pub async fn get_profile() -> Result<UserProfile, String> {
            profile::get_profile().await
        }

        /// Update the current user's display name. Empty string clears it.
        #[frb]
        pub async fn set_display_name(name: String) -> Result<(), String> {
            profile::set_display_name(name).await
        }

        /// Update the current user's avatar. `mxc` is an `mxc://` URI obtained from
        /// `upload_avatar`. Pass an empty string to remove the avatar.
        #[frb]
        pub async fn set_avatar_url(mxc: String) -> Result<(), String> {
            profile::set_avatar_url(mxc).await
        }

        /// Upload raw image bytes as avatar media and return the resulting `mxc://`
        /// URI. Call `set_avatar_url` afterwards to actually apply it. Split into two
        /// steps so the UI can show progress if needed and a failed upload won't leave
        /// a half-set profile.
        #[frb]
        pub async fn upload_avatar(content_type: String, data: Vec<u8>) -> Result<String, String> {
            profile::upload_avatar(content_type, data).await
        }

        /// List all logged-in accounts.
        #[frb]
        pub async fn list_accounts() -> Vec<AccountInfo> {
            session_relogin::list_accounts().await
        }

        /// Switch the active account. Returns true if the account exists and was activated.
        #[frb]
        pub async fn switch_account(user_id: String) -> bool {
            session_relogin::switch_account(user_id).await
        }

        /// Release an expired active client so the same account can authenticate again.
        /// Returns whether a soft logout allows reuse of the original device and store.
        #[frb]
        pub async fn prepare_session_relogin(account_user_id: String) -> Result<bool, String> {
            session_relogin::prepare_session_relogin(account_user_id).await
        }

        /// Renew a soft-logged-out session using its original device and crypto store.
        #[frb]
        pub async fn resume_session_with_password(
            account_user_id: String,
            password: String,
            search_index_key: String,
            reset_search_index: bool,
            use_in_memory_search_index: bool,
        ) -> Result<AuthResult, String> {
            session_relogin::resume_session_with_password(
                account_user_id,
                password,
                search_index_key,
                reset_search_index,
                use_in_memory_search_index,
            )
            .await
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
            account_removal::logout().await
        }

        /// Remove a specific account by user_id (logout + delete data).
        #[frb]
        pub async fn remove_account(user_id: String) -> Result<AccountRemovalResult, String> {
            account_removal::remove_account(user_id).await
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
            session_restore::get_session().await
        }

        /// Read one account's access/refresh token pair from the same SDK snapshot.
        /// Account-scoped so late notifications cannot persist another account's tokens.
        #[frb]
        pub async fn get_session_tokens(account_user_id: String) -> Option<SessionTokenUpdate> {
            session_restore::get_session_tokens(account_user_id).await
        }

        /// Restore a previously saved session (used on app startup).
        /// Uses a per-user store directory so multiple accounts coexist.
        ///
        /// `use_in_memory_search_index` keeps the search index in memory instead of
        /// the encrypted on-disk store. When true, `search_index_key` may be empty and
        /// `reset_search_index` is ignored.
        #[frb]
        pub async fn restore_session(
            session: StoredSession,
            data_dir: String,
            search_index_key: String,
            reset_search_index: bool,
            use_in_memory_search_index: bool,
        ) -> Result<(), String> {
            session_restore::restore_session(
                session,
                data_dir,
                search_index_key,
                reset_search_index,
                use_in_memory_search_index,
            )
            .await
        }
    };
}
