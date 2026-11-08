//! Stable FFI declarations expanded into the matrix namespace.
macro_rules! declare_room_operations_api {
    () => {
        /// Create a new direct chat room with a user.
        #[frb]
        pub async fn create_dm(account_user_id: String, user_id: String) -> Result<String, String> {
            room_create::create_dm(account_user_id, user_id).await
        }

        /// Create a group room with a name and optional topic.
        #[frb]
        pub async fn create_group_room(
            account_user_id: String,
            name: String,
            topic: Option<String>,
        ) -> Result<String, String> {
            room_create::create_group_room(account_user_id, name, topic).await
        }

        /// Create a space room with a name and optional topic.
        #[frb]
        pub async fn create_space(
            account_user_id: String,
            name: String,
            topic: Option<String>,
        ) -> Result<String, String> {
            spaces::create_space(account_user_id, name, topic).await
        }

        /// Join a room or space by room ID or alias.
        #[frb]
        pub async fn join_room(
            account_user_id: String,
            identifier: String,
        ) -> Result<String, String> {
            room_membership::join_room(account_user_id, identifier).await
        }

        #[frb]
        pub async fn accept_room_invite(
            account_user_id: String,
            room_id: String,
        ) -> Result<(), String> {
            room_membership::accept_room_invite(account_user_id, room_id).await
        }

        #[frb]
        pub async fn reject_room_invite(
            account_user_id: String,
            room_id: String,
        ) -> Result<(), String> {
            room_membership::reject_room_invite(account_user_id, room_id).await
        }

        #[frb]
        pub async fn withdraw_room_knock(
            account_user_id: String,
            room_id: String,
        ) -> Result<(), String> {
            room_membership::withdraw_room_knock(account_user_id, room_id).await
        }

        /// Leave a joined non-space room.
        #[frb]
        pub async fn leave_room(account_user_id: String, room_id: String) -> Result<(), String> {
            room_membership::leave_room(account_user_id, room_id).await
        }

        /// Return the editable state of a joined non-space room.
        #[frb]
        pub async fn get_room_details(room_id: String) -> Result<RoomDetails, String> {
            room_membership::get_room_details(room_id).await
        }

        /// Invite a Matrix user to a joined non-space room.
        #[frb]
        pub async fn invite_user_to_room(
            account_user_id: String,
            room_id: String,
            user_id: String,
        ) -> Result<(), String> {
            room_membership::invite_user_to_room(account_user_id, room_id, user_id).await
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
            room_membership::update_room_details(
                account_user_id,
                room_id,
                name,
                update_name,
                update_topic,
                topic,
            )
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
            room_membership::upload_room_avatar(account_user_id, room_id, content_type, data).await
        }

        /// Return whether a room has an explicit mute push rule.
        #[frb]
        pub async fn is_room_muted(room_id: String) -> Result<bool, String> {
            room_notifications::is_room_muted(room_id).await
        }

        /// Create or remove an explicit mute push rule for a room.
        #[frb]
        pub async fn set_room_muted(
            account_user_id: String,
            room_id: String,
            muted: bool,
        ) -> Result<(), String> {
            room_notifications::set_room_muted(account_user_id, room_id, muted).await
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
            room_pins::get_pinned_event_ids(account_user_id, room_id).await
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
            room_pins::set_pinned_message(account_user_id, room_id, event_id, pinned).await
        }

        /// Load every accessible pinned message in display order.
        #[frb]
        pub async fn get_pinned_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
            room_pins::get_pinned_messages(room_id).await
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
            room_reads::mark_room_as_read(account_user_id, room_id, explicit).await
        }

        /// Persist an explicit unread marker for a room in room account data.
        #[frb]
        pub async fn mark_room_unread(
            account_user_id: String,
            room_id: String,
        ) -> Result<(), String> {
            room_reads::mark_room_unread(account_user_id, room_id).await
        }
    };
}
