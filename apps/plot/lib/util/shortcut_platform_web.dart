import 'package:web/web.dart';

/// Web implementation for detecting if the current platform is macOS
bool isMacOSWeb() {
  final userAgent = window.navigator.userAgent.toLowerCase();
  // Look for "macintosh" or "mac os" in the user agent string
  return userAgent.contains('macintosh') || userAgent.contains('mac os');
}
