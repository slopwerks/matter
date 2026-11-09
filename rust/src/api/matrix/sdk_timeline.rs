//! SDK timeline adaptation facade: shared caches, focused histories and conversions.
use super::{
    api_err, image_info_dimensions, media_caption_parts, mentions_parts, sticker_info_dimensions,
    text_message_parts, uint_to_i32, unable_to_decrypt_message, ChatMessage, MessageReader,
    MessageType, PollAnswerInfo, PollAnswerResult, PollInfo, Reaction,
};
use futures_util::{stream, StreamExt};
use matrix_sdk::{
    event_cache::EventsOrigin,
    ruma::{
        api::client::receipt::create_receipt::v3::ReceiptType,
        events::{
            receipt::{ReceiptThread, ReceiptType as EventReceiptType},
            room::message::MessageType as RumaMessageType,
            AnySyncStateEvent, AnySyncTimelineEvent, StateEventContentChange,
        },
    },
    Client, Room,
};
use matrix_sdk_ui::timeline::{
    AnyOtherStateEventContentChange, EventTimelineItem, MemberProfileChange, MembershipChange,
    MsgLikeKind, OtherState, Profile, RoomMembershipChange, Timeline, TimelineBuilder,
    TimelineDetails, TimelineEventFocusThreadMode, TimelineFocus, TimelineItem,
    TimelineItemContent, TimelineReadReceiptTracking,
};
use once_cell::sync::Lazy;
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::Duration,
};
use tokio::sync::Mutex;
static REACTION_LOCKS: Lazy<Mutex<HashMap<String, Arc<Mutex<()>>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static TIMELINES: Lazy<Mutex<HashMap<String, Arc<Timeline>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
#[path = "sdk_live.rs"]
mod sdk_live;
#[cfg(test)]
#[path = "tests/sdk_timeline_tests.rs"]
mod tests;
pub(super) use sdk_live::clear_for_user;
use sdk_live::ensure_initial_window;
pub(super) use sdk_live::get_messages;
pub(super) use sdk_live::get_or_create_timeline;
use sdk_live::loaded_expected_event_count;
use sdk_live::loaded_expected_event_ids;
use sdk_live::pinned_events_ready;

use sdk_live::snapshot;
use sdk_live::timeline_key;
#[path = "sdk_reactions.rs"]
mod sdk_reactions;
pub(super) use sdk_reactions::toggle_reaction;
#[path = "sdk_receipts.rs"]
mod sdk_receipts;
pub(super) use sdk_receipts::clear_marked_unread;
pub(super) use sdk_receipts::clear_marked_unread_if_set;

pub(super) use sdk_receipts::send_read_receipts;
#[path = "sdk_pinned.rs"]
mod sdk_pinned;
#[cfg(test)]
use sdk_pinned::complete_pinned_messages;

pub(super) use sdk_pinned::get_pinned_messages;
pub(super) use sdk_pinned::load_focused_message;
#[cfg(test)]
use sdk_pinned::missing_pinned_event_ids;
#[cfg(test)]
#[cfg(test)]
use sdk_pinned::ordered_pinned_messages;

#[path = "sdk_history.rs"]
mod sdk_history;
#[cfg(test)]
use sdk_history::checked_history_page;

pub(super) use sdk_history::get_messages_around;
pub(super) use sdk_history::get_messages_before;

#[path = "sdk_snapshot.rs"]
mod sdk_snapshot;
pub(super) use sdk_snapshot::convert_snapshot;
#[cfg(test)]
use sdk_snapshot::newest_receipt_position;
#[cfg(test)]
use sdk_snapshot::reader_ids_for_position;
#[cfg(test)]
use sdk_snapshot::record_latest_receipt_position;
#[cfg(test)]
use sdk_snapshot::resolve_receipt_position;
#[path = "sdk_convert.rs"]
mod sdk_convert;
use sdk_convert::timeline_item_to_message;
#[path = "sdk_message.rs"]
mod sdk_message;
pub(super) use sdk_message::base_message;
#[cfg(test)]
use sdk_message::media_duration_ms;
use sdk_message::message_to_chat_message;

use sdk_message::timeline_reactions;
#[path = "sdk_poll.rs"]
mod sdk_poll;
use sdk_poll::poll_message;
#[path = "sdk_state_events.rs"]
mod sdk_state_events;
use sdk_state_events::event_chat_message;
use sdk_state_events::membership_info;
use sdk_state_events::other_state_info;
use sdk_state_events::profile_change_info;
