/// Stub implementation for detecting if the current platform is macOS on web
/// This should never be called on non-web platforms
bool isMacOSWeb() {
  throw UnsupportedError('isMacOSWeb should only be called on web platforms');
}
