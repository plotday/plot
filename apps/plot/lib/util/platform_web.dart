// DO NOT import this file directly! Import 'platform.dart' instead.
// This file is specifically for web platforms.
import 'package:web/web.dart';

/// Web implementation for detecting if the current platform has a physical keyboard.
/// Returns false for mobile browsers (Android, iPhone, iPad, iPod),
/// true for desktop browsers.
bool hasPhysicalKeyboard() {
  final userAgent = window.navigator.userAgent.toLowerCase();
  // Detect mobile browsers
  final isMobileBrowser = userAgent.contains('android') ||
      userAgent.contains('iphone') ||
      userAgent.contains('ipad') ||
      userAgent.contains('ipod');
  // Desktop browsers have keyboards, mobile browsers typically don't
  return !isMobileBrowser;
}

/// Web implementation for detecting if the current platform is a mobile platform.
/// Returns true for mobile browsers (Android, iPhone, iPad, iPod).
bool isMobilePlatform() {
  final userAgent = window.navigator.userAgent.toLowerCase();
  return userAgent.contains('android') ||
      userAgent.contains('iphone') ||
      userAgent.contains('ipad') ||
      userAgent.contains('ipod');
}
