// IMPORTANT: Always import this file (platform.dart) instead of platform_stub.dart or platform_web.dart directly.
// This file automatically exports the correct platform-specific implementation:
// - platform_stub.dart for native platforms (uses dart:io)
// - platform_web.dart for web (uses user agent detection)
export 'platform_stub.dart' if (dart.library.js_interop) 'platform_web.dart';
