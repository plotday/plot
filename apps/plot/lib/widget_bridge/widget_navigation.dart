import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'package:plot/main.dart' show navigatorKey;
import 'package:plot/widget/priorities_shell.dart';

/// Collaborator the widget bridge uses to surface the app from the
/// menu-bar/tray. Abstracted so tests inject a fake. The default impl brings
/// the desktop window forward then drives auto_route via [PrioritiesShell].
abstract class WidgetNavigator {
  Future<void> showWindow();
  Future<void> openThread(String threadId, String priorityId);
  Future<void> openFocus(String priorityId);
}

class DefaultWidgetNavigator implements WidgetNavigator {
  const DefaultWidgetNavigator();

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  Future<void> showWindow() async {
    if (!_isDesktop) return;
    await _showDesktopWindow();
  }

  @override
  Future<void> openThread(String threadId, String priorityId) async {
    await showWindow();
    final ctx = navigatorKey?.currentContext;
    if (ctx != null && ctx.mounted) {
      PrioritiesShell.openThread(ctx, priorityId, threadId);
    }
  }

  @override
  Future<void> openFocus(String priorityId) async {
    await showWindow();
    PrioritiesShell.openFocus(priorityId);
  }
}

Future<void> _showDesktopWindow() async {
  if (!await windowManager.isVisible()) {
    await windowManager.show();
  }
  await windowManager.focus();
}
