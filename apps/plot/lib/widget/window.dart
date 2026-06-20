import 'dart:async';
import 'dart:io' as io;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:macos_window_utils/macos_window_utils.dart' as macos_win;
import 'package:macos_window_utils/macos/ns_window_button_type.dart';
import 'package:macos_window_utils/widgets/visual_effect_subview_container/visual_effect_subview_container.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/main.dart' show instanceLock;
import 'package:plot/widget/focus_keeper.dart';
import 'package:plot/widget/modal.dart';
import 'logging.dart';

/// Height of the app's top header band — the [UnifiedHeader] used by the
/// feed/thread views and, on desktop, the [WindowControlsInset] band that
/// keeps single-panel tab-root pages clear of the macOS traffic lights.
/// Shared so the two never drift, which would otherwise make the traffic
/// lights jump as the user moves between a tab root and a thread.
const double kAppHeaderHeight = 44.0;

class Window extends StatefulWidget {
  static late final double toolbarHeight;
  static late final EdgeInsetsGeometry toolbarPadding;

  /// Height of the Windows window controls area, matching the header bar height.
  static const double windowControlsHeight = 46.0;

  /// Default macOS traffic light button height in points.
  static const double _trafficLightHeight = 14.0;

  /// Original x positions (from window left) of the macOS traffic light
  /// buttons, captured at init time so we can re-position them while keeping
  /// their horizontal layout intact.
  static List<double>? _trafficLightOriginalX;
  static double? _lastAppliedTrafficLightY;

  /// Vertically centers the macOS traffic light buttons within a header of
  /// [headerHeight] points. No-op on non-macOS platforms.
  static Future<void> alignTrafficLightsToHeader(double headerHeight) async {
    if (!Platform.instance.isMacOS) return;
    final originals = _trafficLightOriginalX;
    if (originals == null) return;
    final y = ((headerHeight - _trafficLightHeight) / 2).clamp(
      0.0,
      double.infinity,
    );
    if (_lastAppliedTrafficLightY != null &&
        (_lastAppliedTrafficLightY! - y).abs() < 0.5) {
      return;
    }
    _lastAppliedTrafficLightY = y;
    const types = [
      NSWindowButtonType.closeButton,
      NSWindowButtonType.miniaturizeButton,
      NSWindowButtonType.zoomButton,
    ];
    for (var i = 0; i < types.length; i++) {
      await macos_win.WindowManipulator.overrideStandardWindowButtonPosition(
        buttonType: types[i],
        offset: Offset(originals[i], y),
      );
    }
  }

