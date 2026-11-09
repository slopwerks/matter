//! Stable FFI declarations expanded into the matrix namespace.
macro_rules! declare_media_api {
    () => {
        /// Convert an mxc:// URI to an avatar-sized thumbnail HTTP URL.
        /// Format: `{homeserver}/_matrix/client/v1/media/thumbnail/{server}/{mediaId}?width=96&height=96&method=scale`
        #[frb]
        pub async fn mxc_to_http_avatar(mxc_url: String) -> Option<String> {
            media_download::mxc_to_http_avatar(mxc_url).await
        }

        /// Convert an mxc:// URI to a scaled thumbnail HTTP URL for message media.
        #[frb]
        pub async fn mxc_to_http_thumbnail(
            mxc_url: String,
            width: u32,
            height: u32,
        ) -> Option<String> {
            media_download::mxc_to_http_thumbnail(mxc_url, width, height).await
        }

        /// Convert an mxc:// URI to a thumbnail HTTP URL for chat bubbles.
        /// Format: `{homeserver}/_matrix/client/v1/media/thumbnail/{server}/{mediaId}?width=800&height=600&method=scale`
        #[frb]
        pub async fn mxc_to_http(mxc_url: String) -> Option<String> {
            media_download::mxc_to_http(mxc_url).await
        }

        /// Convert an mxc:// URI to a full-quality download HTTP URL.
        /// Used for "原图" (original quality) preview.
        #[frb]
        pub async fn mxc_to_http_full(mxc_url: String) -> Option<String> {
            media_download::mxc_to_http_full(mxc_url).await
        }

        #[frb]
        pub async fn download_media_bytes(mxc_url: String) -> Option<Vec<u8>> {
            media_download::download_media_bytes(mxc_url).await
        }

        /// Download a Matrix media source, decrypting and integrity-checking encrypted
        /// attachments through the SDK when necessary. The response is read in bounded
        /// chunks so automatic media previews cannot allocate unbounded memory.
        #[frb]
        pub async fn download_media_source_bytes(
            media_source_json: String,
            max_size_bytes: i32,
        ) -> Result<Vec<u8>, String> {
            media_download::download_media_source_bytes(media_source_json, max_size_bytes).await
        }

        /// Get the current access token for authenticated media requests.
        #[frb]
        pub async fn get_access_token() -> Option<String> {
            session_restore::get_access_token().await
        }

        #[frb]
        pub async fn get_refresh_token() -> Option<String> {
            session_restore::get_refresh_token().await
        }

        #[frb]
        pub async fn is_room_encrypted(room_id: String) -> Result<bool, String> {
            room_list::is_room_encrypted(room_id).await
        }

        #[frb]
        pub async fn get_chat_rooms(
            ignored_user_ids: Option<Vec<String>>,
            authoritative: bool,
        ) -> Result<Vec<ChatRoom>, String> {
            room_list::get_chat_rooms(ignored_user_ids, authoritative).await
        }

        /// Get messages for a room (must sync first).
        #[frb]
        pub async fn get_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
            message_send::get_messages(room_id).await
        }

        #[frb]
        pub async fn get_sticker_packs(room_id: String) -> Result<Vec<StickerPack>, String> {
            message_send::get_sticker_packs(room_id).await
        }

        #[frb]
        pub async fn send_message(
            account_user_id: String,
            room_id: String,
            message: FormattedMessageInput,
        ) -> Result<String, String> {
            message_send::send_message(account_user_id, room_id, message).await
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
            message_forward::forward_message(source_room_id, target_room_id, event_id, text).await
        }

        /// Read the caption belonging to an image album without downloading its media.
        #[frb]
        pub async fn get_image_album_caption(
            account_user_id: String,
            room_id: String,
            root_event_id: String,
        ) -> Result<Option<String>, String> {
            media_send::get_image_album_caption(account_user_id, room_id, root_event_id).await
        }

        /// Send an image message to a room.
        /// `image_data` is the raw bytes of the image file.
        /// `filename` is the original file name (e.g. "photo.jpg").
        #[frb]
        #[allow(clippy::too_many_arguments)]
        pub async fn send_image_message(
            account_user_id: String,
            room_id: String,
            image_data: Vec<u8>,
            filename: String,
            mime_type: Option<String>,
            width: Option<i32>,
            height: Option<i32>,
            caption: Option<String>,
            shared_caption: Option<String>,
            metadata: Option<ImageMessageMetadata>,
        ) -> Result<String, String> {
            media_send::send_image_message(
                account_user_id,
                room_id,
                image_data,
                filename,
                mime_type,
                width,
                height,
                caption,
                shared_caption,
                metadata,
            )
            .await
        }

        /// Send an arbitrary file (document) attachment to a room.
        #[frb]
        pub async fn send_file_message(
            account_user_id: String,
            room_id: String,
            file_data: Vec<u8>,
            filename: String,
            mime_type: Option<String>,
            size: Option<i32>,
        ) -> Result<(), String> {
            media_send::send_file_message(
                account_user_id,
                room_id,
                file_data,
                filename,
                mime_type,
                size,
            )
            .await
        }

        /// Send a video attachment to a room.
        #[frb]
        #[allow(clippy::too_many_arguments)]
        pub async fn send_video_message(
            account_user_id: String,
            room_id: String,
            video_data: Vec<u8>,
            filename: String,
            mime_type: Option<String>,
            width: Option<i32>,
            height: Option<i32>,
            duration_ms: Option<i32>,
            size: Option<i32>,
        ) -> Result<(), String> {
            media_send::send_video_message(
                account_user_id,
                room_id,
                video_data,
                filename,
                mime_type,
                width,
                height,
                duration_ms,
                size,
            )
            .await
        }

        /// Share a geographic location as legacy `m.room.message` / `m.location`.
        ///
        /// The extensible top-level `m.location` event is not parsed by the current
        /// `matrix-sdk-ui` version. `geo_uri` follows RFC 5870, for example
        /// `geo:37.786971,-122.399677`.
        #[frb]
        pub async fn send_location(
            account_user_id: String,
            room_id: String,
            body: String,
            geo_uri: String,
        ) -> Result<(), String> {
            location::send_location(account_user_id, room_id, body, geo_uri).await
        }

        /// Start a poll using the unstable `org.matrix.msc3381.poll.start` event.
        ///
        /// This is the poll type surfaced by the current `matrix-sdk-ui` version; its
        /// stable counterpart is not parsed there yet.
        #[frb]
        pub async fn send_poll(
            account_user_id: String,
            room_id: String,
            question: String,
            answers: Vec<String>,
            disclosed: bool,
            max_selections: i32,
        ) -> Result<(), String> {
            polls::send_poll(
                account_user_id,
                room_id,
                question,
                answers,
                disclosed,
                max_selections,
            )
            .await
        }

        /// Submit a vote on a poll. Replaces the current user's previous response on
        /// the same poll start event.
        #[frb]
        pub async fn send_poll_response(
            room_id: String,
            poll_start_event_id: String,
            answer_ids: Vec<String>,
        ) -> Result<(), String> {
            polls::send_poll_response(room_id, poll_start_event_id, answer_ids).await
        }

        /// Close a poll so no further votes are accepted.
        #[frb]
        pub async fn end_poll(room_id: String, poll_start_event_id: String) -> Result<(), String> {
            polls::end_poll(room_id, poll_start_event_id).await
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
            stickers::send_sticker(room_id, image_url, body, mime_type, width, height).await
        }
    };
}
