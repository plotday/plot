import 'package:flutter/widgets.dart';

/// Provides access to a context from inside the app (below Navigator and ModalProvider).
///
/// This is used by widgets that are above the main app content (like RootMenuBar)
/// to access services like ModalProvider that are only available lower in the tree.
class AppContext {
  static GlobalKey<State<StatefulWidget>>? _currentKey;

  /// Register the active AppShell key. Called from AppShell's initState.
  static void register(GlobalKey<State<StatefulWidget>> key) {
    _currentKey = key;
  }

  /// Unregister the AppShell key. Called from AppShell's dispose.
  static void unregister(GlobalKey<State<StatefulWidget>> key) {
    if (_currentKey == key) _currentKey = null;
  }

  /// Get the context from inside the app, or null if not available.
  static BuildContext? get context => _currentKey?.currentContext;
}
