# matter

## Building

### macOS/iOS Specific notes

As the macOS build is tested on a Mac running the dev beta of macOS 27, whose toolchain only supports macOS 12.0 and higher, this will also be the minimum supported version for the current Xcode project as reported. This is different from the default minumum version as Flutter currently configures by default. While it is possible to change the minimum supported version by manually editing `macos/Runner.xcodeproj/project.pbxproj`, it is recommended to change it from Xcode instead.

Also note that release builds are broken on macOS 27 due to [this Flutter issue](https://github.com/flutter/flutter/issues/188461), which has been fixed with [this PR](https://github.com/flutter/flutter/pull/188625), which appears to not be in stable as of Flutter 3.44.5. Debug builds (`flutter build macos --debug`) are not affected.

These issues should affect iOS builds as well and should be fixable in a similar fashion, but these changes haven't been incorporated as I haven't gotten to testing them on iOS yet.
