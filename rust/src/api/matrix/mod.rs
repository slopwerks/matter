//! Matrix FFI facade. Public signatures stay in this namespace.
//! Private domain modules share the single runtime owner through explicit imports.

use crate::http_client::matrix_client_builder;
use crate::network_diagnostics::RequestDiagnostics;
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
use matrix_sdk_base::linked_chunk::{ChunkContent, ChunkIdentifier, ChunkMetadata, LinkedChunkId};
use once_cell::sync::Lazy;
use sha2::{Digest, Sha256};
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
#[cfg(test)]
#[path = "tests/account_bound_attachment_tests.rs"]
mod account_bound_attachment_tests;
#[cfg(test)]
#[path = "tests/account_device_tests.rs"]
mod account_device_tests;
#[cfg(test)]
#[path = "tests/account_store_cleanup_tests.rs"]
mod account_store_cleanup_tests;
#[cfg(test)]
#[path = "tests/attachment_message_tests.rs"]
mod attachment_message_tests;
#[cfg(test)]
#[path = "tests/auth_error_tests.rs"]
mod auth_error_tests;
pub mod desktop_notifications;
#[cfg(test)]
#[path = "tests/device_name_tests.rs"]
mod device_name_tests;
#[cfg(test)]
#[path = "tests/encryption_recovery_tests.rs"]
mod encryption_recovery_tests;
#[cfg(test)]
#[path = "tests/formatted_message_tests.rs"]
mod formatted_message_tests;
pub mod history;
mod image_caption;
#[cfg(test)]
#[path = "tests/knock_request_tests.rs"]
mod knock_request_tests;
#[cfg(test)]
#[path = "tests/live_room_subscription_tests.rs"]
mod live_room_subscription_tests;
mod logging;
#[cfg(test)]
#[path = "tests/media_download_tests.rs"]
mod media_download_tests;
#[cfg(test)]
#[path = "tests/message_search_tests.rs"]
mod message_search_tests;
#[cfg(test)]
#[path = "tests/mutation_queue_tests.rs"]
mod mutation_queue_tests;
pub mod notifications;
pub mod push;
#[cfg(test)]
#[path = "tests/remote_logout_retry_tests.rs"]
mod remote_logout_retry_tests;
#[cfg(test)]
#[path = "tests/room_subscription_tests.rs"]
mod room_subscription_tests;
mod sdk_timeline;
mod search_hydration;
mod search_metrics;
#[cfg(test)]
#[path = "tests/session_expiry_tests.rs"]
mod session_expiry_tests;
#[cfg(test)]
#[path = "tests/space_child_tests.rs"]
mod space_child_tests;
mod sticker_packs;
pub mod storage;
#[cfg(test)]
#[path = "tests/sync_event_tests.rs"]
mod sync_event_tests;
#[cfg(test)]
#[path = "tests/sync_lifecycle_tests.rs"]
mod sync_lifecycle_tests;
#[cfg(test)]
#[path = "tests/typing_subscription_tests.rs"]
mod typing_subscription_tests;
pub mod unread;
use logging::api_err;
use logging::app_log;
use logging::init_log_store;
mod connection;
use connection::advance_sync_generation;
#[cfg(test)]
use connection::classify_session_expiry;
#[cfg(test)]
use connection::is_session_expired_error;
use connection::notify_sync_event_for_generation;
use connection::report_session_error;
use connection::report_session_error_for_generation;
use connection::reset_connection_status;
#[cfg(test)]
use connection::set_connection_status;
use connection::set_connection_status_for_generation;
mod ignored_overrides;
use ignored_overrides::effective_is_user_ignored;
use ignored_overrides::ignored_user_override_key;
use ignored_overrides::merge_current_account_ignored_user_overrides;
#[cfg(test)]
use ignored_overrides::merge_ignored_user_overrides;
use ignored_overrides::reconcile_ignored_user_overrides;
#[cfg(test)]
use ignored_overrides::reconcile_ignored_user_overrides_inner;
#[cfg(test)]
use ignored_overrides::resolve_ignored_user;
use ignored_overrides::set_ignored_user_override;
mod runtime_cleanup;
use runtime_cleanup::bounded_request_config;
use runtime_cleanup::clear_account_runtime_state;
use runtime_cleanup::notification_settings_for;
mod sync_events;
use sync_events::failures_after_stream_end;
#[cfg(test)]
use sync_events::lagged_sync_event;
use sync_events::notify_sync_event;
use sync_events::sync_retry_delay;
use sync_events::sync_retry_status;
mod mutation;
#[cfg(test)]
use mutation::enqueue_mutation;
use mutation::run_bounded;
use mutation::run_bounded_mutation;
use mutation::run_bounded_mutation_undroppable;
mod read_overrides;
use read_overrides::effective_marked_unread;
use read_overrides::marked_unread_override_key;
use read_overrides::reconcile_marked_unread_override;
#[cfg(test)]
use read_overrides::resolve_marked_unread;
use read_overrides::set_marked_unread_override;
use read_overrides::synced_marked_unread;
mod session_tokens;
use session_tokens::install_session_token_callback;
mod remote_logout;
use remote_logout::clear_timeline_cache_for;
#[cfg(test)]
use remote_logout::remote_logout_retry_settles;
use remote_logout::retry_pending_remote_logout;
mod subscriptions;
use subscriptions::desired_room_ids;
use subscriptions::lock_subscription_state;
use subscriptions::receipt_extension_for_subscribed_rooms;
use subscriptions::set_subscription_user;
#[cfg(test)]
use subscriptions::subscription_user_matches;
mod sync_lifecycle;
use sync_lifecycle::clear_published_sync;
use sync_lifecycle::interruptible_retry_sleep;
use sync_lifecycle::stop_sync_task;
use sync_lifecycle::sync_generation_is_active;
mod event_handlers;
use event_handlers::active_generation_for_client;
use event_handlers::install_live_update_event_handlers;
use event_handlers::install_verification_event_handler;
use event_handlers::notify_sync_event_for_client;
mod encryption_events;
use encryption_events::encryption_settings;
use encryption_events::install_room_key_event_handler;
use encryption_events::wait_for_e2ee_initialization;
mod account_store;
use account_store::build_sdk_data_dir;
use account_store::delete_account_sdk_store;
use account_store::prepare_encrypted_search_index;
use account_store::remove_dir_all_if_exists;
use account_store::remove_legacy_plaintext_search_index;
use account_store::rename_with_retry;
mod client_lease;
pub(super) use client_lease::get_client;
use client_lease::get_pending_client;
mod finalize_login;
use finalize_login::finalize_pending;
mod room_preview;
use room_preview::image_info_dimensions;
use room_preview::room_avatar_event_id;
use room_preview::room_display_name;
use room_preview::room_message_preview;
use room_preview::room_name_event_id;
use room_preview::room_to_chat_room;
use room_preview::room_topic_event_id;
use room_preview::sticker_info_dimensions;
use room_preview::uint_to_i32;
#[cfg(test)]
use room_preview::unstable_poll_preview;
mod auth_errors;
use auth_errors::friendly_auth_error;
use auth_errors::get_room_by_id;
use auth_errors::truncate_utf8;
use auth_errors::try_extract_uiaa;
use auth_errors::try_parse_uiaa_from_string;
mod auth_registration;
#[cfg(test)]
use auth_registration::device_name_for_platform;
use auth_registration::get_initial_device_name;
mod account_removal;
mod auth_login;
mod device_verification;
mod profile;
mod session_relogin;
mod session_restore;
use device_verification::clear_verification_session;
#[cfg(test)]
use device_verification::sort_account_devices;
mod encryption_recovery;
#[cfg(test)]
use encryption_recovery::encryption_recovery_info;
mod sync_traditional;
use sync_traditional::start_sync_internal;
mod sync_sliding;
use sync_sliding::try_start_sliding_sync;
mod typing;
use typing::live_room_subscription;
#[cfg(test)]
use typing::take_typing_task_for_owner;
mod media_download;
#[cfg(test)]
use media_download::append_media_chunk;
#[cfg(test)]
use media_download::ensure_media_content_length;
pub(super) use media_download::media_client_identity;
#[cfg(test)]
use media_download::media_download_limit;
pub(super) use media_download::media_download_url;
pub(super) use media_download::reacquire_media_client;
mod message_content;
mod room_list;
use message_content::extract_edit_content;
use message_content::media_caption_parts;
use message_content::mentions_parts;
use message_content::strip_reply_fallback;
use message_content::text_message_parts;
use message_content::unable_to_decrypt_message;
mod message_send;
use message_send::build_mentions;
use message_send::build_text_content;
use message_send::poll_start_for_forward;
mod media_upload;
mod message_forward;
use media_upload::file_message_content;
use media_upload::image_message_content;
use media_upload::image_mime_type;
use media_upload::parse_supplied_mime_type;
use media_upload::upload_media_source;
use media_upload::video_message_content;
use media_upload::video_mime_type;
mod location;
mod media_send;
#[cfg(test)]
use location::location_message_content;
mod polls;
#[cfg(test)]
use polls::poll_start_content;
#[cfg(test)]
use polls::validate_poll_answer_ids;
mod room_create;
mod spaces;
mod stickers;
#[cfg(test)]
use spaces::space_child_room_id;
mod room_membership;
use room_membership::ensure_account_matches;
use room_membership::is_dm_by_members;
use room_membership::joined_non_space_room;
mod ignored_users;
mod room_knocks;
mod room_notifications;
mod room_pins;
mod room_reads;
#[cfg(test)]
use room_knocks::knock_member_events_request;
mod contacts;
mod message_actions;
mod search_query;
use search_query::begin_message_search;
use search_query::message_matches_search_terms;
use search_query::message_search_cancelled;
use search_query::message_search_index_query;
use search_query::message_search_is_current;
use search_query::message_search_terms;
use search_query::ordered_event_cache_chunk_ids;
mod search_cached_backfill;
use search_cached_backfill::backfill_cached_search_index_page;
use search_cached_backfill::cached_search_backfill_complete;
use search_cached_backfill::index_search_events;
mod search_history;
#[cfg(test)]
use search_history::backfill_message_search_with_client;
use search_history::message_search_room_key;
use search_history::searchable_rooms;
mod search_results;
use search_results::insert_latest_search_result;
use search_results::paginate_message_search_results;
use search_results::search_result_from_event;
mod search_execution;
#[cfg(test)]
use search_execution::search_messages_with_client;
mod history_api;
#[macro_use]
mod ffi_lifecycle;
declare_lifecycle_api!();
#[macro_use]
mod ffi_models;
declare_models_api!();
#[macro_use]
mod ffi_auth;
declare_auth_api!();
#[macro_use]
mod ffi_sync_crypto;
declare_sync_crypto_api!();
#[macro_use]
mod ffi_media;
declare_media_api!();
#[macro_use]
mod ffi_room_operations;
declare_room_operations_api!();
#[macro_use]
mod ffi_room_state;
declare_room_state_api!();
#[macro_use]
mod ffi_search;
declare_search_api!();
mod runtime;
use runtime::*;
pub(super) use runtime::{ClientLease, MediaClientIdentity};

#[cfg(test)]
mod search_index_tests;
#[cfg(test)]
mod search_performance_tests;
