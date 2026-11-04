use super::*;
use matrix_sdk_base::crypto::AttachmentEncryptor;
use std::io::{Seek, SeekFrom};

fn fixture(parent: &Path, size: u64) -> (NamedTempFile, MediaSource) {
    let mut plaintext = std::io::repeat(0x5a).take(size);
    let mut encryptor = AttachmentEncryptor::new(&mut plaintext);
    let mut encrypted = NamedTempFile::new_in(parent).unwrap();
    std::io::copy(&mut encryptor, &mut encrypted).unwrap();
    encrypted.flush().unwrap();
    let mut metadata = serde_json::to_value(encryptor.finish()).unwrap();
    metadata["url"] = "mxc://example.org/media".into();
    let source = serde_json::from_value(serde_json::json!({"file": metadata})).unwrap();
    assert!(matches!(source, MediaSource::Encrypted(_)));
    (encrypted, source)
}

#[test]
fn decrypts_more_than_16_mb_in_files_and_deletes_ciphertext() {
    let directory = tempfile::tempdir().unwrap();
    let size = 17 * 1024 * 1024 + 13;
    let (encrypted, source) = fixture(directory.path(), size);
    let encrypted_path = encrypted.path().to_owned();
    let transfer = MediaTransfer::new();
    let mut output = decrypt_file(
        encrypted,
        source,
        transfer.cancelled,
        Instant::now() + TRANSFER_TIMEOUT,
    )
    .unwrap();
    assert!(!encrypted_path.exists());
    assert_eq!(output.as_file().metadata().unwrap().len(), size);
    output.seek(SeekFrom::Start(0)).unwrap();
    let mut chunk = [0; COPY_BUFFER_SIZE];
    loop {
        let size = output.read(&mut chunk).unwrap();
        if size == 0 {
            break;
        }
        assert!(chunk[..size].iter().all(|byte| *byte == 0x5a));
    }
    drop(output);
    assert_eq!(directory.path().read_dir().unwrap().count(), 0);
}

#[test]
fn refuses_tampering_and_truncation_without_leaving_plaintext() {
    let directory = tempfile::tempdir().unwrap();
    for truncate in [false, true] {
        let (mut encrypted, source) = fixture(directory.path(), 128 * 1024);
        if truncate {
            encrypted.as_file().set_len(1024).unwrap();
        } else {
            encrypted.seek(SeekFrom::Start(0)).unwrap();
            let mut byte = [0];
            encrypted.read_exact(&mut byte).unwrap();
            encrypted.seek(SeekFrom::Start(0)).unwrap();
            encrypted.write_all(&[byte[0] ^ 0xff]).unwrap();
            encrypted.flush().unwrap();
        }
        let result = decrypt_file(
            encrypted,
            source,
            MediaTransfer::new().cancelled,
            Instant::now() + TRANSFER_TIMEOUT,
        );
        assert!(result.unwrap_err().contains("Hash mismatch"));
        assert_eq!(directory.path().read_dir().unwrap().count(), 0);
    }
}

#[test]
fn refuses_missing_hash_and_unknown_version() {
    let directory = tempfile::tempdir().unwrap();
    for invalid_version in [false, true] {
        let (encrypted, source) = fixture(directory.path(), 8);
        let mut json = serde_json::to_value(source).unwrap();
        if invalid_version {
            json["file"]["v"] = "v99".into();
        } else {
            json["file"]["hashes"] = serde_json::json!({});
        }
        let result = match serde_json::from_value(json) {
            Ok(source) => decrypt_file(
                encrypted,
                source,
                MediaTransfer::new().cancelled,
                Instant::now() + TRANSFER_TIMEOUT,
            ),
            Err(_) => {
                drop(encrypted);
                Err("invalid metadata".to_string())
            }
        };
        assert!(result.is_err());
        assert_eq!(directory.path().read_dir().unwrap().count(), 0);
    }
}

#[test]
fn cancellation_and_deadline_remove_all_temporary_files() {
    let directory = tempfile::tempdir().unwrap();
    for cancel in [false, true] {
        let (encrypted, source) = fixture(directory.path(), 128 * 1024);
        let transfer = MediaTransfer::new();
        if cancel {
            transfer.cancel();
        }
        let deadline = if cancel {
            Instant::now() + TRANSFER_TIMEOUT
        } else {
            Instant::now()
        };
        assert!(decrypt_file(encrypted, source, transfer.cancelled, deadline).is_err());
        assert_eq!(directory.path().read_dir().unwrap().count(), 0);
    }
}

#[tokio::test]
async fn cancellation_before_start_does_not_require_an_account_or_create_files() {
    let transfer = MediaTransfer::new();
    transfer.cancel();
    let error = download_media_source_to_file(
        &transfer,
        "invalid".into(),
        "@a:example.org".into(),
        "unused".into(),
    )
    .await
    .unwrap_err();
    assert!(error.contains("cancelled"));
}
