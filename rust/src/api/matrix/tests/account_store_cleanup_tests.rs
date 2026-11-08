use super::{
    build_sdk_data_dir, cleanup_removed_account_store, prepare_encrypted_search_index,
    remove_legacy_plaintext_search_index, ENCRYPTED_SEARCH_INDEX_MARKER,
};

#[tokio::test]
async fn removed_account_store_cleanup_is_idempotent() {
    let data_dir = std::env::temp_dir().join(format!(
        "matter-removed-account-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let user_id = "@removed:example.org";
    let sdk_dir = build_sdk_data_dir(data_dir.to_str().unwrap(), Some(user_id));
    tokio::fs::create_dir_all(&sdk_dir).await.unwrap();
    tokio::fs::write(sdk_dir.join("store.db"), b"stale credentials")
        .await
        .unwrap();

    cleanup_removed_account_store(user_id.to_string(), data_dir.to_str().unwrap().to_string())
        .await
        .unwrap();
    assert!(!sdk_dir.exists());

    cleanup_removed_account_store(user_id.to_string(), data_dir.to_str().unwrap().to_string())
        .await
        .unwrap();
    let _ = tokio::fs::remove_dir_all(data_dir).await;
}

#[tokio::test]
async fn legacy_plaintext_index_cleanup_is_required_and_idempotent() {
    let data_dir = std::env::temp_dir().join(format!(
        "matter-search-cleanup-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let index_dir = data_dir.join("search_index");
    tokio::fs::create_dir_all(&index_dir).await.unwrap();
    tokio::fs::write(index_dir.join("plaintext"), b"secret")
        .await
        .unwrap();

    remove_legacy_plaintext_search_index(&data_dir)
        .await
        .unwrap();
    assert!(!index_dir.exists());
    remove_legacy_plaintext_search_index(&data_dir)
        .await
        .unwrap();

    tokio::fs::remove_dir_all(&data_dir).await.unwrap();
    tokio::fs::write(&data_dir, b"not a directory")
        .await
        .unwrap();
    assert!(remove_legacy_plaintext_search_index(&data_dir)
        .await
        .is_err());
    let _ = tokio::fs::remove_file(data_dir).await;
}

#[tokio::test]
async fn encrypted_search_index_survives_restore_and_resets_with_a_new_key() {
    let data_dir = std::env::temp_dir().join(format!(
        "matter-encrypted-search-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let index_dir = prepare_encrypted_search_index(&data_dir, false)
        .await
        .unwrap();
    let indexed_data = index_dir.join("room-segment");
    tokio::fs::write(&indexed_data, b"encrypted data")
        .await
        .unwrap();

    prepare_encrypted_search_index(&data_dir, false)
        .await
        .unwrap();
    assert!(indexed_data.exists());
    assert!(index_dir.join(ENCRYPTED_SEARCH_INDEX_MARKER).exists());

    prepare_encrypted_search_index(&data_dir, true)
        .await
        .unwrap();
    assert!(!indexed_data.exists());
    assert!(index_dir.join(ENCRYPTED_SEARCH_INDEX_MARKER).exists());
    let _ = tokio::fs::remove_dir_all(data_dir).await;
}

#[tokio::test]
async fn encrypted_search_index_refuses_to_delete_when_marker_is_missing_but_key_exists() {
    let data_dir = std::env::temp_dir().join(format!(
        "matter-encrypted-search-missing-marker-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let index_dir = data_dir.join("search_index");
    tokio::fs::create_dir_all(&index_dir).await.unwrap();
    tokio::fs::write(index_dir.join("seshat-index.key"), b"key-material")
        .await
        .unwrap();
    tokio::fs::write(index_dir.join("room-segment"), b"encrypted data")
        .await
        .unwrap();

    assert!(prepare_encrypted_search_index(&data_dir, false)
        .await
        .is_err());
    assert!(index_dir.join("seshat-index.key").exists());
    assert!(index_dir.join("room-segment").exists());

    // Explicit reset still works.
    prepare_encrypted_search_index(&data_dir, true)
        .await
        .unwrap();
    assert!(!index_dir.join("seshat-index.key").exists());
    assert!(!index_dir.join("room-segment").exists());
    assert!(index_dir.join(ENCRYPTED_SEARCH_INDEX_MARKER).exists());
    let _ = tokio::fs::remove_dir_all(data_dir).await;
}