  static Future<void> init() async {
    // Native window configuration must follow the real HOST OS, not the
    // rendered platform. A screenshot build can render Windows *chrome* on a
    // macOS host (CliArgs.emulateWindows overrides Platform.instance to
    // Windows; see main.dart), but the underlying NSWindow must still be set up
    // as macOS — otherwise it is left misconfigured (wrong size, uncapturable).
    // `currentHost` is unaffected by the override; gate on !kIsWeb so the web
    // build (where currentHost may report the browser's OS) does no native
    // setup, exactly as the previous `isMacOS || isWindows` guards did.
    final macHost = !kIsWeb && Platform.instance.currentHost == Platforms.macOS;
    final winHost =
        !kIsWeb && Platform.instance.currentHost == Platforms.windows;
    final emulatingWindows = macHost && Platform.instance.isWindows;

    // Initialize cross-platform window manager on desktop platforms
    if (macHost || winHost) {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
    }

    // Initialize macOS-specific window styling (runs on a macOS host even when
    // emulating Windows chrome — the NSWindow is physically macOS).
    if (macHost) {
      await WindowManipulator.initialize(enableWindowDelegate: false);
      await WindowManipulator.setMaterial(
        NSVisualEffectViewMaterial.windowBackground,
      );
      await WindowManipulator.enableFullSizeContentView();
      await WindowManipulator.makeTitlebarTransparent();
      await WindowManipulator.hideTitle();
      await WindowManipulator.addToolbar();
      await WindowManipulator.setToolbarStyle(
        toolbarStyle: NSWindowToolbarStyle.unifiedCompact,
      );

      if (emulatingWindows) {
        // Rendered chrome is Windows: the Flutter-drawn caption buttons
        // (_WindowControls, top-right) stand in, so hide the macOS traffic
        // lights and use the Windows header inset. alignTrafficLightsToHeader
        // is a no-op under the override (its isMacOS guard is false), so the
        // hidden buttons are never repositioned back on screen.
        await WindowManipulator.hideCloseButton();
        await WindowManipulator.hideMiniaturizeButton();
        await WindowManipulator.hideZoomButton();
        toolbarHeight = 32.0;
        // ~138px for 3 caption buttons (46px each)
        toolbarPadding = const EdgeInsets.only(right: 138);
      } else {
        toolbarHeight = await macos_win.WindowManipulator.getTitlebarHeight();
        const buttonTypes = [
          NSWindowButtonType.closeButton,
          NSWindowButtonType.miniaturizeButton,
          NSWindowButtonType.zoomButton,
        ];
        final buttonRects = [
          for (final type in buttonTypes)
            await macos_win.WindowManipulator.getStandardWindowButtonPosition(
              buttonType: type,
            ),
        ];
        _trafficLightOriginalX = [for (final r in buttonRects) r.left];
        toolbarPadding = EdgeInsets.only(left: buttonRects.last.right);
      }
    } else if (winHost) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: true,
      );
      toolbarHeight = 32.0;
      // ~138px for 3 native buttons (46px each)
      toolbarPadding = const EdgeInsets.only(right: 138);
    } else {
      toolbarHeight = 32.0;
      toolbarPadding = const EdgeInsets.all(0);
    }

    // Restore window state after platform styling (especially toolbar) is
    // applied, so macOS doesn't shift the window to accommodate the toolbar.
    if (macHost || winHost) {
      await _restoreWindowState();
      // The macOS window is kept hidden at launch (see MainFlutterWindow.swift
      // `order(_:relativeTo:)` override) so the user doesn't see the default
      // Nib frame flash to the saved size. Show it now that the saved bounds
      // have been applied. window_manager's `show(inactive: true)` silently
      // drops the flag on macOS and always activates the app — stealing
      // focus from the editor that ran `flutter run`. Use our own method
      // channel that calls `orderFront(nil)` so the window appears without
      // bringing Plot to the foreground.
      if (macHost) {
        const channel = MethodChannel('day.plot.app/window');
        await channel.invokeMethod<void>('showInactive');
      } else {
        await windowManager.show();
      }
    }
  }

  static Future<void> _restoreWindowState() async {
    try {
      final prefs = ProfilePreferences.instance;

      // Get screen info to validate restored position
      final displays = await screenRetriever.getAllDisplays();
      final primaryDisplay = await screenRetriever.getPrimaryDisplay();

      // Get saved window state
      final savedX = prefs.getDouble('window_x');
      final savedY = prefs.getDouble('window_y');
      final savedWidth = prefs.getDouble('window_width');
      final savedHeight = prefs.getDouble('window_height');

      // Find the display the saved position lands on. We clamp against that
      // display's visible size rather than the primary's — on macOS the
      // built-in screen is usually primary even when the window lives on a
      // taller external monitor, so primary-based clamping would trim the
      // height on every restart.
      Display? savedDisplay;
      if (savedX != null && savedY != null) {
        for (final d in displays) {
          final pos = d.visiblePosition;
          final size = d.visibleSize;
          if (pos == null || size == null) continue;
          final bounds = Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
          if (bounds.contains(Offset(savedX, savedY))) {
            savedDisplay = d;
            break;
          }
        }
      }

      // Set default size if no saved state
      double width = savedWidth ?? 1200;
      double height = savedHeight ?? 800;

      final clampDisplay = savedDisplay ?? primaryDisplay;
      final maxWidth = clampDisplay.visibleSize!.width;
      final maxHeight = clampDisplay.visibleSize!.height;
      width = width.clamp(400, maxWidth);
      height = height.clamp(300, maxHeight);

      log.info(
        'Restoring window: saved=${savedWidth?.toStringAsFixed(0)}x'
        '${savedHeight?.toStringAsFixed(0)} at '
        '${savedX?.toStringAsFixed(0)},${savedY?.toStringAsFixed(0)}; '
        'visible=${maxWidth.toStringAsFixed(0)}x${maxHeight.toStringAsFixed(0)}; '
        'applying ${width.toStringAsFixed(0)}x${height.toStringAsFixed(0)}',
      );

      await windowManager.setSize(Size(width, height));

      // Only restore position if it was saved and is valid
      if (savedX != null && savedY != null) {
        // Check if the saved position is visible on any current display
        bool isPositionValid = false;
        for (final display in displays) {
          final bounds = Rect.fromLTWH(
            display.visiblePosition!.dx,
            display.visiblePosition!.dy,
            display.visibleSize!.width,
            display.visibleSize!.height,
          );

          // Check if at least part of the window would be visible
          final windowRect = Rect.fromLTWH(savedX, savedY, width, height);
          if (bounds.overlaps(windowRect)) {
            isPositionValid = true;
            break;
          }
        }

        if (isPositionValid) {
          await windowManager.setPosition(Offset(savedX, savedY));
        }
      }

      // Set minimum size
      await windowManager.setMinimumSize(const Size(400, 300));
    } catch (e, t) {
      log.warning('Failed to restore window state', e, t);
    }
  }

  static Future<void> _saveWindowState() async {
    try {
      final prefs = ProfilePreferences.instance;
      final size = await windowManager.getSize();
      final position = await windowManager.getPosition();

      log.fine(
        'Saving window: ${size.width.toStringAsFixed(0)}x'
        '${size.height.toStringAsFixed(0)} at '
        '${position.dx.toStringAsFixed(0)},${position.dy.toStringAsFixed(0)}',
      );

      await prefs.setDouble('window_width', size.width);
      await prefs.setDouble('window_height', size.height);
      await prefs.setDouble('window_x', position.dx);
      await prefs.setDouble('window_y', position.dy);
    } catch (e, t) {
      log.warning('Failed to save window state', e, t);
      // Ignore save errors
    }
  }

  const Window({required this.child, super.key});

  final Widget child;

  @override
  WindowState createState() => WindowState();
}

