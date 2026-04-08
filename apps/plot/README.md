# Plot

## Setup

1. Install Flutter: [MacOS](https://docs.flutter.dev/get-started/install/macos/desktop#install-the-flutter-sdk) / [Windows](https://docs.flutter.dev/get-started/install/windows/desktop#install-the-flutter-sdk)
2. Install [Rust](https://rustup.rs/) (required by `super_clipboard` native extensions): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`

## Installing on Windows (Local Testing)

MSIX packages are signed with a self-signed certificate. Before installing, you need to trust the certificate on the Windows machine:

1. Copy `windows/plot-codesign.cer` to your Windows machine
2. Double-click the `.cer` file and click **Install Certificate...**
3. Select **Local Machine** → Next
4. Choose **Place all certificates in the following store** → Browse → select **Trusted People** → OK → Next → Finish
5. Double-click the `Plot.msix` file to install

## Upgrading sqlite3

`sqlite3` is overridden via `dependency_overrides` to point to a local fork at `third_party/sqlite3/`. The fork exists because Flutter hard-disables link hooks in debug mode, making it impossible to control per-platform native asset behavior from `pubspec.yaml` alone.

**The patch** is a single change in `third_party/sqlite3/hook/build.dart`: on macOS, the build hook uses `SimpleBinary.fromProcess` (resolves sqlite3 symbols from the process, where `FlutterMacOS.framework` already has sqlite3 loaded) instead of bundling a precompiled copy. This avoids a SIGSEGV crash caused by dual-loaded sqlite3 when multiple app instances run concurrently. All other platforms use the original bundled precompiled behavior.

**To upgrade sqlite3:**
1. Copy the new version from the pub cache: `cp -r ~/.pub-cache/hosted/pub.dev/sqlite3-X.Y.Z/ apps/plot/third_party/sqlite3/`
2. Re-apply the macOS check in `third_party/sqlite3/hook/build.dart` — replace the `SqliteBinary.forBuild(input)` call with:
   ```dart
   final sqlite = input.config.code.targetOS == OS.macOS
       ? SimpleBinary.fromProcess
       : SqliteBinary.forBuild(input);
   ```
3. Update the `sqlite3` version constraint in `pubspec.yaml` dependencies
4. Run `flutter clean && flutter pub get`

## Updating Drift

Two Drift dependancies are copied into the `web` folder:

1. [sqlite3](https://github.com/simolus3/sqlite3.dart/releases) `sqlite3.wasm`
1. [Drift](https://github.com/simolus3/drift/releases) `drift_worker.dart.js`
