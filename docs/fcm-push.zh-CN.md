# 消息推送

[English](fcm-push.md)

Matter 默认关闭推送，不预置推送网关或 Firebase 项目。接入方式按平台区分：浏览器使用 Web Push/VAPID，Android 使用 FCM。设置页同时显示两种方式，但只允许选择当前平台支持的一种。ntfy、直接 APNs、iOS 和桌面推送尚未实现。

## 账号通知偏好

“设置 → 通知”先显示账号通知偏好，设备相关的“推送服务与网关”默认折叠在页面底部。

偏好通过 Matrix push rules 保存在 Homeserver 上，因此对该账号的其他设备同样生效；FCM、网关和设备权限仍需分别配置。不支持系统推送的平台也可以管理这些偏好。

可设置的项目包括全部静音、过滤 `m.notice` 通知类消息、过滤编辑消息，以及普通和加密的一对一、群聊分别选择所有消息或仅提及。提及包含直接提及、全体提及，以及匹配显示名、用户名或旧版 `@room` 写法的内容。其他类别各有开关：房间邀请、通话邀请、成员变动、表情回应、房间升级、投票的开始、结束和回应，以及线程通知。关键词支持添加、移除，以及 Matrix 的 `*`、`?` 通配符。服务器上缺少对应规则的项目显示为不支持，无法操作。

全部静音保留其他偏好，静音期间仍可调整，关闭静音后使用调整后的设置。关闭某一类事件提醒时保留匹配规则并清空通知动作，避免这类事件继续落到兜底的消息规则上；过滤通知类消息和编辑消息调整的是抑制规则。

页面直接读取服务器状态，修改后立即显示并自动保存，仅正在保存的那一项暂时不可操作。保存失败时只重新读取对应项并显示底部错误提示，也可刷新或重试。单独设置过的房间仍由房间规则控制，全部静音优先于这些设置。

`m.notice` 是消息类型，不能覆盖所有机器人账号。加密事件在服务端不可读，提及、关键词和消息类型过滤需要客户端解密后才能精确判断，而后台推送不解密。通话开关只控制 Matrix 通话邀请的通知，不改变通话功能或系统铃声。

## 导入自己的 Firebase 配置（Android）

同一个 APK 可供使用不同 Firebase 项目的用户共用，无需重新编译。在“设置 → 通知”中展开底部的“推送服务与网关”，点击“导入 google-services.json”，选择从 Firebase 控制台下载的 Android 客户端配置。文件须包含包名 `moe.aks.matter` 的客户端；如果没有，先在自己的 Firebase 项目中添加该 Android 应用。

Matter 提取对应客户端的 API Key、Firebase App ID、项目编号（Sender ID）和 Project ID，只保存这些公开的客户端参数。一个文件包含多个 Android 客户端时按包名选择；包名不符、参数缺失、编号不一致或给出服务账号文件都会被拒绝。网关的服务账号私钥仍只保存在服务器端。

导入的配置由该安装上的所有账号共用。切换到另一份配置之前，Matter 会关闭并注销所有账号的 FCM pusher，再撤销旧的 FCM 令牌，然后才保存新配置。注销失败时不保存新项目，已关闭的账号保留清理记录以供重试。保存后请在 Android 系统设置中**强行停止 Matter 后重新打开**，使默认 Firebase SDK 实例和后台进程从新配置启动，之后再逐账号启用推送。退出页面或划掉任务不保证 Android 进程已经结束。

导入的配置优先于私人构建的预填值。启动时，Android Application 在前台页面或后台 FCM 服务运行之前读取保存的配置；没有导入配置时才使用构建资源。网关 URL 和 Matrix 应用 ID 仍在账号自己的“推送服务与网关”中修改，须与所选 Firebase 项目的网关对应。

## 可选构建预填值

构建者可通过 `--dart-define-from-file` 注入公开的客户端配置。配置文件放在被 Git 忽略的 `.env.push-client.json` 中：

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

四个 Firebase 字段为可选的预填值，分别取自 Firebase Android 客户端配置的 `current_key`、`mobilesdk_app_id`、`project_number` 和 `project_id`，Android 包名必须是 `moe.aks.matter`。构建会把选项写入 Dart 和 Android 原生资源，用户导入自己的配置后覆盖这些默认值。这些字段留空也能构建 APK，由用户随后在设置中导入；仓库不需要跟踪 `google-services.json` 或 `firebase_options.dart`。

```sh
flutter build apk --dart-define-from-file=.env.push-client.json
```

Web 构建需要网关 URL、Matrix Web 应用 ID 和网关的 VAPID 公钥，不需要 Firebase 客户端配置：

```sh
flutter build web --dart-define-from-file=.env.push-client.json
```

**Web 运行边界：** 上述命令能生成 Flutter 前端，但本仓库的原生 Rust 核心尚未提供浏览器桥接所需的 `pkg/rust_lib_matter` WASM 产物。应用在 `RustLib.init()` 就需要它，因此生成的 `build/web` 还不能作为完整聊天客户端部署。Web Push 的订阅桥接、Service Worker、注册参数和点击路由均已实现并单独测试；完整的 Web 客户端仍需先解决 Rust 核心的 Web 构建与运行支持。本次推送未移植 SQLite、搜索和原生同步运行时。

客户端配置和 VAPID 公钥会进入构建产物。Firebase 服务账号凭据和 VAPID 私钥只能保存在网关端，不能加入客户端或 Git。

## 网关

Homeserver 向 `MATTER_PUSH_GATEWAY` 发出标准 Matrix HTTP 推送请求。该地址须为 Homeserver 可访问的 HTTPS URL，路径以 `/_matrix/push/v1/notify` 结尾；`127.0.0.1` 不是远端 Homeserver 可用的地址。