class WindowState extends State<Window> with WindowListener {
  late final AppLifecycleListener _lifecycleListener;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // Restore keyboard focus into the app when the window regains focus.
    // macOS parks focus on the root scope after Cmd+Tab, which silently kills
    // every global shortcut (Cmd+K, Cmd+/, …) and leaves no editable focus
    // owner. Self-gates to desktop. See [FocusKeeper].
    FocusKeeper.instance.start();
    // Handle Cmd+Q and system-initiated termination (not covered by
    // onWindowClose which only fires for the window close button).
    // Closes the database before allowing exit to prevent FFI crashes
    // in the Drift isolate worker during VM shutdown.
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: _onExitRequested,
    );
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _lifecycleListener.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  // Debounce frame-change saves so we don't write on every pixel of a live
  // drag-resize, but still capture the final state after macOS Sequoia
  // tiling (which is programmatic and fires `windowDidResize` only).
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () {
      Window._saveWindowState();
    });
  }

  Future<AppExitResponse> _onExitRequested() async {
    _saveDebounce?.cancel();
    await Window._saveWindowState();
    // Hide the window before the (potentially slow) shutdown work so the
    // user perceives an instant quit. `Store.stop()` can take up to ~5s
    // draining in-flight sync operations before closing SQLite; without
    // this, the window stays on screen the whole time.
    await _hideWindowForShutdown();
    await _runShutdownWithWatchdog();
    return AppExitResponse.exit;
  }

  // Best-effort hide. Failures here must not block shutdown — if hiding
  // fails (e.g. on a platform where it's a no-op), we still want to
  // continue closing the store and exiting.
  Future<void> _hideWindowForShutdown() async {
    if (!Platform.instance.isMacOS && !Platform.instance.isWindows) return;
    try {
      await windowManager.hide();
    } catch (e, t) {
      log.warning('Failed to hide window during shutdown', e, t);
    }
  }

  // Runs `Store.stop()` + instance-lock release with a hard deadline, then
  // force-exits the process. `_drainActiveOperations` inside Store.stop has
  // its own 5s cap, but the surrounding steps (Drift's SQLite close,
  // file-lock release) are unbounded — a wedged FFI call could hang the
  // await forever and leave the process running invisibly after the window
  // is hidden. Budget = drain cap (5s) + comfortable slack for close/release.
  //
  // `io.exit(0)` is unconditional (not just on timeout) because returning to
  // AppKit's natural shutdown triggers `FlutterEngine shutDownEngine` →
  // `Dart::Cleanup`, which calls `Dart_ShutdownIsolate` on the still-living
  // Drift background isolate. `RunAndCleanupFinalizersOnShutdown` then fires
  // every pending NativeFinalizer in that isolate — including statement
  // finalizers in `package:sqlite3`'s statement cache whose `sqlite3_stmt*`
  // belongs to a connection that `sqlite3_close_v2` has already freed (no
  // ordering guarantee between sibling finalizers). The resulting
  // sqlite3_finalize on a stale pointer crashes the process. Exiting before
  // VM teardown skips the finalizer pass entirely.
  //
  // The companion guard lives in `AppDelegate.swift`:
  // `applicationShouldTerminateAfterLastWindowClosed` returns `false`. Without
  // it, `_hideWindowForShutdown()` below would order the window out, AppKit
  // would schedule its terminate-after-last-window timer on the next runloop
  // tick, and that timer would call `[NSApplication terminate:]` long before
  // we reach `io.exit(0)` — racing us straight into the crash described
  // above.
  Future<void> _runShutdownWithWatchdog() async {
    const watchdog = Duration(seconds: 8);
    try {
      await Future.any([
        () async {
          await Store.stop();
          if (instanceLock != null) {
            await instanceLock!.release();
          }
        }(),
        Future<void>.delayed(watchdog).then((_) {
          throw TimeoutException('Shutdown exceeded ${watchdog.inSeconds}s');
        }),
      ]);
    } catch (e, t) {
      log.warning('Shutdown work did not finish in time', e, t);
    }
    io.exit(0);
  }

  // Use `onWindowResize` (no -d) for resize: it maps to `windowDidResize`,
  // which fires for all frame changes including programmatic ones (macOS
  // Sequoia tiling). The past-tense `onWindowResized` only fires after a
  // USER drag-resize ends, so it misses tiling.
  //
  // For move, use `onWindowMoved` (past-tense): it maps to `windowDidMove`,
  // which also fires for programmatic moves. The non-`d` variant maps to
  // `windowWillMove`, which fires BEFORE the move (so the frame is still
  // the old position) and only for user-driven drags.
  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowMaximize() {
    Window._saveWindowState();
  }

  @override
  void onWindowUnmaximize() {
    Window._saveWindowState();
  }

  @override
  void onWindowClose() async {
    _saveDebounce?.cancel();
    await Window._saveWindowState();

    // Hide the window immediately so the user perceives an instant close
    // while the (potentially slow) store shutdown runs in the background.
    await _hideWindowForShutdown();

    // Closes the database, releases the instance lock, then `io.exit(0)`s
    // (see method doc for why we exit eagerly). `windowManager.destroy()`
    // below is unreachable on success, but kept as a fallback in case the
    // platform somehow returns from the force-exit.
    await _runShutdownWithWatchdog();

    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      // Frosted NSVisualEffectView sits below Flutter's content; the
      // priority-tinted gradient on top tints its gray vibrancy. We can't
      // strip the frost entirely (Flutter's Metal layer doesn't honor
      // isOpaque=false reliably on macOS, so a fully clear window renders
      // black instead of translucent), so this hybrid is as translucent as
      // the platform supports today.
      macOSBuilder: (_) => VisualEffectSubviewContainer(
        alphaValue: 1,
        material: NSVisualEffectViewMaterial.underWindowBackground,
        state: NSVisualEffectViewState.followsWindowActiveState,
        // Due to the fact that visual effect subviews cannot be updated while
        // the window is being resized, doing so can cause visual artifacts.
        // To hide those artifacts, the container adds a large negative
        // margin to the visual effect subview.
        padding: const EdgeInsets.all(-2000.0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: context.colour.frameBackgroundGradient,
          ),
          child: _ModalBackdropScrim(child: widget.child),
        ),
      ),
      windowsBuilder: (_) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: context.colour.frameBackgroundGradient,
        ),
        child: _ModalBackdropScrim(
          child: Stack(
            children: [
              widget.child,
              const Positioned(top: 0, right: 0, child: _WindowControls()),
            ],
          ),
        ),
      ),
      builder: (_) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: context.colour.frameBackgroundGradient,
        ),
        child: _ModalBackdropScrim(child: widget.child),
      ),
    );
  }
}

