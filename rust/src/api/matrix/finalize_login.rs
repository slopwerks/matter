//! Finalize login implementation.

use super::*;

/// After a successful auth on the pending client, migrate it to a per-user store.
pub(super) async fn finalize_pending() -> Result<String, String> {
    enum FinalizeStart {
        Duplicate {
            pending_client: Client,
            user_id: String,
            access_token: String,
            homeserver_url: String,
        },
        New {
            pending_client: Client,
            data_dir: String,
            homeserver_url: String,
            search_index_key: String,
            user_id: String,
            matrix_session: MatrixSession,
        },
    }

    // Phase 1: inspect the pending client and global state under the lifecycle
    // write lock. For a duplicate login we clear PENDING immediately so no other
    // call can use this pending client while we perform the remote logout
    // outside the lock.
    let start = {
        let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
        let (pending_client, data_dir, homeserver_url, search_index_key, user_id, matrix_session) = {
            let pending = PENDING.read().await;
            let p = pending.as_ref().ok_or("No pending client to finalize")?;
            let client = p.client.clone();
            let auth = client.matrix_auth();
            if !auth.logged_in() {
                return Err("Pending client is not logged in".into());
            }
            let session = auth.session().ok_or("No session in pending client")?;
            let user_id = session.meta.user_id.to_string();
            let matrix_session = MatrixSession {
                meta: SessionMeta {
                    user_id: session.meta.user_id.clone(),
                    device_id: session.meta.device_id.clone(),
                },
                tokens: SessionTokens {
                    access_token: session.tokens.access_token.clone(),
                    refresh_token: session.tokens.refresh_token.clone(),
                },
            };
            drop(auth);
            (
                client,
                p.data_dir.clone(),
                p.homeserver_url.clone(),
                p.search_index_key.clone(),
                user_id,
                matrix_session,
            )
        };

        app_log(
            "info",
            "auth",
            format!("finalize_pending: starting for user {}", user_id),
        );
        info!("finalize_pending: starting for user {}", user_id);

        if CLIENTS.read().await.contains_key(&user_id) {
            {
                let mut pending = PENDING.write().await;
                *pending = None;
            }
            FinalizeStart::Duplicate {
                pending_client,
                user_id,
                access_token: matrix_session.tokens.access_token,
                homeserver_url,
            }
        } else {
            FinalizeStart::New {
                pending_client,
                data_dir,
                homeserver_url,
                search_index_key,
                user_id,
                matrix_session,
            }
        }
    };

    match start {
        FinalizeStart::Duplicate {
            pending_client,
            user_id,
            access_token,
            homeserver_url,
        } => {
            // Remote logout is performed outside the lifecycle lock so an
            // unreachable server does not block every API call.
            if pending_client.matrix_auth().logged_in() {
                match tokio::time::timeout(
                    std::time::Duration::from_secs(15),
                    pending_client.matrix_auth().logout(),
                )
                .await
                {
                    Ok(Ok(_)) => {}
                    Ok(Err(e)) => {
                        PENDING_REMOTE_LOGOUTS.write().await.insert(
                            user_id.clone(),
                            (access_token.clone(), homeserver_url.clone()),
                        );
                        app_log(
                            "warn",
                            "auth",
                            format!(
                                "Remote logout of duplicate pending session failed for {user_id}: {e}"
                            ),
                        );
                        warn!(
                            "Remote logout of duplicate pending session failed for {user_id}: {e}"
                        );
                    }
                    Err(_) => {
                        PENDING_REMOTE_LOGOUTS
                            .write()
                            .await
                            .insert(user_id.clone(), (access_token, homeserver_url));
                        app_log(
                            "warn",
                            "auth",
                            format!(
                                "Remote logout of duplicate pending session timed out for {user_id}"
                            ),
                        );
                        warn!("Remote logout of duplicate pending session timed out for {user_id}");
                    }
                }
            }
            drop(pending_client);
            Err("This account is already signed in.".to_string())
        }
        FinalizeStart::New {
            pending_client,
            data_dir,
            homeserver_url,
            search_index_key,
            user_id,
            matrix_session,
        } => {
            // Phase 2: under lock, stop sync, clear runtime state, and migrate
            // the pending store into the per-user directory. File migration
            // stays under the lock so a concurrent create_client cannot delete
            // the pending directory while we are moving it.
            let (sdk_dir, search_index_dir, had_previous_store, previous_dir) = {
                let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
                // Defensive re-check: another restore may have installed this
                // account while we were not holding the lock.
                if CLIENTS.read().await.contains_key(&user_id) {
                    {
                        let mut pending = PENDING.write().await;
                        *pending = None;
                    }
                    drop(pending_client);
                    return Err("This account is already signed in.".to_string());
                }
                stop_sync_task(Some(&user_id), false).await;
                clear_account_runtime_state(&user_id).await;

                let sdk_dir = build_sdk_data_dir(&data_dir, Some(&user_id));
                let temp_dir = build_sdk_data_dir(&data_dir, None);
                {
                    let mut pending = PENDING.write().await;
                    *pending = None;
                }
                drop(pending_client);
                // The pending client's SQLite stores are released asynchronously
                // by matrix-sdk's internal deadpool: `Object::drop` returns the
                // connection to the pool rather than closing it, and the pool
                // only releases the underlying file handle when the last
                // connection is dropped. On Windows the rename below can therefore
                // race the still-open handles and fail with `AccessDenied`
                // (os error 5). Retry with bounded backoff instead of sleeping a
                // fixed duration: most attempts succeed on the first try, while
                // slow machines and antivirus scans get enough headroom without
                // a hard 100 ms penalty on the happy path.

                remove_legacy_plaintext_search_index(&sdk_dir).await?;
                remove_legacy_plaintext_search_index(&temp_dir).await?;
                let accounts_dir = sdk_dir
                    .parent()
                    .ok_or_else(|| "Invalid account store path".to_string())?;
                tokio::fs::create_dir_all(accounts_dir)
                    .await
                    .map_err(|e| format!("Failed to create accounts directory: {e}"))?;
                let previous_dir = sdk_dir.with_extension("previous");
                remove_dir_all_if_exists(&previous_dir)
                    .await
                    .map_err(|e| format!("Failed to remove stale account store backup: {e}"))?;
                let had_previous_store = sdk_dir.exists();
                if had_previous_store {
                    if let Err(error) = rename_with_retry(
                        &sdk_dir,
                        &previous_dir,
                        6,
                        std::time::Duration::from_millis(50),
                    )
                    .await
                    {
                        return Err(format!(
                            "Failed to preserve existing account store: {error}"
                        ));
                    }
                }
                if let Err(error) =
                    rename_with_retry(&temp_dir, &sdk_dir, 6, std::time::Duration::from_millis(50))
                        .await
                {
                    if had_previous_store {
                        let _ = tokio::fs::rename(&previous_dir, &sdk_dir).await;
                    }
                    return Err(format!("Failed to migrate encryption store: {error}"));
                }
                let search_index_dir = match prepare_encrypted_search_index(&sdk_dir, true).await {
                    Ok(path) => path,
                    Err(error) => {
                        let _ = remove_dir_all_if_exists(&sdk_dir).await;
                        if had_previous_store {
                            let _ = tokio::fs::rename(&previous_dir, &sdk_dir).await;
                        }
                        return Err(error);
                    }
                };
                (sdk_dir, search_index_dir, had_previous_store, previous_dir)
            };

            // Phase 3: build the per-user client and restore the session outside
            // the lifecycle lock so long-running work does not block other API
            // calls.
            let url = url::Url::parse(&homeserver_url).map_err(|e| format!("Invalid URL: {e}"))?;
            app_log(
                "info",
                "auth",
                format!("finalize_pending: creating client in {}", sdk_dir.display()),
            );
            info!("finalize_pending: creating client in {}", sdk_dir.display());
            let new_client = match matrix_client_builder()?
                .handle_refresh_tokens()
                .homeserver_url(url)
                .with_encryption_settings(encryption_settings())
                .request_config(bounded_request_config())
                .search_index_store(
                    matrix_sdk::search_index::SearchIndexStoreKind::EncryptedDirectory(
                        search_index_dir.clone(),
                        search_index_key,
                    ),
                )
                .sqlite_store(&sdk_dir, None)
                .build()
                .await
            {
                Ok(client) => client,
                Err(error) => {
                    let _ = remove_dir_all_if_exists(&sdk_dir).await;
                    if had_previous_store {
                        let _ = tokio::fs::rename(&previous_dir, &sdk_dir).await;
                    }
                    return Err(format!("Failed to create per-user client: {error}"));
                }
            };
            install_session_token_callback(&new_client)?;

            app_log(
                "info",
                "auth",
                format!("finalize_pending: restoring session for {}", user_id),
            );
            info!("finalize_pending: restoring session for {}", user_id);
            if let Err(error) = new_client
                .matrix_auth()
                .restore_session(matrix_session, RoomLoadSettings::default())
                .await
            {
                drop(new_client);
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                let _ = remove_dir_all_if_exists(&sdk_dir).await;
                if had_previous_store {
                    let _ = tokio::fs::rename(&previous_dir, &sdk_dir).await;
                }
                return Err(format!("Restore session in per-user store: {error}"));
            }
            if had_previous_store {
                if let Err(error) = remove_dir_all_if_exists(&previous_dir).await {
                    warn!("Failed to remove previous account store: {error}");
                }
            }
            wait_for_e2ee_initialization(&new_client, "login finalization").await;
            app_log(
                "info",
                "auth",
                format!("finalize_pending: session restored for {}", user_id),
            );
            info!("finalize_pending: session restored for {}", user_id);
            let instance_id = NEXT_CLIENT_INSTANCE_ID.fetch_add(1, Ordering::Relaxed);
            let identity = ClientIdentity {
                user_id: user_id.clone(),
                instance_id,
            };
            install_verification_event_handler(&new_client, identity.clone());
            install_live_update_event_handlers(&new_client, identity.clone());
            desktop_notifications::install(&new_client, identity.clone()).await;
            let room_key_task = install_room_key_event_handler(&new_client, identity);

            // Phase 4: reacquire the lock and install the finalized client.
            {
                let _sync_lifecycle = SYNC_LIFECYCLE.write().await;
                // If another lifecycle transition installed this account or a
                // new pending client in the meantime, drop our work and let the
                // winner stand. We only clean up the store if no other client
                // owns it.
                let client_present = CLIENTS.read().await.contains_key(&user_id);
                if PENDING.read().await.is_some() || client_present {
                    drop(new_client);
                    if !client_present {
                        let _ = remove_dir_all_if_exists(&sdk_dir).await;
                        if had_previous_store {
                            let _ = tokio::fs::rename(&previous_dir, &sdk_dir).await;
                        }
                    }
                    return Err("Account state changed during finalization".to_string());
                }

                // Stop event publication before replacing the client entry.
                // This orders callbacks from the old instance before the
                // identity swap.
                set_subscription_user(None).await;
                stop_sync_task(None, false).await;
                // A previous logout of this account may have failed to reach
                // the server (dead network): its old token may still be valid
                // there — retry the remote logout best-effort (fire-and-forget)
                // with this client's transport.
                retry_pending_remote_logout(&user_id, &new_client).await;
                {
                    let mut clients = CLIENTS.write().await;
                    clients.insert(
                        user_id.clone(),
                        ClientEntry {
                            client: new_client,
                            data_dir: data_dir.clone(),
                            search_index_dir,
                            instance_id,
                            room_key_task,
                        },
                    );
                }

                // Invalidate builders on both sides of the active-account write.
                {
                    let mut active = ACTIVE_USER.write().await;
                    *active = Some(user_id.clone());
                }
                stop_sync_task(None, false).await;
                *SESSION_RELOGIN.write().await = None;
                reset_connection_status();
                set_subscription_user(Some(user_id.clone())).await;
            }

            app_log("info", "auth", format!("Account finalized: {}", user_id));
            info!("Account finalized: {}", user_id);
            Ok(user_id)
        }
    }
}
