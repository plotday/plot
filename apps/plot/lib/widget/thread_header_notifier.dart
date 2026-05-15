import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';

/// Bridge between ThreadBloc (which lives inside ThreadPage) and the
/// UnifiedHeader (which lives above all panels).
///
/// ThreadPage registers its search callbacks and tag data when it mounts,
/// and unregisters on dispose.
class ThreadHeaderNotifier extends ChangeNotifier {
  /// Set true by external triggers (e.g. the bottom-nav "New" button)
  /// when a navigation to NewThreadPage is *imminent* but the inner
  /// router isn't mounted yet. Allows [UnifiedHeader] to render the
  /// collapsed variant immediately, before the route change settles —
  /// otherwise the full header flashes during the cross-tab navigation
  /// while priorities_shell polls for the inner router to appear.
  /// Cleared once NewThreadPage mounts (or the route resolves elsewhere).
  static final ValueNotifier<bool> pendingNewThreadIntent =
      ValueNotifier(false);

  void Function(String)? onSearchChanged;
  void Function()? onSearchClosed;
  List<(Tag, int)> tags = const [];
  List<Tag> filter = const [];
  bool isThreadVisible = false;
  bool isNewThread = false;

  void register({
    required void Function(String) onSearchChanged,
    required void Function() onSearchClosed,
    required List<(Tag, int)> tags,
    required List<Tag> filter,
    bool isNewThread = false,
  }) {
    this.onSearchChanged = onSearchChanged;
    this.onSearchClosed = onSearchClosed;
    this.tags = tags;
    this.filter = filter;
    isThreadVisible = true;
    this.isNewThread = isNewThread;
    notifyListeners();
  }

  void unregister() {
    onSearchChanged = null;
    onSearchClosed = null;
    tags = const [];
    filter = const [];
    isThreadVisible = false;
    isNewThread = false;
    // Defer notification to avoid calling notifyListeners during dispose/unmount
    // when the widget tree is locked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      notifyListeners();
    });
  }

  void updateTags(List<(Tag, int)> tags, List<Tag> filter) {
    this.tags = tags;
    this.filter = filter;
    notifyListeners();
  }
}

class ThreadHeaderNotifierProvider extends InheritedNotifier<ThreadHeaderNotifier> {
  ThreadHeaderNotifierProvider({
    required super.child,
    super.key,
  }) : super(notifier: ThreadHeaderNotifier());

  /// Subscribe to changes (for consumers that need to rebuild on notification).
  static ThreadHeaderNotifier? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ThreadHeaderNotifierProvider>()
        ?.notifier;
  }

  /// Look up without subscribing (for producers that call register/unregister).
  static ThreadHeaderNotifier? read(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<ThreadHeaderNotifierProvider>()
        ?.notifier;
  }
}
