use flutter_rust_bridge::frb;
use matrix_sdk::ruma::{
    api::client::push::{
        delete_pushrule, get_pushrules_all, set_pushrule, set_pushrule_actions,
        set_pushrule_enabled,
    },
    push::{Action, NewPatternedPushRule, NewPushRule, RuleKind, Ruleset},
};

use super::{
    api_err, notify_sync_event_for_generation, run_bounded, run_bounded_mutation, ClientLease,
    SyncEvent, CLIENTS, SYNC_GENERATION, SYNC_LIFECYCLE,
};

/// Only expose account defaults; room and sender overrides remain untouched.
#[frb]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotificationRule {
    MuteAll,
    SuppressNotices,
    UserMention,
    RoomMention,
    DisplayName,
    UserName,
    RoomNotif,
    Invite,
    MemberEvent,
    Reaction,
    Tombstone,
    Call,
    DirectMessage,
    EncryptedDirectMessage,
    GroupMessage,
    EncryptedGroupMessage,
    SuppressEdits,
    PollStartDirect,
    PollStartGroup,
    PollEndDirect,
    PollEndGroup,
    PollResponse,
    SubscribedThread,
    SuppressUnsubscribedThreads,
}

impl NotificationRule {
    fn target(self) -> (RuleKind, &'static str) {
        use NotificationRule::*;
        match self {
            MuteAll => (RuleKind::Override, ".m.rule.master"),
            SuppressNotices => (RuleKind::Override, ".m.rule.suppress_notices"),
            UserMention => (RuleKind::Override, ".m.rule.is_user_mention"),
            RoomMention => (RuleKind::Override, ".m.rule.is_room_mention"),
            DisplayName => (RuleKind::Override, ".m.rule.contains_display_name"),
            UserName => (RuleKind::Content, ".m.rule.contains_user_name"),
            RoomNotif => (RuleKind::Override, ".m.rule.roomnotif"),
            Invite => (RuleKind::Override, ".m.rule.invite_for_me"),
            MemberEvent => (RuleKind::Override, ".m.rule.member_event"),
            Reaction => (RuleKind::Override, ".m.rule.reaction"),
            Tombstone => (RuleKind::Override, ".m.rule.tombstone"),
            Call => (RuleKind::Underride, ".m.rule.call"),
            DirectMessage => (RuleKind::Underride, ".m.rule.room_one_to_one"),
            EncryptedDirectMessage => (RuleKind::Underride, ".m.rule.encrypted_room_one_to_one"),
            GroupMessage => (RuleKind::Underride, ".m.rule.message"),
            EncryptedGroupMessage => (RuleKind::Underride, ".m.rule.encrypted"),
            SuppressEdits => (RuleKind::Override, ".m.rule.suppress_edits"),
            PollStartDirect => (
                RuleKind::Underride,
                ".org.matrix.msc3930.rule.poll_start_one_to_one",
            ),
            PollStartGroup => (RuleKind::Underride, ".org.matrix.msc3930.rule.poll_start"),
            PollEndDirect => (
                RuleKind::Underride,
                ".org.matrix.msc3930.rule.poll_end_one_to_one",
            ),
            PollEndGroup => (RuleKind::Underride, ".org.matrix.msc3930.rule.poll_end"),
            SubscribedThread => (
                RuleKind::Underride,
                ".io.element.msc4306.rule.subscribed_thread",
            ),
            SuppressUnsubscribedThreads => (
                RuleKind::Underride,
                ".io.element.msc4306.rule.unsubscribed_thread",
            ),
            PollResponse => (RuleKind::Override, ".org.matrix.msc3930.rule.poll_response"),
        }
    }

    fn controls_enabled(self) -> bool {
        matches!(
            self,
            Self::MuteAll
                | Self::SuppressNotices
                | Self::SuppressEdits
                | Self::SuppressUnsubscribedThreads
        )
    }
}

const RULES: [NotificationRule; 24] = [
    NotificationRule::MuteAll,
    NotificationRule::SuppressNotices,
    NotificationRule::UserMention,
    NotificationRule::RoomMention,
    NotificationRule::DisplayName,
    NotificationRule::UserName,
    NotificationRule::RoomNotif,
    NotificationRule::Invite,
    NotificationRule::MemberEvent,
    NotificationRule::Reaction,
    NotificationRule::Tombstone,
    NotificationRule::Call,
    NotificationRule::DirectMessage,
    NotificationRule::EncryptedDirectMessage,
    NotificationRule::GroupMessage,
    NotificationRule::EncryptedGroupMessage,
    NotificationRule::SuppressEdits,
    NotificationRule::PollStartDirect,
    NotificationRule::PollStartGroup,
    NotificationRule::PollEndDirect,
    NotificationRule::PollEndGroup,
    NotificationRule::PollResponse,
    NotificationRule::SubscribedThread,
    NotificationRule::SuppressUnsubscribedThreads,
];

