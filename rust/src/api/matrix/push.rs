use flutter_rust_bridge::frb;
use matrix_sdk::ruma::{
    api::client::push::{PusherIds, PusherInit, PusherKind},
    push::{HttpPusherData, PushFormat},
};

use super::{api_err, run_bounded, ClientLease, CLIENTS, SYNC_LIFECYCLE};

async fn account_client(user_id: &str) -> Result<ClientLease, String> {
    let lifecycle = SYNC_LIFECYCLE.read().await;
    let client = CLIENTS
        .read()
        .await
        .get(user_id)
        .map(|entry| entry.client.clone())
        .ok_or_else(|| api_err("push", "账号尚未就绪，请重试。".to_owned()))?;
    Ok(ClientLease {
        client,
        lifecycle: std::sync::Arc::new(lifecycle),
    })
}

fn http_pusher(
    user_id: &str,
    device_id: &str,
    pushkey: String,
    app_id: String,
    gateway_url: String,
    registration_id: String,
    web_subscription: Option<String>,
) -> Result<matrix_sdk::ruma::api::client::push::Pusher, String> {
    let url = url::Url::parse(&gateway_url).map_err(|_| "推送网关 URL 无效。")?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.path().ends_with("/_matrix/push/v1/notify")
    {
        return Err("请填写 HTTPS 网关地址，路径以 /_matrix/push/v1/notify 结尾。".to_owned());
    }
    if app_id.is_empty()
        || app_id.len() > 64
        || !app_id.is_ascii()
        || app_id.chars().any(char::is_whitespace)
        || pushkey.is_empty()
        || pushkey.len() > 512
        || registration_id.is_empty()
    {
        return Err("推送应用 ID 或设备令牌无效。".to_owned());
    }
    let mut data = HttpPusherData::new(gateway_url);
    data.format = Some(PushFormat::EventIdOnly);
    data.data.insert(
        "default_payload".to_owned(),
        serde_json::json!({"user_id": user_id, "registration_id": registration_id}),
    );
    let mut device_display_name = format!("Matter Android ({device_id})");
    if let Some(subscription) = web_subscription {
        let subscription: serde_json::Value =
            serde_json::from_str(&subscription).map_err(|_| "浏览器推送订阅无效。")?;
        let endpoint = subscription["endpoint"].as_str().ok_or("订阅端点缺失。")?;
        let endpoint_url = url::Url::parse(endpoint).map_err(|_| "订阅端点无效。")?;
        let p256dh = subscription["keys"]["p256dh"]
            .as_str()
            .ok_or("订阅公钥缺失。")?;
        let auth = subscription["keys"]["auth"]
            .as_str()
            .ok_or("订阅鉴权参数缺失。")?;
        if endpoint_url.scheme() != "https"
            || endpoint_url.host_str().is_none()
            || p256dh != pushkey
            || auth.is_empty()
        {
            return Err("浏览器推送订阅无效。".to_owned());
        }
        data.data.insert("endpoint".to_owned(), endpoint.into());
        data.data.insert("p256dh".to_owned(), p256dh.into());
        data.data.insert("auth".to_owned(), auth.into());
        device_display_name = format!("Matter Web ({device_id})");
    }
    Ok(PusherInit {
        ids: PusherIds::new(pushkey, app_id),
        kind: PusherKind::Http(data),
        app_display_name: "Matter".to_owned(),
        device_display_name,
        profile_tag: None,
        lang: "zh-CN".to_owned(),
    }
    .into())
}

/// Register on the named account, including inactive accounts on this device.
/// append=true preserves other users sharing this installation's subscription.
#[frb]
pub async fn register_http_pusher(
    account_user_id: String,
    pushkey: String,
    app_id: String,
    gateway_url: String,
    registration_id: String,
    web_subscription: Option<String>,
) -> Result<(), String> {
    let client = account_client(&account_user_id).await?;
    let device_id = client.device_id().ok_or("当前会话没有设备 ID。")?.as_str();
    let pusher = http_pusher(
        &account_user_id,
        device_id,
        pushkey,
        app_id,
        gateway_url,
        registration_id,
        web_subscription,
    )?;
    run_bounded(async move {
        client.pusher().set(pusher, true).await.map_err(|_| {
            api_err(
                "push",
                "注册推送失败，请检查 Homeserver 连接后重试。".to_owned(),
            )
        })
    })
    .await
}

