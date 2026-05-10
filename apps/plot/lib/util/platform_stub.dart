// DO NOT import this file directly! Import 'platform.dart' instead.
// This file uses dart:io which is not available on web platforms.
import 'dart:io' show Platform;

/// Non-web implementation for detecting if the current platform has a physical keyboard.
/// Returns true for desktop platforms (macOS, Windows, Linux).
bool hasPhysicalKeyboard() {
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

/// Non-web implementation for detecting if the current platform is a mobile platform.
/// Returns true for iOS and Android platforms.
bool isMobilePlatform() {
  return Platform.isIOS || Platform.isAndroid;
}

/// True for platforms where the primary input is touch (no physical
/// keyboard). Used to switch UI affordances between hover-revealed
/// (desktop) and tap-to-modal (touch) treatments.
bool isTouchPlatform() => !hasPhysicalKeyboard();