/// Paints a full-window opaque underlay beneath [child] (but above the
/// window's gradient / NSVisualEffectView vibrancy) while any modal is
/// open. The modal route's `BackdropFilter` barrier samples Flutter's
/// rendered scene; without this, the translucent frame regions let OS
/// vibrancy bleed through and read as crisper / more legible than the
/// opaque squircle regions behind the same barrier. The scrim gives the
/// barrier a uniform opaque base so the blur+tint looks consistent across
/// the whole window.
class _ModalBackdropScrim extends StatelessWidget {
  const _ModalBackdropScrim({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ModalProvider.hasOpenModalsListenable,
      child: child,
      builder: (context, hasOpenModals, child) => Stack(
        fit: StackFit.expand,
        children: [
          if (hasOpenModals)
            Positioned.fill(
              child: ColoredBox(color: context.colour.background),
            ),
          child!,
        ],
      ),
    );
  }
}

class _WindowControls extends StatefulWidget {
  const _WindowControls();

  @override
  State<_WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<_WindowControls> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((maximized) {
      if (mounted) setState(() => _isMaximized = maximized);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = context.colour.brightness;
    return SizedBox(
      height: Window.windowControlsHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          WindowCaptionButton.minimize(
            brightness: brightness,
            onPressed: () => windowManager.minimize(),
          ),
          _isMaximized
              ? WindowCaptionButton.unmaximize(
                  brightness: brightness,
                  onPressed: () => windowManager.unmaximize(),
                )
              : WindowCaptionButton.maximize(
                  brightness: brightness,
                  onPressed: () => windowManager.maximize(),
                ),
          WindowCaptionButton.close(
            brightness: brightness,
            onPressed: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}
