//! Stable FFI declarations expanded into the matrix namespace.
macro_rules! declare_search_api {
    () => {
        /// A lightweight message-search row. Full timeline events stay on the Rust
        /// side; Flutter loads the surrounding timeline only after a result is tapped.
        #[frb]
        #[derive(Clone, Debug)]
        pub struct MessageSearchResult {
            pub room_id: String,
            pub room_name: String,
            pub room_avatar_url: Option<String>,
            pub event_id: String,
            pub sender_id: String,
            pub sender_name: String,
            pub body: String,
            pub timestamp: String,
            pub is_dm: bool,
            pub is_edited: bool,
        }

        #[frb]
        #[derive(Clone, Debug)]
        pub struct MessageSearchPage {
            pub results: Vec<MessageSearchResult>,
            pub has_more: bool,
            pub terms: Vec<String>,
            pub history_complete: bool,
        }

        #[frb]
        #[derive(Clone, Debug)]
        pub struct MessageSearchBackfill {
            pub loaded_events: u32,
            pub reached_start: bool,
        }

        /// Load and index one older room-history page. The search UI calls this in the
        /// background and refreshes visible local results after every bounded step.
        /// Both scopes index cached events, then continue homeserver pagination. Global
        /// search advances one room per bounded step so no large room monopolizes it.
        #[frb]
        pub async fn backfill_message_search(
            room_id: Option<String>,
        ) -> Result<MessageSearchBackfill, String> {
            search_history::backfill_message_search(room_id).await
        }

        /// Cooperatively stop the active search for this account and scope. A
        /// currently running Tantivy batch finishes, then the superseded request
        /// exits before scanning more batches or rooms.
        #[frb]
        pub async fn cancel_message_search(room_id: Option<String>) {
            search_results::cancel_message_search(room_id).await
        }

        /// Search text already present in the local encrypted index. Room history is
        /// backfilled separately so this call never waits for an unbounded chain of
        /// homeserver pagination requests.
        #[frb]
        pub async fn search_messages(
            query: String,
            room_id: Option<String>,
            offset: u32,
            limit: u32,
            ignored_user_ids: Option<Vec<String>>,
        ) -> Result<MessageSearchPage, String> {
            search_execution::search_messages(query, room_id, offset, limit, ignored_user_ids).await
        }

        /// Load a focused slice of the room timeline around one event.
        #[frb]
        pub async fn get_messages_around(
            room_id: String,
            event_id: String,
            limit: u32,
        ) -> Result<Vec<ChatMessage>, String> {
            history_api::get_messages_around(room_id, event_id, limit).await
        }

        /// Load more messages (paginated) from before a given event.
        #[frb]
        pub async fn get_messages_before(
            room_id: String,
            from_event_id: String,
            limit: u32,
        ) -> Result<Vec<ChatMessage>, String> {
            history_api::get_messages_before(room_id, from_event_id, limit).await
        }

        /// Load the next room-ordered history page, including a cursor for hidden events.
        #[frb]
        pub async fn get_messages_after(
            room_id: String,
            from_event_id: String,
            limit: u32,
        ) -> Result<history::HistoryPage, String> {
            history_api::get_messages_after(room_id, from_event_id, limit).await
        }
    };
}