#[frb]
#[derive(Clone, Debug)]
pub struct NotificationRuleSetting {
    pub rule: NotificationRule,
    pub enabled: bool,
    /// Older homeservers may omit mention or legacy rules.
    pub supported: bool,
}

fn settings_from_rules(rules: &Ruleset) -> Vec<NotificationRuleSetting> {
    RULES
        .into_iter()
        .map(|rule| {
            let (kind, id) = rule.target();
            let current = rules.get(kind, id);
            NotificationRuleSetting {
                rule,
                enabled: current.is_some_and(|r| {
                    r.enabled() && (rule.controls_enabled() || r.triggers_notification())
                }),
                supported: current.is_some(),
            }
        })
        .collect()
}

#[frb]
#[derive(Clone, Debug)]
pub struct NotificationPreferences {
    pub rules: Vec<NotificationRuleSetting>,
    pub keywords: Vec<String>,
}

fn keywords_from_rules(rules: &Ruleset) -> Vec<String> {
    let mut keywords: Vec<_> = rules
        .content
        .iter()
        .filter(|r| !r.default && r.enabled && r.actions.iter().any(Action::should_notify))
        .map(|r| r.pattern.clone())
        .collect();
    keywords.sort();
    keywords.dedup();
    keywords
}

async fn account_client(user_id: &str) -> Result<ClientLease, String> {
    let lifecycle = SYNC_LIFECYCLE.read().await;
    let client = CLIENTS
        .read()
        .await
        .get(user_id)
        .map(|entry| entry.client.clone())
        .ok_or_else(|| api_err("notifications", "账号尚未就绪，请重试。".to_owned()))?;
    Ok(ClientLease {
        client,
        lifecycle: std::sync::Arc::new(lifecycle),
    })
}

/// Read the server, including changes from other devices and writes not yet
/// echoed by sync. Never present SDK fallback defaults as saved preferences.
#[frb]
pub async fn get_notification_rules(
    account_user_id: String,
) -> Result<NotificationPreferences, String> {
    let client = account_client(&account_user_id).await?;
    run_bounded(async move {
        let response = client
            .send(get_pushrules_all::v3::Request::new())
            .await
            .map_err(|error| api_err("notifications", format!("读取通知偏好失败：{error}")))?;
        Ok(NotificationPreferences {
            rules: settings_from_rules(&response.global),
            keywords: keywords_from_rules(&response.global),
        })
    })
    .await
}

fn notification_actions(
    rules: &Ruleset,
    defaults: &Ruleset,
    rule: NotificationRule,
    enabled: bool,
) -> Result<Vec<Action>, String> {
    let (kind, id) = rule.target();
    let current = rules
        .get(kind.clone(), id)
        .ok_or("此服务器不支持该通知规则。")?;
    if !enabled {
        // Keep matching the event with no notification action. Disabling the
        // rule instead would fall through to all-message rules and still notify.
        return Ok(vec![]);
    }
    if current.triggers_notification() {
        return Ok(current.actions().to_vec());
    }
    let actions = defaults
        .get(kind, id)
        .map(|r| r.actions().to_vec())
        .unwrap_or_default();
    if actions.iter().any(Action::should_notify) {
        Ok(actions)
    } else {
        // Membership and reactions are suppressed by default, but can be
        // explicitly opted into. Do not introduce a sound or highlight.
        Ok(vec![Action::Notify])
    }
}

