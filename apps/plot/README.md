# Plot

## Setup

1. Install Flutter: [MacOS](https://docs.flutter.dev/get-started/install/macos/desktop#install-the-flutter-sdk) / [Windows](https://docs.flutter.dev/get-started/install/windows/desktop#install-the-flutter-sdk)

## Installing on Windows (Local Testing)

MSIX packages are signed with a self-signed certificate. Before installing, you need to trust the certificate on the Windows machine:

1. Copy `windows/plot-codesign.cer` to your Windows machine
2. Double-click the `.cer` file and click **Install Certificate...**
3. Select **Local Machine** → Next
4. Choose **Place all certificates in the following store** → Browse → select **Trusted People** → OK → Next → Finish
5. Double-click the `Plot.msix` file to install

## Updating Drift

Two Drift dependancies are copied into the `web` folder:

1. [sqlite3](https://github.com/simolus3/sqlite3.dart/releases) `sqlite3.wasm`
1. [Drift](https://github.com/simolus3/drift/releases) `drift_worker.dart.js`
