//! Stable FFI declarations expanded into the matrix namespace.
macro_rules! declare_room_state_api {
    () => {
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
            ignored_users::get_ignored_users().await
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
            ignored_users::set_user_ignored(account_user_id, user_id, ignored).await
        }

        #[frb]
        pub async fn get_room_knock_requests(room_id: String) -> Result<Vec<KnockRequest>, String> {
            room_knocks::get_room_knock_requests(room_id).await
        }

        /// Accept a knock request by inviting the requester to the room.
        #[frb]
        pub async fn approve_room_knock(
            account_user_id: String,
            room_id: String,
            user_id: String,
        ) -> Result<(), String> {
            room_knocks::approve_room_knock(account_user_id, room_id, user_id).await
        }

        /// Decline a knock request by removing the requester from the room.
        #[frb]
        pub async fn reject_room_knock(
            account_user_id: String,
            room_id: String,
            user_id: String,
        ) -> Result<(), String> {
            room_knocks::reject_room_knock(account_user_id, room_id, user_id).await
        }

        #[frb]
        pub async fn get_spaces() -> Result<Vec<Space>, String> {
            spaces::get_spaces().await
        }

        #[frb]
        pub async fn get_space_details(space_id: String) -> Result<SpaceDetails, String> {
            spaces::get_space_details(space_id).await
        }

        #[frb]
        pub async fn get_space_children(
            space_id: String,
            ignored_user_ids: Option<Vec<String>>,
            authoritative: bool,
        ) -> Result<Vec<ChatRoom>, String> {
            spaces::get_space_children(space_id, ignored_user_ids, authoritative).await
        }

        #[frb]
        pub async fn update_space_details(
            account_user_id: String,
            space_id: String,
            name: String,
            topic: Option<String>,
        ) -> Result<(), String> {
            spaces::update_space_details(account_user_id, space_id, name, topic).await
        }

        /// Add a room to a space, and advertise the reciprocal parent relation.
        #[frb]
        pub async fn add_room_to_space(
            account_user_id: String,
            space_id: String,
            room_id: String,
        ) -> Result<(), String> {
            spaces::add_room_to_space(account_user_id, space_id, room_id).await
        }

        #[frb]
        pub async fn remove_room_from_space(
            account_user_id: String,
            space_id: String,
            room_id: String,
        ) -> Result<(), String> {
            spaces::remove_room_from_space(account_user_id, space_id, room_id).await
        }

        #[frb]
        pub async fn leave_space(account_user_id: String, space_id: String) -> Result<(), String> {
            spaces::leave_space(account_user_id, space_id).await
        }

        #[frb]
        pub async fn get_ungrouped_rooms(
            ignored_user_ids: Option<Vec<String>>,
            authoritative: bool,
        ) -> Result<Vec<ChatRoom>, String> {
            spaces::get_ungrouped_rooms(ignored_user_ids, authoritative).await
        }

        #[frb]
        pub async fn get_contacts() -> Result<Vec<Contact>, String> {
            contacts::get_contacts().await
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
            message_actions::send_reply(
                account_user_id,
                room_id,
                message,
                reply_to_event_id,
                reply_to_user_id,
            )
            .await
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
            message_actions::edit_message(
                account_user_id,
                room_id,
                event_id,
                message,
                previous_mentioned_user_ids,
                previous_mentions_room,
            )
            .await
        }

        /// Toggle the current user's emoji reaction and return the updated message.
        #[frb]
        pub async fn toggle_reaction(
            account_user_id: String,
            room_id: String,
            event_id: String,
            key: String,
        ) -> Result<ChatMessage, String> {
            message_actions::toggle_reaction(account_user_id, room_id, event_id, key).await
        }

        /// Redact (delete) a message from a room.
        #[frb]
        pub async fn redact_message(
            account_user_id: String,
            room_id: String,
            event_id: String,
            reason: Option<String>,
        ) -> Result<(), String> {
            message_actions::redact_message(account_user_id, room_id, event_id, reason).await
        }

        /// Send a typing notice to a room.
        #[frb]
        pub async fn send_typing_notice(
            account_user_id: String,
            room_id: String,
            typing: bool,
        ) -> Result<(), String> {
            message_actions::send_typing_notice(account_user_id, room_id, typing).await
        }

        /// Get members of a room.
        #[frb]
        pub async fn get_room_members(room_id: String) -> Result<Vec<Contact>, String> {
            contacts::get_room_members(room_id).await
        }

        /// Get the avatar URL for a room.
        #[frb]
        pub async fn get_room_avatar_url(room_id: String) -> Option<String> {
            contacts::get_room_avatar_url(room_id).await
        }

        /// Search rooms by name.
        #[frb]
        pub async fn search_rooms(
            query: String,
            ignored_user_ids: Option<Vec<String>>,
            authoritative: bool,
        ) -> Result<Vec<ChatRoom>, String> {
            contacts::search_rooms(query, ignored_user_ids, authoritative).await
        }
    };
}
