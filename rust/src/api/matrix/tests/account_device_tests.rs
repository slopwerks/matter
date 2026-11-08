use super::{sort_account_devices, AccountDevice};

fn device(device_id: &str, is_current: bool, last_seen_ts: Option<i64>) -> AccountDevice {
    AccountDevice {
        device_id: device_id.to_owned(),
        display_name: None,
        last_seen_ip: None,
        last_seen_ts,
        is_current,
    }
}

fn order(devices: &[AccountDevice]) -> Vec<&str> {
    devices
        .iter()
        .map(|device| device.device_id.as_str())
        .collect()
}

#[test]
fn current_device_comes_first_then_recent_activity() {
    let mut devices = vec![
        device("OLD", false, Some(100)),
        device("NEW", false, Some(300)),
        device("CURRENT", true, Some(1)),
    ];
    sort_account_devices(&mut devices);
    assert_eq!(order(&devices), ["CURRENT", "NEW", "OLD"]);
}

#[test]
fn sessions_without_activity_sort_last() {
    let mut devices = vec![device("NEVER", false, None), device("SEEN", false, Some(5))];
    sort_account_devices(&mut devices);
    assert_eq!(order(&devices), ["SEEN", "NEVER"]);
}
