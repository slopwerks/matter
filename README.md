# matter

## Building

First generate the bindings between Rust and Flutter. This will need to be rerun on any change in Rust code or environment.

```bash
flutter_rust_bridge_codegen generate
```

A `flutter build` for a platform supported by your Flutter toolchain should generally work afterwards. The bridge component as a build product should be automatically configured for Android, iOS, Linux, macOS, and Windows. Other platforms are not tested, but should most likely only require some form of manual copying.

### macOS/iOS Specific notes

If you are building a release build on a macOS 27 host:
- <del>Flutter 3.47.0 or higher is required due to [this Flutter issue](https://github.com/flutter/flutter/issues/188461).</del> No longer an extra requirement since the project's own Flutter dependency is now higher.
- Rust 1.98.0 or higher might be required due to [this Rust issue](https://github.com/rust-lang/rust/issues/157750). The primary indicator is if you run into Rust errors on `*_derive` libraries, and a second build reports errors involving `LINKEDIT` misalignments.

When building for iOS, simulator builds (inherently Debug) are broken due to [#56](https://github.com/slopwerks/matter/issues/56). Release build should work provided that you configure your own provisioning.

Note that currently the Rust component is only built for the current arch while the Xcode build is universal for release. This results in a supposedly universal app but with a framework that only runs on the same arch it is built on.

### Windows specific notes

As stated in a TODO under rust/src/api/matrix.rs#2838, the login can fail due to an "Access Denied" error on Windows (reports a generic error on GUI, only visible in logs). This appears to be a race condition that can be worked around by making the `sleep` longer. The correct value (without making the wait too long) is most likely hardware dependent, and more testing is needed.
