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

  /// The current step-back handler for the single-panel new-thread flow, or
  /// null when there's no back affordance (step 1 / sections, where the
  /// bottom-nav tab is the exit). Published by [NewThreadPage] as the compose
  /// flow advances between steps; consumed by [UnifiedHeader]'s single-panel
  /// new-thread branch to render the back chevron in the header strip (so the
  /// back aligns with the PriorityPage / ThreadPage backs rather than sitting
  /// one line below in the page body).
  ///
  /// Mutated via [setNewThreadBack] so the change drives [notifyListeners] and
  /// the header (a dependent of [ThreadHeaderNotifierProvider]) rebuilds.
  VoidCallback? newThreadBack;

  /// Update [newThreadBack] and notify listeners (so the header rebuilds for
  /// the new step). No-ops when the handler is unchanged.
  void setNewThreadBack(VoidCallback? handler) {
    if (identical(newThreadBack, handler)) return;
    newThreadBack = handler;
    notifyListeners();
  }

  void Function(String)? onSearchChanged;
  void Function()? onSearchClosed;
  List<(Tag, int)> tags = const [];
  List<Tag> filter = const [];
  List<(Reaction, int)> reactions = const [];
  List<Reaction> reactionFilter = const [];
  bool isThreadVisible = false;
  bool isNewThread = false;

  void register({
    required void Function(String) onSearchChanged,
    required void Function() onSearchClosed,
    required List<(Tag, int)> tags,
    required List<Tag> filter,
    List<(Reaction, int)> reactions = const [],
    List<Reaction> reactionFilter = const [],
    bool isNewThread = false,
  }) {
    this.onSearchChanged = onSearchChanged;
    this.onSearchClosed = onSearchClosed;
    this.tags = tags;
    this.filter = filter;
    this.reactions = reactions;
    this.reactionFilter = reactionFilter;
    isThreadVisible = true;
    this.isNewThread = isNewThread;
    notifyListeners();
  }

  void unregister() {
    onSearchChanged = null;
    onSearchClosed = null;
    newThreadBack = null;
    tags = const [];
    filter = const [];
    reactions = const [];
    reactionFilter = const [];
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

  void updateReactions(
    List<(Reaction, int)> reactions,
    List<Reaction> reactionFilter,
  ) {
    this.reactions = reactions;
    this.reactionFilter = reactionFilter;
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
