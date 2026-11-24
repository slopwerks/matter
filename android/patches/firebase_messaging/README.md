# Firebase 元数据读取补丁

`FlutterFirebaseMessagingBackgroundGate.java` 来自 firebase_messaging 17.1.0。
根 Android 构建脚本仅在 Java 编译输入中替换此文件，插件其余源码仍来自原包，
共享 Pub 缓存保持不变。

该模块同步采用应用的 compileSdk 37，以满足 AndroidX Core 1.16 的编译及
单元测试依赖要求；不改变 minSdk 或 targetSdk。
该插件的 Robolectric 测试依赖也与应用统一为 4.16.1，兼容 SDK 37。

唯一逻辑改动：使用 `BundleCompat.getSerializable(..., Serializable.class)`
替代弃用的 `Bundle.get`。Manifest 元数据中的 Boolean 与 String 仍由原来的
`BackgroundHandlerStartDecision.manifestValue` 解释；缓存、线程和后台处理策略不变。

FCM 的 `getToken`、`deleteToken` 和 `onNewToken` 仍保留在原包中。它们用于
现有 Matrix 推送网关的令牌协议；替换为 FID 注册接口还需要网关同步迁移。
这些调用的弃用诊断没有屏蔽。升级插件时需复核并移除已被上游修复的补丁。
