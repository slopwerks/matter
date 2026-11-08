use super::*;
use matrix_sdk::ruma::{profile::ProfileFieldName, UserId};
use matrix_sdk::test_utils::mocks::MatrixMockServer;

static ACCOUNT_API_TEST_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

#[tokio::test]
async fn account_bound_apis_reject_a_switched_account_before_access() {
    let _test_lock = ACCOUNT_API_TEST_LOCK.lock().await;
    let server = MatrixMockServer::new().await;
    let client = server.client_builder().build().await;
    let user_id = client.user_id().unwrap().to_string();
    let (previous_active, previous_entry) = {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        let active = ACTIVE_USER.write().await.replace(user_id.clone());
        let entry = CLIENTS.write().await.insert(
            user_id.clone(),
            ClientEntry {
                client,
                data_dir: String::new(),
                search_index_dir: std::path::PathBuf::new(),
                instance_id: u64::MAX,
                room_key_task: tokio::spawn(std::future::pending()),
            },
        );
        (active, entry)
    };
    let wrong = "@wrong:example.org".to_owned();
    let room = "!missing:example.org".to_owned();
    let results = [
        send_image_message(
            wrong.clone(),
            room.clone(),
            vec![1],
            "image.png".into(),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .map(|_| ()),
        send_file_message(
            wrong.clone(),
            room.clone(),
            vec![1],
            "file.txt".into(),
            None,
            None,
        )
        .await,
        send_video_message(
            wrong.clone(),
            room.clone(),
            vec![1],
            "video.mp4".into(),
            None,
            None,
            None,
            None,
            None,
        )
        .await,
        send_location(
            wrong.clone(),
            room.clone(),
            "location".into(),
            "geo:1,2".into(),
        )
        .await,
        send_poll(
            wrong.clone(),
            room.clone(),
            "question".into(),
            vec!["yes".into(), "no".into()],
            true,
            1,
        )
        .await,
        redact_message(wrong.clone(), room, "$event:example.org".into(), None).await,
        get_encryption_recovery_info(Some(wrong.clone()))
            .await
            .map(|_| ()),
        recover_encryption("existing-recovery-key".into(), Some(wrong.clone())).await,
        enable_encryption_recovery(None, Some(wrong))
            .await
            .map(|_| ()),
    ];
    let unknown_recovery = enable_encryption_recovery(None, Some(user_id.clone())).await;
    {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        *ACTIVE_USER.write().await = previous_active;
        let entry = CLIENTS.write().await.remove(&user_id).unwrap();
        entry.room_key_task.abort();
        if let Some(previous_entry) = previous_entry {
            CLIENTS.write().await.insert(user_id, previous_entry);
        }
    }
    assert!(unknown_recovery
        .unwrap_err()
        .contains("恢复配置已存在或状态尚未确认"));
    for result in results {
        assert!(result.unwrap_err().contains("当前账号已切换"));
    }
    server.verify_and_reset().await;
}

#[tokio::test]
async fn adding_account_token_login_preserves_original_crypto_and_cancel_is_isolated() {
    let _test_lock = ACCOUNT_API_TEST_LOCK.lock().await;
    let active_server = MatrixMockServer::new().await;
    let pending_server = MatrixMockServer::new().await;
    let client = active_server
        .client_builder()
        .logged_in_with_token(
            "1234".into(),
            UserId::parse("@original-add-token:example.org").unwrap(),
            "ORIGINAL_DEVICE".into(),
        )
        .build()
        .await;
    let user_id = client.user_id().unwrap().to_string();
    let fingerprint = client.encryption().ed25519_key().await.unwrap();
    let previous_status = get_connection_status();
    let (previous_active, previous_entry, previous_pending, previous_relogin) = {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        let active = ACTIVE_USER.write().await.replace(user_id.clone());
        let entry = CLIENTS.write().await.insert(
            user_id.clone(),
            ClientEntry {
                client,
                data_dir: String::new(),
                search_index_dir: std::path::PathBuf::new(),
                instance_id: u64::MAX,
                room_key_task: tokio::spawn(std::future::pending()),
            },
        );
        let pending = PENDING.write().await.take();
        let relogin = SESSION_RELOGIN.write().await.take();
        (active, entry, pending, relogin)
    };
    let data_dir = std::env::temp_dir().join(format!(
        "matter-add-account-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let search_key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".to_owned();
    create_client(
        pending_server.uri(),
        data_dir.to_str().unwrap().into(),
        search_key.clone(),
        false,
    )
    .await
    .unwrap();
    let bob = "@bob:example.org".to_owned();
    let result = login_with_token("bob-token".into(), bob.clone(), "BOB_DEVICE".into(), None).await;
    let bob_session = get_session().await.unwrap();
    let switched = switch_account(user_id.clone()).await;
    let restored_fingerprint = get_client().await.unwrap().encryption().ed25519_key().await;
    let original_session = get_session().await.unwrap();
    create_client(
        pending_server.uri(),
        data_dir.to_str().unwrap().into(),
        search_key,
        false,
    )
    .await
    .unwrap();
    let cancelled = cancel_pending_login().await;
    let cancelled_again = cancel_pending_login().await;
    let current_user = get_active_user_id().await;
    let account_count = list_accounts().await.len();
    let pending_cleared = PENDING.read().await.is_none()
        && !build_sdk_data_dir(data_dir.to_str().unwrap(), None).exists();
    let bob_store_preserved = build_sdk_data_dir(data_dir.to_str().unwrap(), Some(&bob)).exists();
    {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        *ACTIVE_USER.write().await = previous_active.clone();
        *PENDING.write().await = previous_pending;
        *SESSION_RELOGIN.write().await = previous_relogin;
        let mut clients = CLIENTS.write().await;
        if let Some(entry) = clients.remove(&bob) {
            entry.room_key_task.abort();
        }
        let entry = clients.remove(&user_id).unwrap();
        entry.room_key_task.abort();
        if let Some(previous_entry) = previous_entry {
            clients.insert(user_id.clone(), previous_entry);
        }
        drop(clients);
        set_subscription_user(previous_active).await;
        set_connection_status(previous_status);
    }
    let _ = tokio::fs::remove_dir_all(data_dir).await;
    assert!(result.unwrap().success);
    assert_eq!(bob_session.user_id, bob);
    assert_eq!(bob_session.device_id, "BOB_DEVICE");
    assert_eq!(bob_session.access_token, "bob-token");
    assert!(switched);
    assert_eq!(restored_fingerprint, Some(fingerprint));
    assert_eq!(original_session.access_token, "1234");
    assert!(cancelled.is_ok());
    assert!(cancelled_again.is_ok());
    assert!(pending_cleared);
    assert!(bob_store_preserved);
    assert_eq!(current_user, Some(user_id));
    assert_eq!(account_count, 2);
}

#[tokio::test]
async fn adding_existing_account_with_token_never_revokes_imported_credentials() {
    let _test_lock = ACCOUNT_API_TEST_LOCK.lock().await;
    let server = MatrixMockServer::new().await;
    let user_id = "@existing-add-token:example.org".to_owned();
    let client = server
        .client_builder()
        .logged_in_with_token(
            "1234".into(),
            UserId::parse(&user_id).unwrap(),
            "ORIGINAL_DEVICE".into(),
        )
        .build()
        .await;
    let fingerprint = client.encryption().ed25519_key().await.unwrap();
    let (previous_active, previous_entry, previous_pending) = {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        let active = ACTIVE_USER.write().await.replace(user_id.clone());
        let entry = CLIENTS.write().await.insert(
            user_id.clone(),
            ClientEntry {
                client,
                data_dir: String::new(),
                search_index_dir: std::path::PathBuf::new(),
                instance_id: u64::MAX,
                room_key_task: tokio::spawn(std::future::pending()),
            },
        );
        let pending = PENDING.write().await.take();
        (active, entry, pending)
    };
    let data_dir = std::env::temp_dir().join(format!(
        "matter-duplicate-token-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    server.mock_versions().ok().mount().await;
    server.mock_logout().ok().expect(0).mount().await;
    let mut results = Vec::new();
    for (token, device) in [("1234", "ORIGINAL_DEVICE"), ("other-token", "OTHER_DEVICE")] {
        create_client(
            server.uri(),
            data_dir.to_str().unwrap().into(),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".into(),
            false,
        )
        .await
        .unwrap();
        results.push(login_with_token(token.into(), user_id.clone(), device.into(), None).await);
        cancel_pending_login().await.unwrap();
    }
    let logout_requests = server
        .server()
        .received_requests()
        .await
        .unwrap()
        .into_iter()
        .filter(|request| request.url.path().ends_with("/logout"))
        .count();
    let original_session = get_session().await.unwrap();
    let current_fingerprint = get_client().await.unwrap().encryption().ed25519_key().await;
    {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        *ACTIVE_USER.write().await = previous_active;
        *PENDING.write().await = previous_pending;
        let entry = CLIENTS.write().await.remove(&user_id).unwrap();
        entry.room_key_task.abort();
        if let Some(previous_entry) = previous_entry {
            CLIENTS
                .write()
                .await
                .insert(user_id.clone(), previous_entry);
        }
    }
    let _ = tokio::fs::remove_dir_all(data_dir).await;
    for result in results {
        assert!(result.unwrap_err().contains("已登录"));
    }
    assert_eq!(logout_requests, 0, "importing a token must never revoke it");
    assert_eq!(original_session.user_id, user_id);
    assert_eq!(original_session.device_id, "ORIGINAL_DEVICE");
    assert_eq!(original_session.access_token, "1234");
    assert_eq!(current_fingerprint, Some(fingerprint));
    server.verify_and_reset().await;
}

#[tokio::test]
async fn adding_account_password_login_uses_pending_homeserver() {
    let _test_lock = ACCOUNT_API_TEST_LOCK.lock().await;
    let active_server = MatrixMockServer::new().await;
    let pending_server = MatrixMockServer::new().await;
    let client = active_server
        .client_builder()
        .logged_in_with_token(
            "1234".into(),
            UserId::parse("@original-add-password:example.org").unwrap(),
            "ORIGINAL_DEVICE".into(),
        )
        .build()
        .await;
    let user_id = client.user_id().unwrap().to_string();
    let fingerprint = client.encryption().ed25519_key().await.unwrap();
    let pending_client = pending_server.client_builder().unlogged().build().await;
    let (previous_active, previous_entry, previous_pending) = {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        let active = ACTIVE_USER.write().await.replace(user_id.clone());
        let entry = CLIENTS.write().await.insert(
            user_id.clone(),
            ClientEntry {
                client,
                data_dir: String::new(),
                search_index_dir: std::path::PathBuf::new(),
                instance_id: u64::MAX,
                room_key_task: tokio::spawn(std::future::pending()),
            },
        );
        let pending = PENDING.write().await.replace(PendingEntry {
            client: pending_client,
            data_dir: String::new(),
            homeserver_url: pending_server.uri(),
            search_index_key: String::new(),
        });
        (active, entry, pending)
    };
    active_server
        .mock_login()
        .error_unknown_token(false)
        .expect(0)
        .mount()
        .await;
    pending_server
        .mock_login()
        .error_unknown_token(false)
        .expect(1)
        .mount()
        .await;
    let result = login_with_password("bob".into(), "wrong-password".into()).await;
    let current_user = get_active_user_id().await;
    let current_fingerprint = get_client().await.unwrap().encryption().ed25519_key().await;
    {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        *ACTIVE_USER.write().await = previous_active;
        *PENDING.write().await = previous_pending;
        let entry = CLIENTS.write().await.remove(&user_id).unwrap();
        entry.room_key_task.abort();
        if let Some(previous_entry) = previous_entry {
            CLIENTS
                .write()
                .await
                .insert(user_id.clone(), previous_entry);
        }
    }
    assert!(!result.unwrap().success);
    assert_eq!(current_user, Some(user_id));
    assert_eq!(current_fingerprint, Some(fingerprint));
    active_server.verify_and_reset().await;
    pending_server.verify_and_reset().await;
}

/// The pending store must never be unlinked while a `create_client` build
/// is still staging on it. Before `PENDING_LIFECYCLE` the cancel took only
/// `SYNC_LIFECYCLE`, which `create_client` releases for the expensive
/// build — so a cancel landing in that window deleted `_pending` and the
/// build then installed a pending client whose SQLite files were gone.
///
/// Deterministic proof: `PENDING_LIFECYCLE` is held for the whole test, so
/// an unguarded `cancel_pending_login` still empties `PENDING` (it takes
/// only `SYNC_LIFECYCLE`) while the guarded one waits and cannot run.
#[tokio::test]
async fn cancel_pending_login_cannot_race_an_in_flight_create_client() {
    let _test_lock = ACCOUNT_API_TEST_LOCK.lock().await;
    let server = MatrixMockServer::new().await;
    let pending_client = server.client_builder().unlogged().build().await;
    let (previous_pending, previous_active) = {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        let previous_pending = PENDING.write().await.replace(PendingEntry {
            client: pending_client,
            data_dir: String::new(),
            homeserver_url: server.uri(),
            search_index_key: String::new(),
        });
        let previous_active = ACTIVE_USER.write().await.clone();
        (previous_pending, previous_active)
    };

    // Stand in for a `create_client` that is inside its build: it holds
    // the pending-login lifecycle lock for the whole staging window.
    let staging = PENDING_LIFECYCLE.lock().await;
    let cancel = tokio::spawn(cancel_pending_login());
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let cancelled_while_staging = PENDING.read().await.is_none();
    drop(staging);
    let cancel_result = cancel.await.unwrap();
    let pending_after = PENDING.read().await.is_none();

    {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        *PENDING.write().await = previous_pending;
        *ACTIVE_USER.write().await = previous_active;
    }

    assert!(
        !cancelled_while_staging,
        "cancel_pending_login emptied PENDING while a create_client build was staging"
    );
    assert!(cancel_result.is_ok());
    assert!(pending_after);
    server.verify_and_reset().await;
}

#[tokio::test]
async fn soft_logout_relogin_preserves_device_and_cross_signing_keys() {
    use matrix_sdk::test_utils::mocks::LoginResponseTemplate200;
    let _test_lock = ACCOUNT_API_TEST_LOCK.lock().await;
    let server = MatrixMockServer::new().await;
    server.mock_versions().ok().mount().await;
    let user_id = matrix_sdk::ruma::owned_user_id!("@alice:example.org");
    let device_id = matrix_sdk::ruma::owned_device_id!("EXISTING_DEVICE");
    let data_dir = std::env::temp_dir().join(format!(
        "matter-soft-relogin-{}",
        SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let sdk_dir = build_sdk_data_dir(data_dir.to_str().unwrap(), Some(user_id.as_str()));
    let index_dir = prepare_encrypted_search_index(&sdk_dir, false)
        .await
        .unwrap();
    let key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".to_owned();
    let client = server
        .client_builder()
        .logged_in_with_token("1234".into(), user_id.clone(), device_id.clone())
        .on_builder(|builder| {
            builder.sqlite_store(&sdk_dir, None).search_index_store(
                matrix_sdk::search_index::SearchIndexStoreKind::EncryptedDirectory(
                    index_dir.clone(),
                    key.clone(),
                ),
            )
        })
        .build()
        .await;
    let fingerprint = client.encryption().ed25519_key().await.unwrap();
    let secrets = {
        let machine = client.olm_machine_for_testing().await;
        let machine = machine.as_ref().unwrap();
        machine.bootstrap_cross_signing(false).await.unwrap();
        machine.export_cross_signing_keys().await.unwrap().unwrap()
    };
    let marker = sdk_dir.join("cached-local-state");
    tokio::fs::write(&marker, b"preserve cache").await.unwrap();
    let (previous_active, previous_entry) = {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        let active = ACTIVE_USER.write().await.replace(user_id.to_string());
        let entry = CLIENTS.write().await.insert(
            user_id.to_string(),
            ClientEntry {
                client,
                data_dir: data_dir.to_str().unwrap().into(),
                search_index_dir: index_dir,
                instance_id: u64::MAX,
                room_key_task: tokio::spawn(std::future::pending()),
            },
        );
        (active, entry)
    };
    reset_connection_status();
    server
        .mock_get_profile_field(&user_id, ProfileFieldName::DisplayName)
        .error_unknown_token(true)
        .expect(1)
        .mount()
        .await;
    assert!(get_profile().await.is_err());
    assert!(prepare_session_relogin(user_id.to_string()).await.unwrap());
    {
        let _scope = server
            .mock_login()
            .error_unknown_token(false)
            .expect(1)
            .mount_as_scoped()
            .await;
        let result = resume_session_with_password(
            user_id.to_string(),
            "wrong-password".into(),
            key.clone(),
            false,
            false,
        )
        .await
        .unwrap();
        assert!(!result.success);
        assert!(SESSION_RELOGIN.read().await.is_some());
        assert!(ACTIVE_USER.read().await.is_none());
    }
    for (returned_user, returned_device) in [
        (
            user_id.clone(),
            matrix_sdk::ruma::owned_device_id!("WRONG_DEVICE"),
        ),
        (
            matrix_sdk::ruma::owned_user_id!("@bob:example.org"),
            device_id.clone(),
        ),
    ] {
        let _scope = server
            .mock_login()
            .ok_with(LoginResponseTemplate200::new(
                "new-access",
                returned_device,
                returned_user,
            ))
            .expect(1)
            .mount_as_scoped()
            .await;
        let error = resume_session_with_password(
            user_id.to_string(),
            "password".into(),
            key.clone(),
            false,
            false,
        )
        .await
        .unwrap_err();
        assert!(error.contains("与原会话不一致"));
        assert!(SESSION_RELOGIN.read().await.is_some());
        assert!(ACTIVE_USER.read().await.is_none());
    }
    server
        .mock_login()
        .ok_with(
            LoginResponseTemplate200::new("new-access", device_id.clone(), user_id.clone())
                .refresh_token("new-refresh"),
        )
        .expect(1)
        .mount()
        .await;
    let resumed =
        resume_session_with_password(user_id.to_string(), "password".into(), key, false, false)
            .await
            .unwrap();
    assert!(
        resumed.success,
        "reauthentication failed: {:?}",
        resumed.error
    );
    let requests = server.received_requests().await.unwrap();
    let login_requests: Vec<_> = requests
        .iter()
        .filter(|request| request.url.path().ends_with("/login"))
        .collect();
    assert_eq!(login_requests.len(), 4);
    for request in login_requests {
        let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
        assert_eq!(body["device_id"], device_id.as_str());
        assert_eq!(body["identifier"]["user"], user_id.as_str());
        assert_eq!(body["refresh_token"], true);
    }
    let client = get_client().await.unwrap();
    let new_fingerprint = client.encryption().ed25519_key().await.unwrap();
    let new_secrets = client
        .olm_machine_for_testing()
        .await
        .as_ref()
        .unwrap()
        .export_cross_signing_keys()
        .await
        .unwrap()
        .unwrap();
    let restored_session = client.matrix_auth().session().unwrap();
    drop(client);
    {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        *ACTIVE_USER.write().await = previous_active;
        let entry = CLIENTS.write().await.remove(user_id.as_str()).unwrap();
        let (client, _) = entry.into_client_and_data_dir().await;
        drop(client);
        if let Some(previous_entry) = previous_entry {
            CLIENTS
                .write()
                .await
                .insert(user_id.to_string(), previous_entry);
        }
        reset_connection_status();
        *SESSION_RELOGIN.write().await = None;
        set_subscription_user(None).await;
    }
    assert!(resumed.success);
    assert_eq!(restored_session.meta.device_id, device_id);
    assert_eq!(restored_session.tokens.access_token, "new-access");
    assert_eq!(
        restored_session.tokens.refresh_token.as_deref(),
        Some("new-refresh")
    );
    assert_eq!(fingerprint, new_fingerprint);
    assert!(
        secrets.master_key == new_secrets.master_key
            && secrets.self_signing_key == new_secrets.self_signing_key
            && secrets.user_signing_key == new_secrets.user_signing_key
    );
    assert_eq!(tokio::fs::read(&marker).await.unwrap(), b"preserve cache");
    tokio::fs::remove_dir_all(data_dir).await.unwrap();
    server.verify_and_reset().await;
}

#[tokio::test]
async fn profile_authentication_failure_is_sticky_and_blocks_sync_restart() {
    let _test_lock = ACCOUNT_API_TEST_LOCK.lock().await;
    let server = MatrixMockServer::new().await;
    let client = server.client_builder().build().await;
    let user_id = client.user_id().unwrap().to_owned();
    let data_dir = std::env::temp_dir().join(format!(
        "matter-relogin-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    tokio::fs::create_dir_all(&data_dir).await.unwrap();
    let marker = data_dir.join("cached-session-data");
    tokio::fs::write(&marker, b"preserve cache").await.unwrap();
    let (previous_active, previous_entry, previous_status) = {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        let active = ACTIVE_USER.write().await.replace(user_id.to_string());
        let entry = CLIENTS.write().await.insert(
            user_id.to_string(),
            ClientEntry {
                client,
                data_dir: data_dir.to_string_lossy().to_string(),
                search_index_dir: std::path::PathBuf::new(),
                instance_id: u64::MAX,
                room_key_task: tokio::spawn(std::future::pending()),
            },
        );
        (active, entry, get_connection_status())
    };
    reset_connection_status();
    let valid_session_error = prepare_session_relogin(user_id.to_string())
        .await
        .unwrap_err();
    let wrong_account_error = prepare_session_relogin("@wrong:example.org".into())
        .await
        .unwrap_err();
    let mut results = Vec::new();
    for field in [ProfileFieldName::DisplayName, ProfileFieldName::AvatarUrl] {
        reset_connection_status();
        if field == ProfileFieldName::AvatarUrl {
            server
                .mock_get_profile_field(&user_id, ProfileFieldName::DisplayName)
                .ok_with_value(Some(serde_json::json!("Alice")))
                .expect(1)
                .mount()
                .await;
        }
        server
            .mock_get_profile_field(&user_id, field)
            .error_unknown_token(false)
            .expect(1)
            .mount()
            .await;
        let profile_error = get_profile().await.unwrap_err();
        set_connection_status_for_generation(
            SYNC_GENERATION.load(Ordering::SeqCst),
            ConnectionStatus::Connected,
        );
        let status = get_connection_status();
        let sync_error = sync_once().await.unwrap_err();
        let restart_error = start_sync().await.unwrap_err();
        results.push((profile_error, status, sync_error, restart_error));
        server.verify_and_reset().await;
    }
    let prepared = prepare_session_relogin(user_id.to_string()).await;
    let resume_error = resume_session_with_password(
        user_id.to_string(),
        "password".into(),
        String::new(),
        false,
        true,
    )
    .await
    .unwrap_err();
    let active_cleared = ACTIVE_USER.read().await.is_none();
    let client_removed = !CLIENTS.read().await.contains_key(user_id.as_str());
    let cache = tokio::fs::read(&marker).await.unwrap();
    {
        let _lifecycle = SYNC_LIFECYCLE.write().await;
        *ACTIVE_USER.write().await = previous_active;
        if let Some(entry) = CLIENTS.write().await.remove(user_id.as_str()) {
            entry.room_key_task.abort();
        }
        if let Some(previous_entry) = previous_entry {
            CLIENTS
                .write()
                .await
                .insert(user_id.to_string(), previous_entry);
        }
        *CONNECTION_STATE.write().unwrap() = previous_status;
    }
    tokio::fs::remove_dir_all(&data_dir).await.unwrap();
    assert!(valid_session_error.contains("尚未失效"));
    assert!(wrong_account_error.contains("当前账号已切换"));
    assert!(!prepared.unwrap());
    assert!(resume_error.contains("没有可恢复的设备会话"));
    assert!(active_cleared && client_removed);
    assert_eq!(cache, b"preserve cache");
    for (profile_error, status, sync_error, restart_error) in results {
        assert!(profile_error.contains("M_UNKNOWN_TOKEN"));
        assert!(matches!(status, ConnectionStatus::SessionExpired));
        assert_eq!(sync_error, "登录已失效，请重新登录");
        assert_eq!(restart_error, "登录已失效，请重新登录");
    }
}