/// Update one preference, preserving every other account/room/sender rule.
#[frb]
pub async fn set_notification_rule(
    account_user_id: String,
    rule: NotificationRule,
    enabled: bool,
) -> Result<(), String> {
    let client = account_client(&account_user_id).await?;
    let lifecycle = client.lifecycle_protection();
    let generation = SYNC_GENERATION.load(std::sync::atomic::Ordering::SeqCst);
    run_bounded_mutation(
        format!("notification_rules:{account_user_id}"),
        lifecycle,
        async move {
            if !client.matrix_auth().logged_in() {
                return Err(api_err(
                    "notifications",
                    "当前账号已登出，请重新登录。".to_owned(),
                ));
            }
            let (kind, id) = rule.target();
            let response = client
                .send(get_pushrules_all::v3::Request::new())
                .await
                .map_err(|error| api_err("notifications", format!("读取通知偏好失败：{error}")))?;
            if response.global.get(kind.clone(), id).is_none() {
                return Err("此服务器不支持该通知规则。".to_owned());
            }
            if rule.controls_enabled() {
                client
                    .send(set_pushrule_enabled::v3::Request::new(
                        kind,
                        id.to_owned(),
                        enabled,
                    ))
                    .await
                    .map_err(|error| {
                        api_err("notifications", format!("保存通知偏好失败：{error}"))
                    })?;
            } else {
                let defaults = Ruleset::server_default(client.user_id().ok_or("当前账号已登出。")?);
                let actions = notification_actions(&response.global, &defaults, rule, enabled)?;
                client
                    .send(set_pushrule_actions::v3::Request::new(
                        kind.clone(),
                        id.to_owned(),
                        actions,
                    ))
                    .await
                    .map_err(|error| {
                        api_err("notifications", format!("保存通知偏好失败：{error}"))
                    })?;
                client
                    .send(set_pushrule_enabled::v3::Request::new(
                        kind,
                        id.to_owned(),
                        true,
                    ))
                    .await
                    .map_err(|error| {
                        api_err(
                            "notifications",
                            format!("保存通知偏好失败，请刷新确认：{error}"),
                        )
                    })?;
            }
            notify_sync_event_for_generation(generation, SyncEvent::RoomListChanged);
            Ok(())
        },
    )
    .await
}

