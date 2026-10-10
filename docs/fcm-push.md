# Push notifications

[中文文档](fcm-push.zh-CN.md)

Push is disabled by default. Matter ships no push gateway and no Firebase project. The two transport paths are Web Push with VAPID in browsers and FCM on Android. The settings page shows both and permits only the one supported by the current platform. ntfy, direct APNs, iOS and desktop push are not implemented yet.

## Account notification preferences

Settings → Notifications opens on the account preferences. The device-related "Push service and gateway" section is collapsed at the bottom of the page.

Preferences are Matrix push rules stored on the homeserver, so they also apply to the other devices on the same account. FCM, the gateway and the system permission are configured separately. A platform without system push can still manage these preferences.

The available settings are mute everything, filtering `m.notice` notifications, filtering edits, and choosing all messages or mentions only for direct chats and group chats, separately for plain and encrypted rooms. A mention covers a direct mention, a room-wide mention, and content matching the display name, user ID or the legacy `@room` form. The remaining categories have individual switches: room invites, call invites, membership changes, reactions, room upgrades, poll starts, ends and responses, and thread notifications. Keywords can be added and removed, and support the Matrix `*` and `?` wildcards. An entry with no matching rule on the server is shown as unsupported and cannot be operated.

Mute everything keeps the other preferences. They remain editable while muted, and the adjusted settings take effect once mute is turned off. Turning off one event category keeps its match rule and clears only the notify action, so such events no longer fall through to the catch-all message rule. Filtering notices and edits adjusts the suppress rule instead.

The page reads server state directly. A change is displayed immediately and saved automatically, and only the entry being saved is temporarily disabled. If a save fails, the page re-reads that entry and shows an error at the bottom; a refresh or retry is also available. Rooms configured individually remain under their room rule, and mute everything takes precedence over those settings.

`m.notice` is a message type and cannot cover every bot account. Encrypted events are unreadable on the server, so mentions, keywords and message-type filters can only be exact after a client decrypts, and background push does not decrypt. The call switch controls Matrix call invite notifications only, and changes neither the calling feature nor the system ringtone.

## Importing your own Firebase config (Android)

A single APK can serve users with different Firebase projects, with no rebuild. In Settings → Notifications, expand "Push service and gateway" at the bottom and tap "Import google-services.json", then select the Android client config downloaded from the Firebase console. The file must contain a client for the package `moe.aks.matter`; if not, add that Android app to the Firebase project first.

Matter takes the API key, Firebase App ID, project number (Sender ID) and Project ID of the matching client, and stores only these public client parameters. When a file contains several Android clients, selection is by package name. A wrong package, a missing parameter, mismatched numbers or a service account file are all rejected. The gateway's service account private key remains on the server only.

The imported config is shared by every account on the installation. Before switching to another config, Matter closes and unregisters the FCM pusher of every account, revokes the old FCM token, and only then saves the new config. If unregistering fails, the new project is not saved and the accounts already closed keep a cleanup record for a later retry. After saving, **force-stop Matter in the Android app settings and open it again**, so the default Firebase SDK instance and the background process start from the new config; enable push per account afterwards. Leaving the page or swiping the task away does not guarantee that the Android process has ended.

An imported config takes precedence over the prefill of a private build. At startup, the Android Application reads the saved config before any foreground page or background FCM service runs, and build resources are used only when nothing was imported. The gateway URL and the Matrix app ID are still edited per account under "Push service and gateway", and must correspond to the gateway of the selected Firebase project.

## Optional build-time prefill

A builder can inject public client config through `--dart-define-from-file` with a config file at `.env.push-client.json`, which Git ignores:

```json
{
  "MATTER_PUSH_GATEWAY": "https://push.example.org/_matrix/push/v1/notify",
  "MATTER_PUSH_ANDROID_APP_ID": "matter.android",
  "MATTER_PUSH_WEB_APP_ID": "matter.web",
  "MATTER_PUSH_VAPID_PUBLIC_KEY": "",
  "MATTER_FIREBASE_API_KEY": "",
  "MATTER_FIREBASE_APP_ID": "",
  "MATTER_FIREBASE_SENDER_ID": "",
  "MATTER_FIREBASE_PROJECT_ID": ""
}
```

The four Firebase fields are optional prefill, taken from `current_key`, `mobilesdk_app_id`, `project_number` and `project_id` in the Firebase Android client config, and the Android package must be `moe.aks.matter`. The build writes the options into Dart and into Android native resources, and an imported config overrides these defaults. An APK builds without them, leaving users to import later; the repository does not need to track `google-services.json` or `firebase_options.dart`.

```sh
flutter build apk --dart-define-from-file=.env.push-client.json
```

A Web build needs the gateway URL, the Matrix Web app ID and the gateway's VAPID public key, and no Firebase client config:

```sh
flutter build web --dart-define-from-file=.env.push-client.json
```

