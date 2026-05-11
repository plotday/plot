import 'dart:async';
import 'dart:ui' show AppExitResponse;

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
import 'logging.dart';

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
    // Initialize cross-platform window manager on desktop platforms
    if (Platform.instance.isMacOS || Platform.instance.isWindows) {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
    }

    // Initialize macOS-specific window styling
    if (Platform.instance.isMacOS) {
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
    } else if (Platform.instance.isWindows) {
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
    if (Platform.instance.isMacOS || Platform.instance.isWindows) {
      await _restoreWindowState();
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

      // Set default size if no saved state
      double width = savedWidth ?? 1200;
      double height = savedHeight ?? 800;

      // Validate and adjust size based on current screen's visible area
      // Use visibleSize to properly handle full-height tiled windows
      final maxWidth = primaryDisplay.visibleSize!.width;
      final maxHeight = primaryDisplay.visibleSize!.height;
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
    await Store.stop();
    if (instanceLock != null) {
      await instanceLock!.release();
    }
    return AppExitResponse.exit;
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

    // Close the database before the process exits to prevent FFI crashes
    // in the Drift isolate worker during VM shutdown
    await Store.stop();

    // Release instance lock on window close
    if (instanceLock != null) {
      await instanceLock!.release();
    }

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
          child: widget.child,
        ),
      ),
      windowsBuilder: (_) => Stack(
        children: [
          widget.child,
          const Positioned(top: 0, right: 0, child: _WindowControls()),
        ],
      ),
      builder: (_) => widget.child,
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
