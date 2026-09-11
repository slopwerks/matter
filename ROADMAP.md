# Matter Roadmap

基于当前代码盘点与 `ref/msc.md`（tuwunel 的 MSC 实现清单）整理。
原则：**优先做「服务端已支持、SDK 已有封装、用户可感知」的功能**，把收益/成本比最高的排在前面。

每个条目标注：

- **服务端**：tuwunel 支持状态（✅ / 🟨 / ❌，来自 ref/msc.md）
- **SDK**：matrix-sdk 0.18 是否有现成封装
- **工作量**：S < 1 天，M 数天，L 一周以上
- **验收**：可验证的完成标准

---

## P0 — 快速补齐：低成本、高存在感

这一批全是标准 C-S API，tuwunel 全 ✅，matrix-sdk 有现成方法，纯 FFI 透传 + UI 接线。

### 1. 房间基础管理

- 退出普通房间（目前只有 `leave_space` / 拒绝邀请 / 撤回 knock，没有 `leave_room`）
- 邀请用户进房间
- 修改房间名 / topic / 头像
- 房间免打扰（mute，用 push rules 或房间账号数据）

**服务端**：✅（标准 API + MSC4010 push rules）
**SDK**：`Room::leave()` / `invite_user_by_id()` / `set_name()` / `set_topic()` / push rules API
**工作量**：S–M
**验收**：在房间详情页完成退出/邀请/改名/静音四操作，另一客户端可见同步结果。

### 2. 置顶消息（Pinned messages）

**服务端**：✅（`m.room.pinned_events` 状态事件）
**SDK**：state event 读写即可
**工作量**：M
**验收**：长按消息可置顶/取消置顶，房间头部可查看全部置顶。

### 3. 已读/未读管理

- 显式「标记房间为已读」
- 「标记为未读」（MSC2867，房间账号数据 `m.marked_unread`）

**服务端**：✅ / 🟨（MSC2867 部分实现）
**SDK**：`Room::mark_as_read()`；未读标记走房间账号数据
**工作量**：S
**验收**：房间列表支持两操作，状态在 tuwunel 重启后保留。

### 4. 忽略用户（Ignore / block）

**服务端**：✅（`m.ignored_user_list` 账号数据）
**SDK**：账号数据 API；matrix-sdk 会自动过滤被忽略用户的事件
**工作量**：S–M
**验收**：忽略某用户后其消息在时间线消失，取消忽略后恢复。

### 5. Knock 审批流

目前已有撤回 knock，缺管理侧的同意/拒绝。

**服务端**：✅（MSC2403 knock + MSC3787 restricted rooms）
**SDK**：邀请该用户即视为批准
**工作量**：S
**验收**：房间管理页能看到 knock 列表并批准/拒绝。

---

## P1 — 核心缺口：当前明显缺失的大块

### 6. 推送通知 ★ 最大缺口

当前完全没有 push：无 pusher 注册、无 FCM/UnifiedPush 依赖、通知设置页是占位文案。

- 方案选型：Android 主推 **UnifiedPush**（自托管场景友好，配合 ntfy）；FCM 需要 Firebase 项目与 Google Play 服务，二选一或双通道。
- 拆解：
  1. 依赖与权限（`flutter_local_notifications` 或对应插件 + 后台隔离）
  2. Rust 侧 pusher 注册（`set_pusher`，http pusher 指向 push gateway）
  3. 通知展示与点击跳转房间
  4. 设置页通知开关（替换 `settings_page.dart:384` 的占位）

**服务端**：✅（MSC4010 push rules、MSC3987、MSC3930 等均实现；tuwunel 支持 http pushers）
**SDK**：matrix-sdk 有 pusher API 封装
**工作量**：L（跨平台后台通知是重头）
**验收**：App 在后台收到消息时弹出系统通知，点击直达对应房间；静音房间不弹。

### 7. 语音消息 + 音频播放

发送按钮已是 stub（`message_input.dart:840` 提示"暂未提供"），音频文件目前按普通文件渲染。

- 录音（`record` 插件）、波形生成、按 `m.audio` + 语音扩展格式发送
- 音频气泡内播放（`just_audio` 或 `audioplayers`）

**服务端**：✅（语音消息只是普通事件 + 媒体上传，tuwunel 全支持）
**SDK**：媒体上传已有，仅需拼事件格式
**工作量**：M–L
**验收**：可录制/发送语音，气泡内播放带进度条，加密房间内可解密播放。

### 8. 服务器端消息搜索

目前只有本地房间名过滤。tuwunel 实现了 `/search` 及聚合。