#[frb]
pub async fn unregister_http_pusher(
    account_user_id: String,
    pushkey: String,
    app_id: String,
) -> Result<(), String> {
    let client = account_client(&account_user_id).await?;
    run_bounded(async move {
        client
            .pusher()
            .delete(PusherIds::new(pushkey, app_id))
            .await
            .map_err(|_| {
                api_err(
                    "push",
                    "注销推送失败，请检查 Homeserver 连接后重试。".to_owned(),
                )
            })
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::http_pusher;

    #[test]
    fn pusher_contains_only_event_ids_and_account_routing_data() {
        let pusher = http_pusher(
            "@alice:example.org",
            "DEVICE",
            "token".to_owned(),
            "moe.aks.matter".to_owned(),
            "https://push.example.org/_matrix/push/v1/notify".to_owned(),
            "registration".to_owned(),
            None,
        )
        .unwrap();
        let json = serde_json::to_value(pusher).unwrap();
        assert_eq!(json["kind"], "http");
        assert_eq!(json["data"]["format"], "event_id_only");
        assert_eq!(
            json["data"]["default_payload"]["user_id"],
            "@alice:example.org"
        );
        assert_eq!(
            json["data"]["default_payload"]["registration_id"],
            "registration"
        );
    }

    #[test]
    fn browser_subscription_is_encoded_without_message_contents() {
        let subscription = serde_json::json!({
            "endpoint": "https://browser-push.example.org/subscription",
            "keys": {"p256dh": "browser-key", "auth": "browser-auth"}
        });
        let pusher = http_pusher(
            "@alice:example.org",
            "DEVICE",
            "browser-key".to_owned(),
            "matter.web".to_owned(),
            "https://push.example.org/_matrix/push/v1/notify".to_owned(),
            "registration".to_owned(),
            Some(subscription.to_string()),
        )
        .unwrap();
        let json = serde_json::to_value(pusher).unwrap();
        assert_eq!(json["pushkey"], "browser-key");
        assert_eq!(json["data"]["endpoint"], subscription["endpoint"]);
        assert_eq!(json["data"]["p256dh"], "browser-key");
        assert_eq!(json["data"]["auth"], "browser-auth");
        assert_eq!(json["data"]["format"], "event_id_only");
        assert_eq!(
            json["data"]["default_payload"]["user_id"],
            "@alice:example.org"
        );
        assert_eq!(json["device_display_name"], "Matter Web (DEVICE)");
    }

    #[test]
    fn rejects_invalid_browser_subscriptions() {
        for subscription in [
            "invalid json".to_owned(),
            serde_json::json!({"endpoint": "http://example.org/push", "keys": {"p256dh": "key", "auth": "auth"}}).to_string(),
            serde_json::json!({"endpoint": "https://example.org/push", "keys": {"p256dh": "wrong-key", "auth": "auth"}}).to_string(),
            serde_json::json!({"endpoint": "https://example.org/push", "keys": {"p256dh": "key"}}).to_string(),
        ] {
            assert!(http_pusher(
                "@alice:example.org", "DEVICE", "key".to_owned(), "matter.web".to_owned(),
                "https://push.example.org/_matrix/push/v1/notify".to_owned(),
                "registration".to_owned(), Some(subscription),
            ).is_err());
        }
    }

    #[test]
    fn rejects_non_matrix_or_insecure_gateways() {
        for url in [
            "http://push.example.org/_matrix/push/v1/notify",
            "https://push.example.org",
            "https://user:password@push.example.org/_matrix/push/v1/notify",
        ] {
            assert!(http_pusher(
                "@alice:example.org",
                "DEVICE",
                "token".to_owned(),
                "app".to_owned(),
                url.to_owned(),
                "id".to_owned(),
                None,
            )
            .is_err());
        }
    }
}
