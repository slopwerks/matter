# 本地 Flutter 依赖补丁

此目录保留发布包的运行所需源码、许可证、pubspec、README 与 CHANGELOG。
根 pubspec 的 path overrides 确保本地和 CI 使用相同补丁，共享 Pub 缓存保持原样。
本地副本同时清理了上游的行尾空白。

- `geolocator_android`：来自 pub.dev 5.2.1，归档 SHA-256
  `e67583809a1fab5f4a2255902978e2bc095ace9451fde0d9624e54facd0a5c22`。
  `LocationMapper.getDoubleExtra` 使用 AndroidX `BundleCompat.getSerializable`
  的类型化读取替代已弃用的 `Bundle.get`，保留对所有 `Number` 子类、有限值
  和多个候选键的处理。上游：<https://github.com/Baseflow/flutter-geolocator>。
- `inspire_blur`：来自 pub.dev 0.4.1，归档 SHA-256
  `b585981ba722ef7e1d4bba6b761dd516a3318189d422186c6a1f756e131a09e5`。
  两个 shader 的 `main` 将低 sigma 与正常模糊路径写成 `if/else`，移除
  提前返回，保持采样、归一化和颜色调整计算不变，避免 Flutter 报告的
  Windows 编译风险。上游：<https://github.com/inspirestack/inspire_blur>。

升级这些包时，与对应发布归档逐文件比较；上游包含同等修复后，删除本地副本
和对应 override，重新解析依赖并执行 release 构建。
