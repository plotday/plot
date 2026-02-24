import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';

/// Bridge between ActivityBloc (which lives inside ActivityPage) and the
/// UnifiedHeader (which lives above all panels).
///
/// ActivityPage registers its search callbacks and tag data when it mounts,
/// and unregisters on dispose.
class ActivityHeaderNotifier extends ChangeNotifier {
  void Function(String)? onSearchChanged;
  void Function()? onSearchClosed;
  List<(Tag, int)> tags = const [];
  List<Tag> filter = const [];
  bool isActivityVisible = false;

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
    isActivityVisible = true;
    notifyListeners();
  }

  void unregister() {
    onSearchChanged = null;
    onSearchClosed = null;
    tags = const [];
    filter = const [];
    isActivityVisible = false;
    notifyListeners();
  }

  void updateTags(List<(Tag, int)> tags, List<Tag> filter) {
    this.tags = tags;
    this.filter = filter;
    notifyListeners();
  }
}

class ActivityHeaderNotifierProvider extends InheritedNotifier<ActivityHeaderNotifier> {
  ActivityHeaderNotifierProvider({
    required super.child,
    super.key,
  }) : super(notifier: ActivityHeaderNotifier());

  /// Subscribe to changes (for consumers that need to rebuild on notification).
  static ActivityHeaderNotifier? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ActivityHeaderNotifierProvider>()
        ?.notifier;
  }

  /// Look up without subscribing (for producers that call register/unregister).
  static ActivityHeaderNotifier? read(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<ActivityHeaderNotifierProvider>()
        ?.notifier;
  }
}
