//! Stable FFI declarations expanded into the matrix namespace.
macro_rules! declare_models_api {
    () => {
        // ── FRB data types ───────────────────────────────────────────────────
        #[frb]
        #[derive(Clone, Debug)]
        pub enum ConnectionStatus {
            Connected,
            Connecting,
            Updating,
            Disconnected,
            SessionExpired,
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

        #[frb]
        #[derive(Clone, Debug)]
        pub struct VerificationDevice {
            pub device_id: String,
            pub display_name: String,
            pub is_current: bool,
            pub is_verified: bool,
        }

        /// A device session straight from the homeserver, together with the activity
        /// metadata that the encryption-side device list does not carry.
        #[frb]
        #[derive(Clone, Debug)]
        pub struct AccountDevice {
            pub device_id: String,
            pub display_name: Option<String>,
            pub last_seen_ip: Option<String>,
            /// Milliseconds since the Unix epoch, absent for sessions that never reported activity.
            pub last_seen_ts: Option<i64>,
            pub is_current: bool,
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
            /// Account cross-signing verification; None means it is not known yet.
            pub device_verified: Option<bool>,
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
            /// Legacy cache field, retained for compatibility. SDK 0.19 snapshots
            /// leave this unset; toggling uses the SDK timeline's reaction state.
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
        #[derive(Clone, Debug, PartialEq)]
        pub struct ImageMessageMetadata {
            pub album_root: Option<String>,
            pub blurhash: Option<String>,
            pub spoiler: bool,
            pub spoiler_reason: Option<String>,
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
            /// Matter's common description, shown when viewing any image in a batch.
            pub shared_caption: Option<String>,
            pub image_metadata: Option<ImageMessageMetadata>,
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
            /// Original filename for media attachments.
            pub filename: Option<String>,
            /// Declared file size in bytes for media attachments.
            pub file_size: Option<i32>,
            /// MIME type declared by the media event.
            pub mime_type: Option<String>,
            /// Declared audio/video duration in milliseconds; absent when unknown.
            pub duration_ms: Option<i32>,
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
    };
}
