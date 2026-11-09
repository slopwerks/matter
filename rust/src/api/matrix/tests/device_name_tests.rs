use super::device_name_for_platform;

#[test]
fn names_known_platforms() {
    assert_eq!(device_name_for_platform("android"), "Matter Android");
    assert_eq!(device_name_for_platform("ios"), "Matter iOS");
    assert_eq!(device_name_for_platform("linux"), "Matter Linux");
    assert_eq!(device_name_for_platform("macos"), "Matter macOS");
    assert_eq!(device_name_for_platform("windows"), "Matter Windows");
}

#[test]
fn passes_unknown_platforms_through() {
    assert_eq!(device_name_for_platform("freebsd"), "Matter freebsd");
}