**服务端**：✅（MSC3666 bundled aggregations for search 🟨——thread 总是 bundle，edit/reference 需在 tuwunel 配置里开 flag）
**SDK**：`Client::search()` 现成
**工作量**：M
**验收**：聊天页可搜历史消息并跳转定位；已知限制——编辑/引用聚合取决于服务端配置，先按基础结果渲染。

### 9. 房间目录 / 公开房间发现

**服务端**：✅（MSC2197 联邦搜索、MSC3827 按类型过滤）
**SDK**：`Client::public_rooms()` 现成
**工作量**：M
**验收**：可浏览/搜索公开房间并加入。

---

## P2 — 体验深化：threads、presence、E2EE 增强

### 10. Threads（消息串）

tuwunel 支持面很全：MSC3440 threading、MSC3771 串内已读回执、MSC3773 串通知、MSC3856 Threads List API 均 ✅。

- 拆解：时间线内串入口 → 串视图（独立分页）→ 串内回复 → 串未读计数
- 风险：`message_group.dart` 与 reconciliation 逻辑耦合深，串消息不应混入主时间线的本地消息匹配。

**SDK**：matrix-sdk 0.18 有 thread 相关封装（relations + 部分 thread API），订阅类功能（MSC4306 tuwunel 仅 🟨）先不做
**工作量**：L
**验收**：可发起/浏览串回复，串未读数与另一客户端一致；主时间线气泡布局无回归（重点回归文本/图片/回复三类消息）。

### 11. Presence（在线状态）

**服务端**：✅（含 MSC3026 busy 状态）
**SDK**：presence API 现成
**工作量**：M
**验收**：联系人/成员列表显示在线状态，DM 标题栏显示对方状态。

### 12. 交叉签名与用户验证

目前有设备级 SAS 验证，缺：交叉签名引导（bootstrap）、验证其他用户的 master key、按用户信任级显示盾牌标识、手动 megolm 密钥导出/导入。

**服务端**：✅（MSC1756 交叉签名、MSC1946 SSSS、MSC3967 等）
**SDK**：matrix-sdk 的 `encryption` 模块完整支持（`bootstrap_cross_signing`、用户级验证）
**工作量**：L
**验收**：新登录设备可通过交叉签名自动被信任；验证过的用户在加密房间显示信任标识；可导出/导入房间密钥。

### 13. SSO / OIDC 登录

**服务端**：✅（MSC3861 next-gen auth、MSC2964/2965/2966 OAuth 全家桶、MSC2858 多 IdP）
**SDK**：matrix-sdk 有 OIDC 封装
**工作量**：L（需要 deeplink/回调处理，多平台各一套）
**验收**：tuwunel 配置了 OIDC provider 时可用 SSO 登录并完成 E2EE 初始化。

---

## P3 — 锦上添花与长线

### 14. 空间增强

空间子房间排序、MSC4168 升级时复制 `m.space.*` 状态（🟨）、Space Summary 更深导航。

### 15. 富文本增强

Spoiler（`data-mx-spoiler`）、MSC4193 媒体 spoiler 遮罩（✅）、MSC4197 复制粘贴提示（✅）。

### 16. BlurHash 图片占位

**服务端**：🟨 MSC2448 部分实现。**工作量**：S（发图时生成、显示时解码）。**验收**：图片加载前显示模糊占位。

### 17. 链接预览改用服务端 URL preview

当前客户端自行抓 OG。可改用服务端 `/preview_url`（MSC4452 capabilities ✅），减轻客户端流量。工作量 M。

### 18. VoIP / MatrixRTC

tuwunel 侧 MSC2746（1:1 信令）✅、MSC4143 MatrixRTC 🟨、MSC4158 focus 发现 🟨、MSC4166 空 TURN 响应 ✅。客户端需要引入 WebRTC 栈，工程量大，且 tuwunel 的 RTC 支持尚不完整。**建议最后做或单独立项。**

### 19. 非协议类欠债

- i18n 框架（目前硬编码 zh-CN）
- 主题选择（目前固定暗色）
- 数据/存储管理（缓存清理入口）
- 账号注销（服务端 MSC4025 ✅）

---

## 建议的第一刀

如果从「下周就能动手」的角度，推荐顺序：**P0 整批（1–5）→ 6 push → 7 语音**。理由：

1. P0 全是透传型工作，能在动工大件之前先积累 FFI 与 UI 接线的手感，且每一项都能立刻被用户感知。
2. Push 是留存级的缺失，越早上越好，但它跨平台细节多，适合在 P0 之后整块投入。
3. Threads 和交叉签名价值高但风险面大（前者碰 `message_group.dart`，后者碰加密栈），等核心链路稳定后再动。
