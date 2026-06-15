import 'package:auto_route/auto_route.dart';

/// Tab indices for the [PrioritiesShell]'s [AutoTabsRouter]. Kept here
/// (not on [PrioritiesShell]) so the navigation helpers can be tested
/// without pulling in the widget.
class PriorityTabs {
  PriorityTabs._();

  /// Tab 0: the Priorities list (path: `/priorities`).
  static const int priorities = 0;

  /// Tab 1: the Agenda (path: `/agenda`). Default landing tab in
  /// single-panel mode.
  static const int agenda = 1;

  /// Tab 2: the Activity stack (path: `'' + /p/:priorityId`). Hosts
  /// PriorityRoute, NewThreadRoute, and ThreadRoute.
  static const int activity = 2;
}

/// Computes the new value of the cross-tab back-source tracker (consumed
/// by the priority page's PopScope to return to the originating tab on
/// the back gesture). Cross-tab arrivals (Priorities/Agenda → Activity)
/// record the originating tab so back can return there; in-tab
/// navigations (priority-to-priority while already on `/p/:id`) keep
/// the previously-recorded source so back still pops to the real
/// origin.
///
/// Returns [currentSourceTab] unchanged when the user is already on
/// the Activity tab — only cross-tab navigations update the slot.
int? computeSourceTabAfterPriorityTap({
  required int? activeTabIndex,
  required int? currentSourceTab,
}) {
  if (activeTabIndex == null) return currentSourceTab;
  if (activeTabIndex == PriorityTabs.activity) return currentSourceTab;
  return activeTabIndex;
}

/// Computes the bottom-nav tab to switch to when back is invoked from a
/// priority page. Consumes (and clears) the recorded source tab in the
/// returned tuple — the caller persists the new [nextSourceTab].
///
/// Bottom-nav taps clear the source tab so back from a tab-arrival
/// exits the app cleanly (replace semantics). Cross-tab arrivals
/// (Priorities/Agenda → Activity) push so back can return to the
/// originating tab.
///
/// Falls back to the Agenda tab when [currentSourceTab] is null
/// (deep-link arrivals).
({int targetTab, int? nextSourceTab}) computeBackTabFromPriority({
  required int? currentSourceTab,
}) {
  return (
    targetTab: currentSourceTab ?? PriorityTabs.agenda,
    nextSourceTab: null,
  );
}

/// The bottom-nav tab that should stay highlighted while the user is on
/// the Activity tab — a `/p/:id` priority page or its thread list, which
/// has no bottom-nav slot of its own. Returns the recorded drill-in
/// origin, so the highlight matches the tab the back gesture returns to
/// (see [computeBackTabFromPriority]) and the thread list keeps the
/// Focus/Agenda highlight the user came from.
///
/// Only Focus (Priorities) and Agenda drill into a priority page this
/// way; Search/More don't, and a null origin (deep-link arrival) has no
/// tab to claim — all of these return null so no item is highlighted.
int? highlightTabForActivityPage({required int? sourceTab}) {
  if (sourceTab == PriorityTabs.priorities) return PriorityTabs.priorities;
  if (sourceTab == PriorityTabs.agenda) return PriorityTabs.agenda;
  return null;
}

/// Whether the user is currently on the Activity tab (i.e. on a `/p/:id`
/// page already). Used to decide between push and replace for URL
/// history — cross-tab arrivals (Priorities/Agenda → Activity) push so
/// back can return to the source tab; in-tab navigations
/// (priority-to-priority while on `/p/:id`) mark the URL state for
/// replace so the history stays flat.
bool isOnActivityTab(TabsRouter? tabsRouter) =>
    tabsRouter?.activeIndex == PriorityTabs.activity;

/// Whether the priority the user just tapped is already at the top of
/// the Activity tab's stack (i.e. the active priority page is for the
/// same priority).
///
/// When true, the caller should avoid `root.navigate` — auto_route's
/// in-place handling with `children: null` for an already-mounted
/// PriorityRoute with the same args clears the existing inner stack
/// (`[PriorityOnlyRoute]`) without remounting it, producing a
/// forever-spinner. The caller should switch the active tab and
/// explicitly remount the inner route to refresh Android's
/// predictive-back registration.
bool isSamePriorityAtActivityTop({
  required TabsRouter? tabsRouter,
  required String targetPriorityIdString,
  required String priorityRouteName,
}) {
  if (tabsRouter == null) return false;
  final activityRouter =
      tabsRouter.stackRouterOfIndex(PriorityTabs.activity);
  if (activityRouter == null || activityRouter.stack.isEmpty) return false;
  final top = activityRouter.stack.last;
  if (top.routeData.name != priorityRouteName) return false;
  return top.routeData.params.getString('priorityId') ==
      targetPriorityIdString;
}

/// Walks the controller tree from [root] looking for the [StackRouter]
/// hosted inside [PriorityRoute]'s page (the inner AutoRouter that
/// holds PriorityOnlyRoute / NewThreadRoute / ThreadRoute).
/// [innerRouterOf] alone is non-recursive, and PriorityRoute is nested
/// several controllers deep (root → AppShell → tabs → ActivityShell →
/// PriorityRoute), so we walk explicitly.
StackRouter? findPriorityInnerRouter(
  RoutingController root,
  String priorityRouteName,
) {
  final direct = root.innerRouterOf<StackRouter>(priorityRouteName);
  if (direct != null) return direct;
  for (final child in root.childControllers) {
    final hit = findPriorityInnerRouter(child, priorityRouteName);
    if (hit != null) return hit;
  }
  return null;
}

/// Like [findPriorityInnerRouter], but scoped to the Activity tab's stack
/// router so it never resolves the Search tab's [PriorityRoute] mount.
///
/// With [PriorityRoute] mounted under BOTH the Activity tab (tab 2) and the
/// Search tab (tab 3), the root-rooted DFS in [findPriorityInnerRouter] is
/// ambiguous: it may return the Search subtree's inner router. Cross-tab
/// thread-opens from the Agenda must target the ACTIVITY stack explicitly,
/// so they walk from `tabsRouter.stackRouterOfIndex(activity)` instead of
/// the root. Returns null when the Activity tab has no [PriorityRoute]
/// mounted yet (cold start).
StackRouter? findActivityPriorityInnerRouter(
  TabsRouter tabsRouter,
  String priorityRouteName,
) {
  final activityRouter =
      tabsRouter.stackRouterOfIndex(PriorityTabs.activity);
  if (activityRouter == null) return null;
  return findPriorityInnerRouter(activityRouter, priorityRouteName);
}
