# Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

# Simplicity First

**Minimum behavior-preserving code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

# Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

# Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

For bug fixes, prefer this order:

1. Reproduce the bug with a failing test, log, or minimal scenario.
2. Fix the root cause.
3. Verify the failing case now passes.
4. Verify nearby existing behavior still works.

If no automated test is practical, state the manual verification steps and the specific behavior that must not regress.
Bug fixes must preserve intended behavior. Do not remove, bypass, disable, or silently ignore behavior just to make the bug disappear.

# Style Guide

- Not defined here. For now, follow the same conventions and patterns that you detect in the surrounding code.
- Keep formatting consistent.
- Format Dart code with `dart format .` and follow the lint rules in `analysis_options.yaml`.
- Format Rust code with `cargo fmt` and check it with `cargo clippy`.

# Environment Guide

- The project uses Flutter SDK (>=3.44.0) and Dart SDK (>=3.12.0).
- The Rust toolchain is managed via `rustup`; build targets include mobile (Android/iOS) native libraries.
- Use the `flutter` CLI as the main entry point; do not run the Flutter project with the `dart` CLI alone.

# Background Dev Servers

Do not start Flutter dev servers with `&` or detached processes. Instead use:

- `flutter run` — run directly, connect to a physical device or emulator, supports hot reload
- `flutter run -d chrome` — debug on the web platform
- `flutter run -d linux` / `flutter run -d macos` — debug on desktop platforms

Long-running development services (e.g., `flutter run`) should be started through the tool's background-task mechanism, which auto-detaches after a timeout. Do not manually `&` or detach.

# Flutter Quick Reference

- Use `flutter run` to start the app with hot reload. Do not use other approaches.
- Use `flutter build apk` / `flutter build ios` / `flutter build web` for production builds.
- Use `flutter analyze` to run static analysis (respects `analysis_options.yaml`).
- Use `flutter test` to run unit and widget tests.
- Use `flutter pub get` / `flutter pub upgrade` to manage dependencies.
- Use `dart format .` to format the codebase.

# Project Structure

This project uses a Flutter + Rust hybrid architecture, connected by `flutter_rust_bridge` (FRB).

```
lib/
├── app.dart                  # App root widget and routing
├── main.dart                 # Entry point, initialization, and dependency injection
├── pages/                    # Page-level widgets
│   ├── chat/                 # Chat-related pages and components
│   ├── login/                # Login page
│   ├── settings/             # Settings page
│   └── contacts/             # Contacts page
├── providers/                # Riverpod state management
│   ├── auth_provider.dart    # Authentication and multi-account management
│   ├── chat_provider.dart    # Core chat state
│   └── ...                   # Other providers
├── src/rust/                 # FRB-generated Dart bindings (do not edit manually)
├── theme/                    # Theme and color definitions
└── widgets/                  # Common widgets

test/                         # Unit tests, provider tests, and some widget tests
test/widgets/                 # Standalone widget tests

rust/
├── src/api/matrix.rs         # Rust-side core business logic
├── src/frb_generated.rs      # FRB-generated Rust bindings (do not edit manually)
└── Cargo.toml                # Rust dependencies
```

**Important:** `lib/src/rust/` and `rust/src/frb_generated.rs` are auto-generated by FRB; do not edit them manually. After modifying Rust APIs, rerun FRB code generation.

# Flutter Rust Bridge (FRB)

This project uses FRB v2 to bind the Rust Matrix SDK to the Dart layer.

- After modifying Rust code under `rust/src/api/`, run `flutter_rust_bridge_codegen generate` to regenerate the bindings.
- The generated `lib/src/rust/api/matrix.dart` is the Dart-side FRB binding file.
- Rust functions exposed to Dart are annotated with `#[frb]`.
- After changes, make sure Rust compiles: `cd rust && cargo check`.

# Running Tests

## Dart Tests

- `flutter test` — run all tests
- `flutter test test/some_test.dart` — run a single test file
- `flutter test --name "test name"` — run tests matching a name
- `flutter test --update-goldens` — update golden files

Tests are based on `flutter_test`. `test/` contains unit, provider, and some widget tests; `test/widgets/` contains standalone widget tests.

## Rust Tests

- `cd rust && cargo test` — run Rust unit tests
- `cd rust && cargo test -- --nocapture` — show test output

## Analysis and Formatting

- `flutter analyze` — static analysis
- `dart format .` — format Dart code
- `cd rust && cargo clippy` — Rust code analysis
- `cd rust && cargo fmt` — format Rust code

# Deep Dives

These modules have the highest commit churn, the largest code volume, and are the most likely to break. Read the related files before making changes.

## Message List and Bubble Rendering

Core file: `lib/pages/chat/message_group.dart` (nearly 2000 lines). Message grouping, clustering, bubble border radius, avatar placeholders, swipe-to-reply gestures, send-flight animation target positioning, and read-receipt avatar rows are all coupled here. When changing message layout or animation, always verify text, image, video, sticker, and event messages, as well as behavior at different screen widths.

## Input Panel and Keyboard State

Core file: `lib/pages/chat/message_input.dart` (nearly 1000 lines), together with `composer_picker_panel.dart` and `emoji_picker_panel.dart`. Keyboard focus, emoji/sticker panel switching, typing timers, edit-message prefilling, and reply-quote state all interact and are timing-sensitive. After changes, test the full flow: open keyboard → switch to emoji → start typing → switch back to keyboard → cancel reply/edit.

## Chat State and Local Message Reconciliation

Core files: `lib/providers/chat_provider.dart` and `lib/pages/chat/send_flight.dart`. Local messages use `local_outgoing_pending:` / `sent:` / `failed:` prefixes for optimistic updates, then reconcile against and replace with server events. `reconcileMessageSnapshot` merges the local and remote lists; the send-flight animation relies on message-ID matching to find its destination. When modifying message IDs, ordering, pagination, or the send flow, make sure reconciliation logic and animation targeting remain intact.

## Rust Matrix Bridge

Core file: `rust/src/api/matrix.rs` (5000+ lines). It is the single FFI boundary between Dart and `matrix-sdk`, wrapping sync, E2EE, room state, pagination, invites/knocks, token refresh, and more. After changes, rerun FRB generation and check Rust compilation and Dart call sites. Async calls across FFI run on the Tokio runtime; avoid blocking the main thread or awaiting while holding locks to prevent deadlocks.