**Web runtime limit:** the command above produces the Flutter frontend, but the native Rust core in this repository does not yet provide the `pkg/rust_lib_matter` WASM artifact required by the browser bridge. The app needs it in `RustLib.init()`, so the generated `build/web` cannot yet be deployed as a complete chat client. The Web Push subscription bridge, the service worker, the registration parameters and click routing are implemented and tested separately; a complete Web client first needs Web build and runtime support in the Rust core. SQLite, search and the native sync runtime were not ported in this push work.

Client config and the VAPID public key end up in the build output. Firebase service-account credentials and the VAPID private key belong on the gateway only, and must not be added to a client or to Git.

## Gateway

The homeserver sends a standard Matrix HTTP push request to `MATTER_PUSH_GATEWAY`. The address must be an HTTPS URL reachable from the homeserver, with a path ending in `/_matrix/push/v1/notify`; `127.0.0.1` is not an address a remote homeserver can use.

Android can use [Sygnal](https://github.com/matrix-org/sygnal) with FCM HTTP v1 support, with an app entry such as:

```yaml
apps:
  matter.android:
    type: gcm
    api_version: v1
    project_id: your-firebase-project
    service_account_file: /run/secrets/fcm-service-account.json
```

The Matrix app ID is the key under `apps` in the gateway config, and differs from the Android package name or the Firebase `1:…:android:…` ID. The gateway's service account must be allowed to send to the Firebase project the user currently selected. Since there is no fixed official Firebase project, a user can import the client config of a personal project into the same APK.

An FCM gateway should send a high-priority **data message** and add no FCM `notification` field: a notification displayed by the system bypasses the client's disabled and account-removed checks.

A Web gateway must support Web Push/VAPID. The client passes `endpoint`, `p256dh` and `auth` in the Matrix pusher `data`, and uses the subscription `p256dh` as `pushkey`. Confirm that the Sygnal version in use or another gateway supports this mode; an FCM app entry cannot receive a browser subscription.

Both paths use `event_id_only`, and the gateway must deliver `user_id` and `registration_id` from `data.default_payload` together with `room_id` and `event_id`. The browser worker accepts these fields as a JSON object or inside `notification`. A Web gateway that does not preserve the account routing data needs to adjust its forwarding, or notifications are rejected.

## User settings and lifecycle

In Settings → Notifications, expand "Push service and gateway" at the bottom and select the transport path for the current platform. Android users can import their own `google-services.json` and fill in the gateway URL and app ID to enable push; a build that already has a prefill config can be used as is or edited. An install without Firebase config prompts for a file import and requires no rebuild. Browser users fill in the gateway, the Web app ID and the VAPID public key. Android needs Google Play services; Web needs HTTPS and a browser supporting PushManager and Service Worker.

The browser push worker uses its own scope and does not replace Flutter's app worker. Disabling one account unregisters only that account's pusher and keeps the browser subscription for other accounts. One site subscription can use only one VAPID public key; on a mismatch an error is reported, and a subscription still used by other accounts is not cancelled. Changing the key requires disabling push for every account first and then clearing the existing browser subscription.

The permission is requested only on enable. Each Matrix account registers separately, and `append=true` keeps the accounts sharing the same installation or browser subscription. Matter displays no system notification while it is in the foreground and focused; on Web, this means a window under the same app path that is visible and focused. Notifications display only "你有一条新消息", and nothing is decrypted in the background. Tapping a notification re-checks the current settings, switches to the owning account and opens the corresponding room and event. Room mute and server push rules continue to apply.

"Push registered" means the homeserver accepted the pusher, and does not prove that the gateway or the complete delivery path works. Disabling push saves the local disabled state first and then unregisters the remote pusher; an offline failure keeps a log and is retried on the next launch, when the account becomes ready, on an Android token update and when the app returns to the foreground. A token or app ID change registers the new pusher first and deletes the old pusher afterwards. A registration sent with an uncertain result is also recorded, for later cleanup. After a force-stop on Android, FCM delivery resumes only once the app is opened again.

## Verification

```sh
flutter analyze
flutter test test/firebase_client_config_test.dart test/push_registration_test.dart test/notification_settings_page_test.dart test/settings_account_switch_test.dart test/auth_provider_test.dart test/account_cache_regression_test.dart
flutter test --platform chrome test/push_registration_test.dart
node --test test/web_push_worker_test.mjs
cd rust
cargo check --locked
cargo clippy --locked --all-targets
cargo test --locked api::matrix::push::tests
cargo test --locked api::matrix::notifications::tests
```

Complete delivery still requires joint testing with a device and a deployed gateway. First import project A's JSON into an APK without Firebase prefill, force-stop and reopen, and verify notifications in the foreground, in the background and after process death. Then import project B and confirm that all old pushers of project A are unregistered, that a reopen uses project B's token, and that a delayed push from project A is rejected. Afterwards verify that a disabled account requests neither permission nor a token, and check each account's HTTP pusher, URL, app ID and `event_id_only`. Use another client to verify notifications in the foreground, in the background and after process death, plus notification taps. Finally verify encrypted rooms, a non-current account, a muted room, offline disable retries, account removal and token rotation. The automated browser checks do not replace joint testing with a real Web client and a real browser push service.
