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

  // When `flutter run -d macos` calls `open <bundle>` after attaching to the
  // new agent process's VM service, Launch Services routes that as a reopen
  // event to the EXISTING dev Plot.app — even though flutter_tools spawned a
  // separate process with `--profile=agent`. Refuse the reopen when a peer
  // Plot.app is still launching: that's the proxy for "different profile"
  // (same-profile second launches never reach this delegate via a launched
  // peer — Launch Services routes them as a no-new-process reopen, and
  // forced same-profile peers exit within ms after failing tryAcquire).
  //
  // In practice the activation arrives before this delegate fires, so the
  // refusal alone doesn't prevent the foregrounding — `applicationDidBecomeActive`
  // does the actual revert. Keeping this as a defensive layer in case some
  // macOS version delivers reopen before the activation event.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    let myBundle = Bundle.main.bundleIdentifier ?? ""
    let myPid = ProcessInfo.processInfo.processIdentifier
    let launching = NSRunningApplication.runningApplications(withBundleIdentifier: myBundle)
      .filter { $0.processIdentifier != myPid && !$0.isFinishedLaunching }
    return launching.isEmpty
  }

  // Last non-Plot app to become frontmost. Used as the yield target when we
  // get spuriously activated by `flutter run`'s post-attach `open <bundle>`
  // while another Plot.app process is launching. Filtering on bundleIdentifier
  // (rather than pid) excludes every Plot.app instance so the yield target is
  // always something the user actually wants to return to (terminal, editor).
  private var lastNonPlotFrontmost: NSRunningApplication?

  // Re-entrancy guard for the spurious-activation revert. A user click that
  // re-activates us during the 250ms unhide window would otherwise loop.
  private var yieldingDueToLaunchingPeer = false

  override func applicationWillFinishLaunching(_ notification: Notification) {
    let myPid = ProcessInfo.processInfo.processIdentifier
    let myBundle = Bundle.main.bundleIdentifier ?? ""
    let frontmost = NSWorkspace.shared.frontmostApplication
    if let prev = frontmost, prev.bundleIdentifier != myBundle {
      lastNonPlotFrontmost = prev
    }
    #if DEBUG
    if let prev = frontmost, prev.processIdentifier != myPid {
      launcherApp = prev
    }
    // The first-launch yield is meant for `flutter run -d macos` activating
    // US via post-attach `open <bundle>`. That only happens when we're the
    // sole Plot.app instance — if another Plot is already running, Launch
    // Services routes the open to that existing one, and OUR first activation
    // will be user-initiated (Cmd+Tab, dock click). Pre-arming the gate
    // suppresses the yield so the agent process doesn't flicker itself out
    // every time the user focuses its window.
    let hasExistingPeer = NSRunningApplication.runningApplications(withBundleIdentifier: myBundle)
      .contains { $0.processIdentifier != myPid }
    if hasExistingPeer {
      hasYieldedLaunchActivation = true
    }
    #endif
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceDidActivate(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )
    super.applicationWillFinishLaunching(notification)
  }

  @objc private func workspaceDidActivate(_ notification: Notification) {
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    if app.bundleIdentifier != Bundle.main.bundleIdentifier {
      lastNonPlotFrontmost = app
    }
  }

  override func applicationDidBecomeActive(_ notification: Notification) {
    let myBundle = Bundle.main.bundleIdentifier ?? ""
    let myPid = ProcessInfo.processInfo.processIdentifier
    let launching = NSRunningApplication.runningApplications(withBundleIdentifier: myBundle)
      .filter { $0.processIdentifier != myPid && !$0.isFinishedLaunching }

    // Spurious-activation revert (release + debug). `flutter run -d macos`
    // calls `open <bundle>` after attaching to the agent process's VM
    // service; Launch Services activates the EXISTING dev Plot.app rather
    // than the launching agent process. The activation notification arrives
    // ~100ms BEFORE the corresponding reopen Apple Event, so refusing the
    // reopen is too late — undo here by hiding and explicitly handing focus
    // back to the last non-Plot app we observed (typically the terminal or
    // editor that ran the launcher).
    if !launching.isEmpty && !yieldingDueToLaunchingPeer {
      yieldingDueToLaunchingPeer = true
      NSApp.hide(self)
      lastNonPlotFrontmost?.activate(options: [.activateIgnoringOtherApps])
      // unhideWithoutActivation brings our windows back without re-firing
      // didBecomeActive — otherwise we'd loop on every cycle.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        NSApp.unhideWithoutActivation()
        self?.yieldingDueToLaunchingPeer = false
      }
      super.applicationDidBecomeActive(notification)
      return
    }

    #if DEBUG
    // First-activation yield (debug-only): `flutter run -d macos` runs
    // `open <bundle>` after attaching to the VM service to bring the new
    // Plot.app to the foreground. That steals focus from the editor that
    // initiated the run. Yield it back the first time we become active,
    // unless we already pre-armed the gate above because another Plot peer
    // is running (the agent case, where the spurious open routes to the
    // peer, not us). Hide is more decisive than deactivate here because
    // Cocoa re-promotes us as `open` keeps propagating through Launch
    // Services. Unhide on the next runloop tick so dart-mcp / flutter_driver
    // can still see the window.
    if !hasYieldedLaunchActivation && NSApp.isActive {
      hasYieldedLaunchActivation = true
      NSApp.hide(self)
      if let prev = launcherApp, prev.bundleIdentifier != myBundle {
        prev.activate(options: [.activateIgnoringOtherApps])
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        NSApp.unhide(nil)
      }
    }
    #endif
    super.applicationDidBecomeActive(notification)
  }

  #if DEBUG
  private var hasYieldedLaunchActivation = false
  private var launcherApp: NSRunningApplication?
  #endif
}
