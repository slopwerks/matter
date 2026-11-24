# Android 插件构建配置

`settings.gradle.kts` 将三个已锁定插件的 `buildFileName` 指向本目录。
项目目录和源文件仍来自 Pub 解析结果，不修改共享缓存，也不复制插件的
跨平台实现。脚本保留对应发布版的 namespace、SDK 配置和 Android 依赖，
移除旧 KGP 的 classpath、apply 和兼容分支，统一使用 AGP 9 内置 Kotlin
及 Java/Kotlin 17。公共 Maven 仓库由根构建脚本提供。

- `desktop_drop.gradle`：desktop_drop 0.8.4。
- `flutter_image_compress_common.gradle`：flutter_image_compress_common 1.1.1。
- `photo_manager.gradle`：photo_manager 3.12.0。

升级插件时同步对照其发布版 `android/build.gradle`，保留新增依赖及配置；
上游完全移除旧 KGP 接入后，可删除对应脚本及 settings 中的映射。
