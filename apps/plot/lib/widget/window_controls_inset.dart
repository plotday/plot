import 'package:flutter/widgets.dart';
import 'package:platform_builder/platform_builder.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/widget/window.dart';

/// Top spacer that keeps a single-panel **tab-root** page (Focus, Agenda,
/// Search, More) clear of the desktop window controls.
///
/// These tab roots render no [UnifiedHeader], so on macOS — where the window
/// uses a full-size content view and the traffic lights float over the
/// top-left of the content — their first row would otherwise slide under the
/// controls. This reserves a band the same height as the feed/thread header
/// ([kAppHeaderHeight]) so the content starts below the lights and the lights
/// stay vertically centered exactly where the feed/thread header places them
/// (no jump when moving between a tab root and a thread).
///
/// Renders nothing when it isn't needed:
///  - **Multi-panel**: the panel headers own the window-control gutter.
///  - **Windows**: the Plot [Scaffold] already injects `_WindowsDragBar` for
///    header-less single-panel pages, so adding a band here would double up.
///  - **Mobile / web / Linux**: no app-drawn window controls overlap the
///    content; the page's own top [SafeArea] handles the status bar.
class WindowControlsInset extends StatelessWidget {
  const WindowControlsInset({super.key});

  @override
  Widget build(BuildContext context) {
    if (context.isMultiPanel || !Platform.instance.isMacOS) {
      return const SizedBox.shrink();
    }
    // Re-assert the traffic-light alignment so a cold start landing directly
    // on this tab (the feed/thread header that normally sets it never having
    // rendered) still centers the lights within the band. Idempotent — the
    // window helper de-dupes against the last applied position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Window.alignTrafficLightsToHeader(kAppHeaderHeight);
    });
    return const SizedBox(height: kAppHeaderHeight);
  }
}