Android 可使用支持 FCM HTTP v1 的 [Sygnal](https://github.com/matrix-org/sygnal)，应用项例如：

```yaml
apps:
  matter.android:
    type: gcm
    api_version: v1
    project_id: your-firebase-project
    service_account_file: /run/secrets/fcm-service-account.json
```

Matrix 应用 ID 是网关 `apps` 下的键，与 Android 包名或 Firebase 的 `1:…:android:…` ID 不同。网关的服务账号须有权限向用户当前选择的 Firebase 项目发送消息。由于没有固定的官方 Firebase 项目，用户可在同一个 APK 中导入自己项目的客户端配置。

FCM 网关应发送高优先级的 **data message**，不要添加 FCM 的 `notification` 字段：系统自动展示的通知会绕过客户端的停用和账号移除检查。

Web 网关须支持 Web Push/VAPID。客户端在 Matrix pusher 的 `data` 中传递 `endpoint`、`p256dh` 和 `auth`，`pushkey` 使用订阅的 `p256dh`。请确认所用 Sygnal 版本或其他网关支持该模式；FCM 应用项不能接收浏览器订阅。

两种方式都使用 Matrix 默认推送格式，Homeserver 会把非加密事件的内容交给网关。网关须将 `data.default_payload` 中的 `user_id`、`registration_id` 与 `room_id`、`event_id` 一同送达客户端，并保留事件的 `type` 和 `content`，否则客户端只能显示通用提示。FCM 的 `content` 可以是 JSON 字符串，Web 可使用 JSON 对象或 JSON 字符串。浏览器 worker 接受这些字段组成的 JSON 对象，或位于 `notification` 内的对象。不保留账号路由数据的 Web 网关需要调整转发，否则通知会被拒绝。旧的 `event_id_only` 注册会在账号就绪或应用恢复前台时的注册刷新中更新。

## 用户设置与生命周期

在“设置 → 通知”中展开底部的“推送服务与网关”，选择当前平台的接入方式。Android 用户可导入自己的 `google-services.json`，填写网关 URL 和应用 ID 后启用；构建已有预填配置时也可直接使用或修改。未配置 Firebase 的安装会提示导入文件，不要求另行编译。浏览器用户需填写网关、Web 应用 ID 和 VAPID 公钥。Android 需要 Google Play 服务；Web 需要 HTTPS 和支持 PushManager、Service Worker 的浏览器。

浏览器的推送 worker 使用单独作用域，不替换 Flutter 的应用 worker。关闭某个账号只注销该账号的 pusher，浏览器订阅保留给其他账号使用。同一站点订阅只能使用一把 VAPID 公钥；发现不同公钥时报错，不会取消其他账号仍在使用的订阅。更换公钥需先关闭所有账号推送，再清除原有浏览器订阅。

权限只在启用时请求。每个 Matrix 账号分别注册，`append=true` 保留共享同一安装或浏览器订阅的其他账号。Matter 在前台且有焦点时不显示系统通知，Web 以同一应用路径下可见且有焦点的窗口为准。非加密的 `m.room.message` 和 `m.sticker` 显示 `content.body`，加密事件或缺少正文的事件显示“你有一条新消息”，后台不做任何解密。点击通知时会重新检查当前设置，切换到所属账号并打开对应房间及事件。房间免打扰和服务器推送规则继续生效。

打开房间或手动标记已读时，成功发送已读回执后才撤销该账号、该房间在操作开始时已有的通知，操作期间新到的消息保留。当前账号同步到房间未读数从正数降为零时也会清理该房间通知，以处理其他设备上的已读。回执失败不撤销任何通知。Android 用通知 tag 保存账号、房间和事件标识，因此清理逻辑也能识别后台进程创建的通知；升级前没有 tag 的旧通知无法按房间识别，需手动清除。

“推送已注册”表示 Homeserver 接受了 pusher，不证明网关或完整投递链路可用。关闭推送先保存本地停用状态，再注销远端 pusher；离线失败保留日志，之后在下次启动、账号就绪、Android 令牌更新和恢复前台时重试。令牌或应用 ID 变更先注册新 pusher，再删除旧 pusher。已发送但结果不确定的注册也会记录，以便后续清理。Android 被强行停止后，需要重新打开应用才能恢复 FCM 投递。

## 验证

```sh
flutter analyze
flutter test test/push_notification_runtime_test.dart test/firebase_client_config_test.dart test/push_registration_test.dart test/notification_settings_page_test.dart test/settings_account_switch_test.dart test/auth_provider_test.dart test/account_cache_regression_test.dart
flutter test --platform chrome test/push_registration_test.dart
node --test test/web_push_worker_test.mjs
cd rust
cargo check --locked
cargo clippy --locked --all-targets
cargo test --locked api::matrix::push::tests
cargo test --locked api::matrix::notifications::tests
```

完整投递仍需设备与已部署网关联调。先用未预填 Firebase 的 APK 导入项目 A 的 JSON，强行停止后重开，验证前台、后台和进程回收后的通知。再导入项目 B，确认项目 A 的所有旧 pusher 已注销、重开后使用项目 B 的令牌、项目 A 的延迟推送被拒绝。之后检查停用时既不请求权限也不获取令牌，检查两个账号各自的 HTTP pusher、URL、应用 ID 和默认推送格式。用另一个客户端验证有焦点时不弹通知、失去焦点和后台时显示通知、进程回收后的消息与通知点击，以及打开房间、手动标记已读后的通知撤销和其他设备已读同步后的撤销。最后验证加密房间、非当前账号、静音房间、离线停用重试、账号移除和令牌轮换。浏览器模块的自动检查不替代与真实 Web 客户端和真实浏览器推送服务的完整联调。
