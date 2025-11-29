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
