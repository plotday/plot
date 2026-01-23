import 'package:web/web.dart' as web;

/// Redirects the browser to the specified URL.
/// This causes a full page navigation, not an in-app route change.
void redirectToUrl(String url) {
  web.window.location.href = url;
}
