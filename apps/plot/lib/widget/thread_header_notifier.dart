import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';

/// Bridge between ThreadBloc (which lives inside ThreadPage) and the
/// UnifiedHeader (which lives above all panels).
///
/// ThreadPage registers its search callbacks and tag data when it mounts,
/// and unregisters on dispose.
class ThreadHeaderNotifier extends ChangeNotifier {
  void Function(String)? onSearchChanged;
  void Function()? onSearchClosed;
  List<(Tag, int)> tags = const [];
  List<Tag> filter = const [];
  bool isThreadVisible = false;

  void register({
    required void Function(String) onSearchChanged,
    required void Function() onSearchClosed,
    required List<(Tag, int)> tags,
    required List<Tag> filter,
  }) {
    this.onSearchChanged = onSearchChanged;
    this.onSearchClosed = onSearchClosed;
    this.tags = tags;
    this.filter = filter;
    isThreadVisible = true;
    notifyListeners();
  }

  void unregister() {
    onSearchChanged = null;
    onSearchClosed = null;
    tags = const [];
    filter = const [];
    isThreadVisible = false;
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
