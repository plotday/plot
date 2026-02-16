/// Platform-agnostic authentication service.
///
/// On native platforms, delegates to [clerk_auth] (Dart HTTP client).
/// On web, delegates to Clerk JS (official browser SDK).
///
/// Import this file — never import the platform-specific implementations directly.
library;

export 'auth_service_interface.dart';

import 'auth_service_interface.dart';
import 'auth_service_native.dart'
    if (dart.library.js_interop) 'auth_service_web.dart';

/// Creates the platform-appropriate [AuthService] implementation.
///
/// On native: wraps `clerk_auth` with a file-based persistor.
/// On web: wraps Clerk JS (loaded via script tag in index.html).
Future<AuthService> createAuthService({
  required String publishableKey,
  String? profile,
}) {
  return createAuthServiceImpl(
    publishableKey: publishableKey,
    profile: profile,
  );
}
