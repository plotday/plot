// DO NOT import this file directly! Import 'platform.dart' instead.
// This file uses dart:io which is not available on web platforms.
import 'dart:io' show Platform;

/// Non-web implementation for detecting if the current platform has a physical keyboard.
/// Returns true for desktop platforms (macOS, Windows, Linux).
bool hasPhysicalKeyboard() {
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}
