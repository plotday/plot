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

  static Future<void> init() async {
    // Initialize cross-platform window manager on desktop platforms
    if (Platform.instance.isMacOS || Platform.instance.isWindows) {
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);
      await _restoreWindowState();
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
      final lastWindowButtonPos =
          await macos_win.WindowManipulator.getStandardWindowButtonPosition(
            buttonType: NSWindowButtonType.zoomButton,
          );
      toolbarPadding = EdgeInsets.only(left: lastWindowButtonPos.right);
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
      final wasMaximized = prefs.getBool('window_maximized') ?? false;

      if (wasMaximized) {
        await windowManager.maximize();
        return;
      }

      // Set default size if no saved state
      double width = savedWidth ?? 1200;
      double height = savedHeight ?? 800;

      // Validate and adjust size based on current screen's visible area
      // Use visibleSize to properly handle full-height tiled windows
      final maxWidth = primaryDisplay.visibleSize!.width;
      final maxHeight = primaryDisplay.visibleSize!.height;
      width = width.clamp(400, maxWidth);
      height = height.clamp(300, maxHeight);

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
      final isMaximized = await windowManager.isMaximized();

      await prefs.setBool('window_maximized', isMaximized);

      if (!isMaximized) {
        final size = await windowManager.getSize();
        final position = await windowManager.getPosition();

        await prefs.setDouble('window_width', size.width);
        await prefs.setDouble('window_height', size.height);
        await prefs.setDouble('window_x', position.dx);
        await prefs.setDouble('window_y', position.dy);
      }
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
    _lifecycleListener.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<AppExitResponse> _onExitRequested() async {
    await Window._saveWindowState();
    await Store.stop();
    if (instanceLock != null) {
      await instanceLock!.release();
    }
    return AppExitResponse.exit;
  }

  @override
  void onWindowResized() {
    Window._saveWindowState();
  }

  @override
  void onWindowMoved() {
    Window._saveWindowState();
  }

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
      macOSBuilder: (_) => VisualEffectSubviewContainer(
        alphaValue: 1,
        material: NSVisualEffectViewMaterial.underWindowBackground,
        state: NSVisualEffectViewState.followsWindowActiveState,
        // Due to the fact that visual effect subviews cannot be updated while the
        // window is being resized, doing so can cause visual artifacts. To hide
        // those artifacts, the TransparentMacOSBottomBar widget adds a large
        // negative margin to the visual effect subview.
        padding: const EdgeInsets.all(-2000.0),
        child: Container(color: context.colour.background, child: widget.child),
      ),
      windowsBuilder: (_) => Stack(
        children: [
          widget.child,
          const Positioned(
            top: 0,
            right: 0,
            child: _WindowControls(),
          ),
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
    return Row(
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
    );
  }
}
