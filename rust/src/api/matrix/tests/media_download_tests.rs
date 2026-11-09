use super::{
    append_media_chunk, ensure_media_content_length, media_download_limit, media_download_url,
    truncate_utf8,
};
use matrix_sdk::Client;

#[test]
fn media_download_limit_rejects_non_positive_values() {
    assert!(media_download_limit(0).is_err());
    assert!(media_download_limit(-1).is_err());
    assert_eq!(media_download_limit(1024), Ok(1024));
}

#[test]
fn media_download_refuses_oversized_headers_and_streams() {
    assert!(ensure_media_content_length(Some(9), 8).is_err());
    assert!(ensure_media_content_length(None, 8).is_ok());

    let mut content = vec![1, 2, 3];
    assert!(append_media_chunk(&mut content, &[4, 5], 4).is_err());
    assert_eq!(content, [1, 2, 3]);
    assert!(append_media_chunk(&mut content, &[4], 4).is_ok());
    assert_eq!(content, [1, 2, 3, 4]);
}

#[test]
fn log_truncation_preserves_utf8_boundaries() {
    let value = format!("{}界", "a".repeat(299));
    assert_eq!(truncate_utf8(&value, 300), "a".repeat(299));
    assert_eq!(truncate_utf8("中文", 500), "中文");
}

#[tokio::test]
async fn media_download_url_uses_the_homeserver_and_mxc_port() {
    let client = Client::new(url::Url::parse("https://matrix.example/").unwrap())
        .await
        .unwrap();
    let source = serde_json::from_str(r#"{"url":"mxc://media.example:8448/media-id"}"#).unwrap();

    let url = media_download_url(&client, &source).unwrap();

    assert_eq!(
        url.as_str(),
        "https://matrix.example/_matrix/client/v1/media/download/media.example:8448/media-id"
    );
}

#[tokio::test]
async fn media_download_url_preserves_the_homeserver_path_prefix() {
    let client = Client::new(url::Url::parse("https://example.org/matrix/").unwrap())
        .await
        .unwrap();
    let source = serde_json::from_str(r#"{"url":"mxc://media.example/media-id"}"#).unwrap();

    let url = media_download_url(&client, &source).unwrap();

    assert_eq!(
        url.as_str(),
        "https://example.org/matrix/_matrix/client/v1/media/download/media.example/media-id"
    );
}
