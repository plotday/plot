import 'package:flutter/widgets.dart';

/// Provides access to a context from inside the app (below Navigator and ModalProvider).
///
/// This is used by widgets that are above the main app content (like RootMenuBar)
/// to access services like ModalProvider that are only available lower in the tree.
class AppContext {
  static final GlobalKey<State<StatefulWidget>> _key = GlobalKey();

  /// GlobalKey that should be placed on a widget inside AppShell.
  static GlobalKey<State<StatefulWidget>> get key => _key;

  /// Get the context from inside the app, or null if not available.
  static BuildContext? get context => _key.currentContext;
}
