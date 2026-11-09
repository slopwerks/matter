//! Sdk reactions adaptation.
use super::*;

/// Toggle through the SDK so pending reactions and remote reactions share
/// one source of truth. Wait for the local echo before accepting another click.
pub(in crate::api::matrix) async fn toggle_reaction(
    client: &Client,
    room: &Room,
    event_id: matrix_sdk::ruma::OwnedEventId,
    key: &str,
) -> Result<ChatMessage, String> {
    let room_key = timeline_key(client, room)?;
    let lock = REACTION_LOCKS
        .lock()
        .await
        .entry(room_key.clone())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone();
    let _guard = lock.lock().await;
    let live_timeline = get_or_create_timeline(client, room).await?;
    let timeline = if live_timeline.item_by_event_id(&event_id).await.is_some() {
        live_timeline
    } else {
        // Detached history and pinned messages may be outside the live window.
        // Keep their focused timeline alive so repeated clicks see local echoes.
        let focused_key = format!("{room_key}\n{event_id}");
        let cached = TIMELINES.lock().await.get(&focused_key).cloned();
        if let Some(timeline) = cached {
            timeline
        } else {
            let timeline = Arc::new(
                TimelineBuilder::new(room)
                    .with_focus(TimelineFocus::Event {
                        target: event_id.clone(),
                        num_context_events: 0,
                        thread_mode: TimelineEventFocusThreadMode::Automatic {
                            hide_threaded_events: false,
                        },
                    })
                    .build()
                    .await
                    .map_err(|error| api_err("rooms", format!("加载回应目标失败: {error}")))?,
            );
            TIMELINES.lock().await.insert(focused_key, timeline.clone());
            timeline
        }
    };
    let (_, mut updates) = timeline.subscribe().await;
    let added = timeline
        .toggle_reaction(
            &matrix_sdk_ui::timeline::TimelineEventItemId::EventId(event_id.clone()),
            key,
        )
        .await
        .map_err(|error| api_err("rooms", format!("Reaction failed: {error}")))?;
    let my_user_id = client.user_id().map(ToString::to_string);
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(item) = timeline.item_by_event_id(&event_id).await {
                let reactions = timeline_reactions(&item);
                let has_reacted = reactions.iter().any(|reaction| {
                    reaction.key == key
                        && my_user_id
                            .as_ref()
                            .is_some_and(|user| reaction.senders.contains(user))
                });
                if has_reacted == added {
                    return convert_snapshot(room, &snapshot(&timeline).await)
                        .await
                        .into_iter()
                        .find(|message| message.id == event_id.as_str())
                        .ok_or_else(|| api_err("rooms", "回应目标消息不可用。".to_owned()));
                }
            }
            if updates.next().await.is_none() {
                return Err(api_err("rooms", "回应时间线已关闭。".to_owned()));
            }
        }
    })
    .await
    .map_err(|_| api_err("rooms", "回应状态更新超时，请刷新确认。".to_owned()))?
}
