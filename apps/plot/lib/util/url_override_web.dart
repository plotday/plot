import 'package:web/web.dart';

/// Sets the browser URL to [path] without touching router state. Used to
/// show a shareable `/t/:threadId` URL while the internal router stack still
/// carries the nested `/p/:priorityId/:threadId` form (which owns rendering
/// and back-navigation).
///
/// Pass `push: true` to add a new browser history entry (so the browser's
/// back button returns to the previous URL) or `push: false` to replace the
/// current entry (for transitions where we don't want a new history frame,
/// e.g. switching between threads).
void setBrowserUrl(String path, {required bool push}) {
  if (window.location.pathname == path) return;
  if (push) {
    window.history.pushState(null, '', path);
  } else {
    window.history.replaceState(null, '', path);
  }
}
