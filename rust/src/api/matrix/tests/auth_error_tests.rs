use super::friendly_auth_error;

#[test]
fn password_login_errors_do_not_expose_server_response_text() {
    let raw = "[403 / M_FORBIDDEN] password was secret-value";
    let safe = friendly_auth_error(raw, "登录失败，请稍后重试");

    assert_eq!(safe, "认证失败，请检查账号、密码或 Token");
    assert!(!safe.contains("secret-value"));
}
