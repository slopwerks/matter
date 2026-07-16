# matter

## Building

### macOS/iOS Specific notes

As the macOS build is tested on a Mac running the dev beta of macOS 27, whose toolchain only supports macOS 12.0 and higher, this will also be the minimum supported version for the current Xcode project as reported. This is different from the default minumum version as Flutter currently configures by default. While it is possible to change the minimum supported version by manually editing `macos/Runner.xcodeproj/project.pbxproj`, it is recommended to change it from Xcode instead.

Also note that macOS release builds and all iOS simulator builds are broken on macOS 27 due to [this Flutter issue](https://github.com/flutter/flutter/issues/188461), which has been fixed with [this PR](https://github.com/flutter/flutter/pull/188625), which appears to not be in stable as of Flutter 3.44.6. Debug builds on macOS (`flutter build macos --debug`) are not affected. Non-simulator iOS builds are not tested as I do not have the correct provisioning setup yet.
