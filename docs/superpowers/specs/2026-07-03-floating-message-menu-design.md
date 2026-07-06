# 悬浮消息菜单设计

日期: 2026-07-03
分支: feat/floating-message-menu

## 背景

当前长按聊天消息时，`message_group.dart` 的 `_showContextMenu`（约 1229 行）用 `showModalBottomSheet` 从屏幕底部滑出一个圆角面板，包含快捷表情行与竖向菜单项（复制/回复/转发/编辑/撤回）。菜单离拇指较远，不够顺手。

## 目标

将长按菜单改为**悬浮**在被长按气泡附近的 popover，贴近手指操作位置。菜单内容与动作逻辑保持不变，只改呈现方式与定位。

## 非目标

- 不改 Rust、provider、其他页面。
- 不改长按触发条件（事件消息仍可长按；本地 pending 消息仍禁用长按）。
- 不处理返回键关闭菜单（点外部即关闭）。
- 不实现"转发"真实逻辑（仍是占位）。

## 设计

### 实现方式：自定义 OverlayEntry

不用 `showMenu`/`PopupMenuButton`（仅支持竖向列表，无法承载双行布局）。改用 `OverlayEntry` + 全屏透明 barrier，完全控制位置与样式。

### 菜单形态（双行混合）

- **上行**：快捷表情 `👍❤️😂😮😢🙏` + `+`（打开完整表情面板）。系统事件消息不显示此行。
- **下行**：图标在上、文字在下的竖向小单元横排。项：复制(文本)/回复/转发/编辑(仅己方文本)/撤回(仅己方，红色)。每项约 52px 宽，5 项约 260px，窄屏可放下。
- 两行之间细分隔线。

### 触发与定位

- 长按入口不变（`message_group.dart` 中文本/媒体气泡与事件消息的 `onLongPress`），仍调用 `_showContextMenu(context, ref, message)`。
- 由于 `_buildMessage` 复用父级（`MessageGroupWidget.build`）的 `context`，其 `findRenderObject()` 会解析到整组的外层渲染对象，而非被长按的气泡。因此在每个气泡（`coreBubble`）与事件消息外层包一层 `Builder`，捕获该 Builder 自身的 `BuildContext` 并传入 `_showContextMenu`。`BuildContext.findRenderObject()` 会沿 `renderObjectAttachingChild` 向下走到子树首个 `RenderObjectElement`，于是取得的是气泡本身的渲染对象（如文本气泡的 `DecoratedBox`）。
- `_showContextMenu` 内通过该 context 的 `findRenderObject() as RenderBox` 取气泡全局坐标与尺寸（bubbleRect）。
- 插入 `OverlayEntry`，渲染 `_FloatingMessageMenu`：
  - **垂直**：上方优先。若 `bubbleTop - 估算菜单高 - gap < 安全区顶部`，翻转到气泡下方。
  - **水平**：对方消息（左侧气泡）菜单左缘对齐气泡左缘；己方消息（右侧气泡）菜单右缘对齐气泡右缘；再用屏幕安全区钳制。
  - **自测尺寸**：首帧 `opacity:0` 渲染在估算位置，post-frame 回调读取实际尺寸并修正位置，第二帧淡入（fade + 轻微 scale，约 150ms），避免位置跳动。

### 关闭与交互

- 全屏 barrier（`Positioned.fill` + `GestureDetector`）捕获外部点击 → 关闭菜单。
- 任意菜单项点击 → 先关闭菜单，再执行原动作。动作回调保持不变：
  - 复制：`Clipboard.setData` + SnackBar。
  - 回复：`replyingToProvider(roomId)` + `onReplyRequested`。
  - 编辑：`editingMessageProvider(roomId)`。
  - 撤回：`redactMessage(ref, roomId, id)` + `MarkdownSourceStore().delete`。
  - 反应：`sendReaction(...)` + `refreshMessages`。
  - `+`：关闭菜单后打开 `_showEmojiPicker`。
- 表情行/菜单项原先的 `Navigator.of(context).pop()` 改为接收统一的 `close` 回调（移除 overlay）。

## 改动范围（surgical）

仅 `lib/pages/chat/message_group.dart`：

1. 重写 `_showContextMenu`（1229-1321）为创建并插入 `OverlayEntry`。
2. 新增私有 `_FloatingMessageMenu`（StatefulWidget）：自测尺寸、定位、淡入、barrier、关闭回调。
3. `_MenuItem`（1587-1626）扩展支持"图标上文字下"竖向单元模式（或新增 `_IconTextAction`），原有横排样式若仅此处使用则一并替换。
4. `_buildQuickReactions`（1079-1117）的关闭动作由 `Navigator.pop` 改为传入的 `close` 回调。

不改 Rust、provider、其他页面。

## 验证

- `flutter analyze` 通过、`dart format .`。
- 手动验证：
  - 消息类型：文本、图片、视频、贴纸、事件消息。
  - 对方/己方消息。
  - 屏幕顶部消息（翻转至下方）。
  - 窄屏宽度（水平钳制不越界）。
  - 点外部关闭。
  - 反应/回复/编辑/撤回/复制/转发各动作正常。
  - `+` 进入完整表情面板。
  - 回复/编辑状态切换正常（取消回复/取消编辑不回归）。
