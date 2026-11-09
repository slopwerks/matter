use super::remote_logout_retry_settles;

#[test]
fn only_success_retries_settle_the_pending_entry() {
    // 2xx: the retry itself revoked the old session — settle.
    assert!(remote_logout_retry_settles(200));
    assert!(remote_logout_retry_settles(204));
    // 401: with refresh tokens enabled the stored access token can
    // expire on its own, so the session may still be alive — the entry
    // must survive for a later retry.
    assert!(!remote_logout_retry_settles(401));
    // Other server errors keep the entry too.
    assert!(!remote_logout_retry_settles(500));
    assert!(!remote_logout_retry_settles(429));
}
