import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:window_manager/window_manager.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/document_title.dart';

/// Builds the window / browser-tab title for the currently viewed focus.
///
/// Format: `[Role] › [Focus] — Plot`, where the `[Role] ›` crumb is included
/// only when the user has more than one role (mirroring the in-app focus
/// label). The unscoped "Everything" feed — a null context or the root focus —
/// is just "Plot".
String windowTitleForFocus(Priority? context) {
  const app = 'Plot';
  if (context == null || context.root) return app;

  final focus = context.displayTitle;

  var prefix = '';
  if (Role.cachedCount >= 2) {
    final role = Role.fromCache(context.roleId);
    if (role != null) prefix = '${role.name}${Priority.separator}';
  }

  return '$prefix$focus — $app';
}

/// Sets the OS window title (desktop) and browser-tab title (web). A no-op on
/// mobile, where there is no window chrome to update.
void setWindowTitle(String title) {
  if (kIsWeb) {
    // Web: set the browser-tab title directly via `package:web` document.title
    // (behind a conditional import so `package:web` is never reached off web).
    setDocumentTitle(title);
    return;
  }
  // `dart:io` Platform.isX throws on web — already handled by the guard above.
  if (Platform.isMacOS || Platform.isWindows) {
    windowManager.setTitle(title);
  }
}
