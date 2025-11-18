import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Returns true if the current platform likely has a physical keyboard.
/// This includes desktop platforms (macOS, Windows, Linux) and web.
bool hasPhysicalKeyboard() {
  return kIsWeb ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;
}