/// Keyword rules apply to plaintext messages and are shared with other clients.
#[frb]
pub async fn set_notification_keyword(
    account_user_id: String,
    keyword: String,
    enabled: bool,
) -> Result<(), String> {
    use sha2::{Digest, Sha256};
    let keyword = keyword.trim().to_owned();
    if keyword.is_empty() || keyword.chars().count() > 100 {
        return Err("关键词需要为 1–100 个字符。".to_owned());
    }
    let client = account_client(&account_user_id).await?;
    let lifecycle = client.lifecycle_protection();
    run_bounded_mutation(
        format!("notification_rules:{account_user_id}"),
        lifecycle,
        async move {
            if !client.matrix_auth().logged_in() {
                return Err("当前账号已登出，请重新登录。".to_owned());
            }
            let rules = client
                .send(get_pushrules_all::v3::Request::new())
                .await
                .map_err(|error| api_err("notifications", format!("读取关键词失败：{error}")))?
                .global;
            if enabled {
                if keywords_from_rules(&rules).contains(&keyword) {
                    return Ok(());
                }
                let id = format!("matter.keyword.{:x}", Sha256::digest(keyword.as_bytes()));
                let rule = NewPushRule::Content(NewPatternedPushRule::new(
                    id.clone(),
                    keyword,
                    vec![Action::Notify],
                ));
                client
                    .send(set_pushrule::v3::Request::new(rule))
                    .await
                    .map_err(|error| {
                        api_err("notifications", format!("添加关键词失败：{error}"))
                    })?;
                client
                    .send(set_pushrule_enabled::v3::Request::new(
                        RuleKind::Content,
                        id,
                        true,
                    ))
                    .await
                    .map_err(|error| {
                        api_err("notifications", format!("启用关键词失败：{error}"))
                    })?;
            } else {
                for rule in rules
                    .content
                    .iter()
                    .filter(|r| !r.default && r.pattern == keyword)
                {
                    client
                        .send(delete_pushrule::v3::Request::new(
                            RuleKind::Content,
                            rule.rule_id.clone(),
                        ))
                        .await
                        .map_err(|error| {
                            api_err("notifications", format!("移除关键词失败：{error}"))
                        })?;
                }
            }
            Ok(())
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::{push::Tweak, user_id};

    #[test]
    fn defaults_distinguish_suppression_from_notification_actions() {
        let rules = Ruleset::server_default(user_id!("@alice:example.org"));
        let settings = settings_from_rules(&rules);
        let enabled = |rule| settings.iter().find(|s| s.rule == rule).unwrap().enabled;
        assert!(!enabled(NotificationRule::MuteAll));
        assert!(enabled(NotificationRule::SuppressNotices));
        assert!(enabled(NotificationRule::Invite));
        assert!(enabled(NotificationRule::UserMention));
        assert!(enabled(NotificationRule::DirectMessage));
        assert!(!enabled(NotificationRule::MemberEvent));
        assert!(!enabled(NotificationRule::Reaction));
        // Legacy rules aren't invented on modern servers.
        assert!(
            !settings
                .iter()
                .find(|s| s.rule == NotificationRule::DisplayName)
                .unwrap()
                .supported
        );
    }

    #[test]
    fn mute_all_preserves_other_preferences() {
        let mut rules = Ruleset::server_default(user_id!("@alice:example.org"));
        let previous = settings_from_rules(&rules);
        rules
            .set_enabled(RuleKind::Override, ".m.rule.master", true)
            .unwrap();
        let muted = settings_from_rules(&rules);
        assert!(muted[0].enabled);
        for (before, after) in previous.iter().zip(&muted).skip(1) {
            assert_eq!(before.enabled, after.enabled);
            assert_eq!(before.supported, after.supported);
        }
    }

    #[test]
    fn disabling_mentions_stops_fallthrough_and_restores_highlight() {
        let defaults = Ruleset::server_default(user_id!("@alice:example.org"));
        let mut rules = defaults.clone();
        let rule = NotificationRule::UserMention;
        let (kind, id) = rule.target();
        let off = notification_actions(&rules, &defaults, rule, false).unwrap();
        rules.set_actions(kind.clone(), id, off).unwrap();
        assert!(rules.get(kind.clone(), id).unwrap().enabled());
        assert!(!rules.get(kind.clone(), id).unwrap().triggers_notification());
        let on = notification_actions(&rules, &defaults, rule, true).unwrap();
        assert!(on.iter().any(Action::should_notify));
        assert!(on
            .iter()
            .any(|action| matches!(action, Action::SetTweak(Tweak::Highlight(_)))));
    }

    #[tokio::test]
    async fn muted_mentions_do_not_fall_through_to_regular_messages() {
        use matrix_sdk::ruma::{owned_room_id, push::PushConditionRoomCtx, serde::Raw};
        let user = user_id!("@alice:example.org");
        let mut rules = Ruleset::server_default(user);
        let event = Raw::new(&serde_json::json!({
            "type": "m.room.message",
            "sender": "@bob:example.org",
            "content": {"msgtype": "m.text", "body": "Hello Alice", "m.mentions": {"user_ids": [user]}}
        })).unwrap();
        let context = PushConditionRoomCtx::new(
            owned_room_id!("!group:example.org"),
            3u32.into(),
            user.to_owned(),
            "Alice".to_owned(),
        );
        assert!(rules
            .get_actions(&event, &context)
            .await
            .iter()
            .any(Action::should_notify));
        rules
            .set_actions(RuleKind::Override, ".m.rule.is_user_mention", vec![])
            .unwrap();
        assert!(rules.get_actions(&event, &context).await.is_empty());
        // Merely disabling the matching rule would produce a notification.
        rules
            .set_enabled(RuleKind::Override, ".m.rule.is_user_mention", false)
            .unwrap();
        assert!(rules
            .get_actions(&event, &context)
            .await
            .iter()
            .any(Action::should_notify));
        rules
            .set_enabled(RuleKind::Override, ".m.rule.master", true)
            .unwrap();
        assert!(rules.get_actions(&event, &context).await.is_empty());
    }

    #[test]
    fn keyword_list_excludes_default_and_non_notifying_content_rules() {
        let mut rules = Ruleset::server_default(user_id!("@alice:example.org"));
        for (id, pattern, actions) in [
            ("keyword-a", "Matter", vec![Action::Notify]),
            ("keyword-b", "Matter", vec![Action::Notify]),
            ("silent", "ignored", vec![]),
        ] {
            rules
                .insert(
                    NewPushRule::Content(NewPatternedPushRule::new(
                        id.to_owned(),
                        pattern.to_owned(),
                        actions,
                    )),
                    None,
                    None,
                )
                .unwrap();
        }
        assert_eq!(keywords_from_rules(&rules), vec!["Matter"]);
        rules
            .set_enabled(RuleKind::Content, "keyword-a", false)
            .unwrap();
        rules
            .set_enabled(RuleKind::Content, "keyword-b", false)
            .unwrap();
        assert!(keywords_from_rules(&rules).is_empty());
    }

    #[test]
    fn reactions_and_membership_can_notify_without_touching_other_rules() {
        let defaults = Ruleset::server_default(user_id!("@alice:example.org"));
        for rule in [NotificationRule::Reaction, NotificationRule::MemberEvent] {
            let actions = notification_actions(&defaults, &defaults, rule, true).unwrap();
            assert!(matches!(actions.as_slice(), [Action::Notify]));
        }
        assert!(
            notification_actions(&defaults, &defaults, NotificationRule::DisplayName, true)
                .is_err()
        );
    }
}
