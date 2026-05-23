import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Return false so AppKit does NOT schedule its
  // `_scheduleCheckForTerminateAfterLastWindowClosed` timer when the last
  // visible window goes away. Dart-side shutdown (window.dart's
  // `onWindowClose` / `onExitRequested`) hides the window before draining
  // Store.stop, so a `true` here lets AppKit's timer fire on the next runloop
  // tick — long before the 8s watchdog's `io.exit(0)` can run — racing it
  // into `[NSApplication terminate:]` → `FlutterEngine shutDownEngine` →
  // `Dart_ShutdownIsolate`, where `package:sqlite3`'s NativeFinalizer pass
  // calls `sqlite3_finalize` on a stmt whose connection's arena was already
  // freed by `sqlite3_close_v2` (no ordering between sibling finalizers).
  // Crash. See `_runShutdownWithWatchdog` in window.dart for the full story.
  //
  // With `false`, the Dart shutdown path is the only thing that terminates
  // the process, via its explicit `io.exit(0)`. Cmd+Q / Apple-menu Quit /
  // MenuBarController's quit item still call `NSApp.terminate(nil)`, which
  // routes through `applicationShouldTerminate:` → Dart's `onExitRequested`
  // → same `io.exit(0)`.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  #if DEBUG
  // `flutter run` for macOS deliberately runs `open <bundle>` after attaching
  // to the VM service to "Bring app to foreground" (flutter_tools'
  // `macos_device.dart` onAttached). That activation is delivered to the
  // already-running Plot process via Launch Services and steals focus from
  // the editor that ran `flutter run`. Yield it back the first time we
  // become active — only in Debug builds, so Release launches from
  // Finder/Dock still activate normally.
  //
  // The yield runs BEFORE super.applicationDidBecomeActive because super
  // does not return cleanly in this path (FlutterAppDelegate inherits
  // applicationDidBecomeActive from NSObject's default forwarding, and a
  // super-send appears to swallow any subsequent statements). Calling our
  // logic first is the difference between the hide running and it being
  // silently skipped.
  private var hasYieldedLaunchActivation = false

  override func applicationDidBecomeActive(_ notification: Notification) {
    if !hasYieldedLaunchActivation && NSApp.isActive {
      hasYieldedLaunchActivation = true
      // Yield focus back to whatever launched us (editor running
      // `flutter run`). `NSApp.deactivate()` alone is unreliable: Cocoa
      // re-promotes us as `open` from flutter_tools keeps propagating
      // through Launch Services. Hiding is decisive — focus goes to the
      // launcher and stays — but leaves Plot's window hidden, which
      // breaks anything driving the UI (dart-mcp, flutter_driver, manual
      // testing). Unhide on the next runloop tick so the window comes
      // back without re-activating the app.
      NSApp.hide(self)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        NSApp.unhide(nil)
      }
    }
    super.applicationDidBecomeActive(notification)
  }
  #endif
}
