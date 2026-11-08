//! Ignored users implementation.

use super::*;

pub(super) async fn get_ignored_users() -> Result<IgnoredUsers, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("account", "No client created.".to_string()))?;
    let account = client.account();
    // Bounded like the other P0 calls: the server read holds the client
    // lease (blocking logout/account switch).
    run_bounded(async move {
        // Prefer the server copy, but fall back to the local state store so
        // an offline client still filters ignored senders after its first
        // sync.
        let (raw, from_server) = match account
            .fetch_account_data_static::<IgnoredUserListEventContent>()
            .await
        {
            Ok(raw) => (raw, true),
            Err(network_error) => (
                account
                    .account_data::<IgnoredUserListEventContent>()
                    .await
                    .map_err(|error| {
                        api_err(
                            "account",
                            format!(
                                "加载忽略用户列表失败: {network_error}；本地缓存读取失败: {error}"
                            ),
                        )
                    })?,
                false,
            ),
        };
        let mut content = raw
            .map(|raw| raw.deserialize())
            .transpose()
            .map_err(|error| api_err("account", format!("解析忽略用户列表失败: {error}")))?
            .unwrap_or_default();
        if !from_server {
            merge_current_account_ignored_user_overrides(&client, &mut content).await;
        }
        Ok(IgnoredUsers {
            user_ids: content
                .ignored_users
                .into_keys()
                .map(|user_id| user_id.to_string())
                .collect(),
            from_server,
        })
    })
    .await
}

pub(super) async fn set_user_ignored(
    account_user_id: String,
    user_id: String,
    ignored: bool,
) -> Result<Vec<String>, String> {
    let client = get_client()
        .await
        .ok_or_else(|| api_err("account", "No client created.".to_string()))?;
    let active_user_id = client
        .user_id()
        .ok_or_else(|| api_err("account", "No active user".to_string()))?
        .to_string();
    if active_user_id != account_user_id {
        return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
    }
    let user_id = matrix_sdk::ruma::UserId::parse(user_id.trim())
        .map_err(|error| api_err("account", format!("无效的用户 ID: {error}")))?
        .to_owned();
    // Capture the account's current client instance id: the queued write may
    // execute after a logout+relogin replaced the client (deep predecessor
    // chains). Same discipline as `set_room_muted` / `create_dm`.
    let expected_instance_id = CLIENTS
        .read()
        .await
        .get(&account_user_id)
        .map(|e| e.instance_id);
    let lifecycle_protection = client.lifecycle_protection();
    let mutation_client = client.clone();
    run_bounded_mutation(
        format!("ignored:{active_user_id}"),
        lifecycle_protection,
        async move {
            // Fail fast when the account was logged out or its client was
            // replaced while this write was queued: a stale session must not
            // apply a late ignored-list edit (and its wording would otherwise
            // mislead).
            if !mutation_client.matrix_auth().logged_in() {
                return Err(api_err(
                    "account",
                    "当前账号已登出，请重新登录。".to_string(),
                ));
            }
            let is_current_client = CLIENTS
                .read()
                .await
                .get(&account_user_id)
                .map(|e| e.instance_id)
                == expected_instance_id;
            if !is_current_client {
                return Err(api_err("account", "当前账号已切换，请重试。".to_string()));
            }
            let account = mutation_client.account();
            let mut content = account
                .fetch_account_data_static::<IgnoredUserListEventContent>()
                .await
                .map_err(|error| api_err("account", format!("加载忽略用户列表失败: {error}")))?
                .map(|raw| raw.deserialize())
                .transpose()
                .map_err(|error| api_err("account", format!("解析忽略用户列表失败: {error}")))?
                .unwrap_or_default();
            if ignored {
                content
                    .ignored_users
                    .insert(user_id.clone(), IgnoredUser::new());
            } else {
                content.ignored_users.remove(&user_id);
            }
            let updated = content
                .ignored_users
                .keys()
                .map(|user_id| user_id.to_string())
                .collect();
            // Baseline of the local store before the write: the store only
            // advances on the sync echo, and previews consult it until then.
            let synced_baseline = mutation_client.is_user_ignored(&user_id).await;
            let override_key = ignored_user_override_key(&mutation_client, &user_id);
            account
                .set_account_data(content)
                .await
                .map_err(|error| api_err("account", format!("更新忽略用户列表失败: {error}")))?;
            if let Some(key) = override_key {
                set_ignored_user_override(key, synced_baseline, ignored).await;
            }
            // No IgnoredUsersChanged here: the Dart caller write-throughs the
            // returned list and revalidates itself, and the genuine account-data
            // echo arrives via the sync event handler. Notifying a local write
            // through the same event would race the FFI future on a different
            // channel — if it landed after the write-through, it would demote
            // the just-confirmed list and bump the generation as if a
            // cross-device change had happened.
            Ok(updated)
        },
    )
    .await
}
