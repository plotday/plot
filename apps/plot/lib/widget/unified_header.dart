import 'dart:async';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:window_manager/window_manager.dart';


import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;
import 'package:plot/state/layout.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/pomodoro_ring.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/priority_selector.dart';
import 'button.dart';
import 'icon.dart';
import 'thread.dart';
import 'window.dart';

/// Selects which slice of the header to render.
///
/// [single] is the all-in-one header used in single-panel mode and as a
/// fallback. In multi-panel mode the [ResizablePanelLayout] renders the
/// [sidebar] variant at the top of the left column and the [main] variant
/// at the top of the right column — each is a complete, self-contained
/// header (no cross-region state plumbing).
enum HeaderVariant { single, sidebar, main }

/// Fixed height for every header variant. Locked to a constant so swapping
/// trailing controls (timer pill vs. plain icon button, etc.) never makes
/// the header shrink — content stays vertically centered within this band.
const double _kHeaderHeight = 44.0;

/// A single header spanning the full window width, placed above all panels.
///
/// In single-panel mode renders one combined header. In multi-panel mode
/// the panel layout instantiates one [sidebar] variant inside the left
/// column and one [main] variant inside the right column — that way the
/// outer resize divider naturally runs top-to-bottom of the window without
/// the header content having to be split across regions.
class UnifiedHeader extends StatefulWidget {
  const UnifiedHeader({this.variant = HeaderVariant.single, super.key});

  final HeaderVariant variant;

  @override
  State<UnifiedHeader> createState() => _UnifiedHeaderState();
}

class _UnifiedHeaderState extends State<UnifiedHeader> {
  bool _searchExpanded = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounceTimer;
  String _lastSearchText = '';
  PriorityShortcutsProviderState? _panelController;
  final GlobalKey _headerKey = GlobalKey();
  double? _lastMeasuredHeaderHeight;
  // Subscribed to the router so the header can collapse to its
  // NewThreadPage variant in the same frame the route changes, instead
  // of waiting for NewThreadPage's post-frame `register` callback.
  ChangeNotifier? _navHistory;
  bool _isNewThreadRoute = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _panelController = ActivityPanelControllerProvider.maybeOf(context);
    _panelController?.registerSearchToggle(_toggleSearch);
    LayoutBloc.instance?.registerSearchToggle(_toggleSearch);
    LayoutBloc.instance?.registerSearchClose(_closeSearchIfOpen);
    // No PriorityBloc when the header is used on the Priorities tab
    // (single-panel root view). That path renders the no-priority header
    // and has nothing to wire up here.
    try {
      context.read<PriorityBloc>().headerNotifier =
          ThreadHeaderNotifierProvider.read(context);
    } on ProviderNotFoundException {
      // Intentionally no-op.
    }
    // Listen on the *root* router. The inner AutoRouter (which hosts
    // NewThreadRoute) sits below UnifiedHeader, so its pushes don't
    // notify our local router's history — only the root history hears
    // every navigation across the tree.
    final history = context.router.root.navigationHistory;
    if (_navHistory != history) {
      _navHistory?.removeListener(_onRouteChanged);
      _navHistory = history;
      history.addListener(_onRouteChanged);
    }
    ThreadHeaderNotifier.pendingNewThreadIntent.removeListener(
      _onPendingNewThreadChanged,
    );
    ThreadHeaderNotifier.pendingNewThreadIntent.addListener(
      _onPendingNewThreadChanged,
    );
    _isNewThreadRoute = _computeIsNewThreadRoute();
  }

  bool _computeIsNewThreadRoute() {
    // Root `currentPath` walks the full nested-router tree, so it
    // becomes `/p/<id>/new` the moment the inner router pushes
    // NewThreadRoute — even though that route lives below us.
    return context.router.root.currentPath.endsWith('/new');
  }

  void _onRouteChanged() {
    if (!mounted) return;
    final next = _computeIsNewThreadRoute();
    // Only clear the intent flag once we've actually arrived at /new —
    // earlier route changes (the initial PriorityRoute push, the empty
    // PriorityOnlyRoute) fire before NewThreadRoute lands and we want
    // the collapsed variant to stay through all of them. priorities_shell
    // also schedules a safety-net timeout for the cancelled-navigation
    // case.
    if (next && ThreadHeaderNotifier.pendingNewThreadIntent.value) {
      ThreadHeaderNotifier.pendingNewThreadIntent.value = false;
    }
    if (next == _isNewThreadRoute) return;
    setState(() => _isNewThreadRoute = next);
  }

  void _onPendingNewThreadChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onSearchChanged() {
    final search = _searchController.text;
    if (search == _lastSearchText) return;
    _lastSearchText = search;
    context.read<PriorityBloc>().prepareSearch(search);
    if (search.isEmpty) {
      _debounceTimer?.cancel();
      _dispatchSearch();
      return;
    }
    if (_debounceTimer == null || !_debounceTimer!.isActive) {
      _debounceTimer = Timer(
        const Duration(milliseconds: 500),
        _dispatchSearch,
      );
    }
  }

  void _dispatchSearch() {
    final search = _searchController.text;
    final priorityBloc = context.read<PriorityBloc>();
    priorityBloc.executeSearch(search);
    context.read<PrioritiesBloc>().updateSearch(search);
    final notifier = ThreadHeaderNotifierProvider.read(context);
    notifier?.onSearchChanged?.call(search);
  }

  void _toggleSearch() {
    if (_searchExpanded) {
      _closeSearch();
      return;
    }
    setState(() {
      _searchExpanded = true;
      _panelController?.updateSearchExpanded(true);
    });
    _focusSearchSoon();
  }

  /// Tries to focus the search field on the next frame, retrying for a
  /// few frames if focus doesn't take. Cross-tab navigation from the
  /// bottom-nav Search button can race with the navigator's own focus
  /// management — the page mounts, the search field builds, our first
  /// `requestFocus` lands, then the navigator's post-route focus pass
  /// steals it back. Retrying across frames lets us reclaim focus once
  /// that transition settles.
  void _focusSearchSoon({int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searchExpanded) return;
      _searchFocusNode.requestFocus();
      if (!_searchFocusNode.hasFocus && attempt < 4) {
        _focusSearchSoon(attempt: attempt + 1);
      }
    });
  }

  void _closeSearchIfOpen() {
    if (_searchExpanded) _closeSearch();
  }

  void _closeSearch() {
    setState(() {
      _searchExpanded = false;
      _panelController?.updateSearchExpanded(false);
      _searchController.clear();
    });
    final priorityBloc = context.read<PriorityBloc>();
    priorityBloc.updateSearch('');
    priorityBloc.updateFilter([]);
    for (final icon in List<String>.from(priorityBloc.state.iconFilter)) {
      priorityBloc.updateIconFilter(icon);
    }
    context.read<PrioritiesBloc>().updateSearch('');
    final notifier = ThreadHeaderNotifierProvider.read(context);
    notifier?.onSearchChanged?.call('');
    notifier?.onSearchClosed?.call();
  }

  @override
  void dispose() {
    _panelController?.unregisterSearchToggle();
    LayoutBloc.instance?.unregisterSearchToggle(_toggleSearch);
    LayoutBloc.instance?.unregisterSearchClose(_closeSearchIfOpen);
    _navHistory?.removeListener(_onRouteChanged);
    ThreadHeaderNotifier.pendingNewThreadIntent.removeListener(
      _onPendingNewThreadChanged,
    );
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _scheduleTrafficLightAlignment() {
    if (!Platform.instance.isMacOS) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box =
          _headerKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final height = box.size.height;
      if (_lastMeasuredHeaderHeight != null &&
          (_lastMeasuredHeaderHeight! - height).abs() < 0.5) {
        return;
      }
      _lastMeasuredHeaderHeight = height;
      Window.alignTrafficLightsToHeader(height);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Only the variants that own the leftmost traffic-light slot publish a
    // height to the window-chrome aligner — single (single-panel mode) and
    // sidebar (multi-panel A column). [_kHeaderHeight] is the constant
    // they all hit thanks to the SizedBox wrapper below.
    final bool ownsTrafficLights = widget.variant == HeaderVariant.single ||
        widget.variant == HeaderVariant.sidebar;
    if (ownsTrafficLights) {
      _scheduleTrafficLightAlignment();
    }
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        // On the Priorities tab in single-panel mode there is no
        // PriorityBloc in scope. Render a minimal header with just
        // window-control padding and the menu.
        try {
          context.read<PriorityBloc>();
        } on ProviderNotFoundException {
          return _wrapHeader(
            context,
            layoutState,
            _buildNoPriorityHeaderChildren(context, layoutState),
            suffixes: <Widget>[
              Button.icon(_buildNoPriorityMenuCommand()),
              if (Window.toolbarPadding
                      .resolve(TextDirection.ltr)
                      .right !=
                  0)
                SizedBox(
                  width: Window.toolbarPadding
                      .resolve(TextDirection.ltr)
                      .right,
                ),
            ],
          );
        }
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) {
            final notifier = ThreadHeaderNotifierProvider.of(context);
            switch (widget.variant) {
              case HeaderVariant.single:
                return _buildSingleHeader(
                  context,
                  layoutState,
                  state,
                  notifier,
                );
              case HeaderVariant.sidebar:
                return _buildSidebarHeader(context, layoutState);
              case HeaderVariant.main:
                return _buildMainHeader(
                  context,
                  layoutState,
                  state,
                  notifier,
                );
            }
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Header shell: every variant goes through this so they share the same
  // height, the same FHeader styling, and the same drag/clip wrapping.

  Widget _wrapHeader(
    BuildContext context,
    LayoutState layoutState,
    List<Widget> titleChildren, {
    List<Widget> suffixes = const <Widget>[],
    BoxDecoration? decoration,
  }) {
    Widget header = ClipRect(
      key: _headerKey,
      child: SizedBox(
        height: _kHeaderHeight,
        child: DecoratedBox(
          decoration: decoration ?? const BoxDecoration(),
          child: FHeader(
            style: FHeaderStyleDelta.delta(
              // Header is height-locked to [_kHeaderHeight]. FHeader's
              // default padding (top:8, bottom:10 from `pagePadding`)
              // would shrink the inner title slot to ~26px — just shy
              // of FTextField's intrinsic ~30px, so opening search
              // overflows the FLabel column by exactly 4px. Zero out
              // vertical padding so the title row gets the full header
              // band; horizontal page padding is preserved.
              padding: EdgeInsetsGeometryDelta.value(
                const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
            title: Row(spacing: 8, children: titleChildren),
            suffixes: suffixes,
          ),
        ),
      ),
    );

    if (Platform.instance.isWindows) {
      header = DragToMoveArea(child: header);
    }
    return header;
  }

  // ---------------------------------------------------------------------------
  // Single-panel header: one combined row above the panel area.

  Widget _buildSingleHeader(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    ThreadHeaderNotifier? notifier,
  ) {
    final resolvedToolbarPadding = Window.toolbarPadding.resolve(
      TextDirection.ltr,
    );
    final thread = state.thread;
    final isThreadVisible = notifier?.isThreadVisible ?? false;
    // We're on (or about to be on) NewThreadPage in any of:
    //   1. The path already ends with `/new` (NewThreadPage mounted).
    //   2. NewThreadPage's notifier flag is set (post-frame register
    //      has fired).
    //   3. `middlePanelVisible` is true with no thread open — that's
    //      the PriorityOnlyRoute state right before its post-frame
    //      redirect to /new fires (multi-panel only path).
    //   4. The pending-intent flag is set by an external caller (e.g.
    //      bottom-nav "New") that knows it's navigating us to /new but
    //      hasn't gotten the inner router pushed yet.
    final isNewThread =
        _isNewThreadRoute ||
        (notifier?.isNewThread ?? false) ||
        (layoutState.middlePanelVisible && thread == null) ||
        ThreadHeaderNotifier.pendingNewThreadIntent.value;
    final hasActivity = thread != null || isThreadVisible;

    // NewThreadPage in single-panel mode: chrome lives inside the page
    // (priority chip, type chip, etc.), so the global header collapses
    // to a bare back-button row. Background matches the NewThreadPage
    // surface (which is translucent over `context.colour.background`) so
    // the header reads as part of the same canvas.
    if (isNewThread) {
      return _wrapHeader(
        context,
        layoutState,
        [
          if (resolvedToolbarPadding.left != 0)
            SizedBox(width: resolvedToolbarPadding.left),
          Button.icon(
            CommandWrapper(
              ChangeCurrentThread(null),
              icon: Value(PlotIcon.back),
            ),
          ),
          const Expanded(child: SizedBox.shrink()),
        ],
        suffixes: <Widget>[
          if (resolvedToolbarPadding.right != 0)
            SizedBox(width: resolvedToolbarPadding.right),
        ],
        decoration: BoxDecoration(color: context.colour.background),
      );
    }

    final List<Widget> leading = [
      if (resolvedToolbarPadding.left != 0)
        SizedBox(width: resolvedToolbarPadding.left),
      if (hasActivity)
        Button.icon(
          CommandWrapper(ChangeCurrentThread(null), icon: Value(PlotIcon.back)),
        ),
    ];

    final Widget titleSection;
    if (_searchExpanded) {
      titleSection = _buildSearchField(context, layoutState, state, notifier);
    } else if (thread != null) {
      titleSection = _buildThreadTitleSection(context, thread);
    } else {
      titleSection = _buildTitleSection(
        context,
        layoutState,
        state,
        alignLeft: true,
      );
    }

    // Single-panel: thread actions live in the header (no squircle).
    final trailing = <Widget>[
      if (thread != null) ..._buildActiveTagToggles(context, thread),
      if (thread != null) _buildTodoToggle(context, thread),
      if (thread != null && !thread.isReadOnly) Button.icon(EditThread(thread)),
      if (thread != null && !thread.isReadOnly)
        SharedCommandButton(thread: thread),
      // Single-panel: search lives in the bottom nav, not the header.
      Button.icon(
        _buildPriorityAndThreadMenuCommand(state, layoutState, notifier),
      ),
      if (resolvedToolbarPadding.right != 0)
        SizedBox(width: resolvedToolbarPadding.right),
    ];

    final decoration = BoxDecoration(
      color: context.colour.panelDarkestBackground,
      border: Border(
        bottom: BorderSide(color: context.theme.colors.border, width: 1),
      ),
    );

    return _wrapHeader(
      context,
      layoutState,
      [...leading, titleSection],
      suffixes: trailing,
      decoration: decoration,
    );
  }

  // ---------------------------------------------------------------------------
  // Multi-panel sidebar header (left column).

  Widget _buildSidebarHeader(
    BuildContext context,
    LayoutState layoutState,
  ) {
    final resolvedToolbarPadding = Window.toolbarPadding.resolve(
      TextDirection.ltr,
    );
    return _wrapHeader(
      context,
      layoutState,
      <Widget>[
        if (resolvedToolbarPadding.left != 0)
          SizedBox(width: resolvedToolbarPadding.left),
        const Expanded(child: SizedBox.shrink()),
        Button.icon(ToggleLeftSidebarCommand(isVisible: true)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Multi-panel main header (right column). One piece: leading open-sidebar
  // (when sidebar is hidden) + left-aligned title + tracking pill +
  // trailing new-thread / search / menu. Thread-specific buttons live
  // inside the thread squircle below, not here.

  Widget _buildMainHeader(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    ThreadHeaderNotifier? notifier,
  ) {
    final resolvedToolbarPadding = Window.toolbarPadding.resolve(
      TextDirection.ltr,
    );
    final showOpenSidebar = !layoutState.leftPanelVisible;

    final List<Widget> leading = [
      // When the sidebar is hidden the main column is the leftmost — it
      // also owns the macOS traffic-light gap.
      if (showOpenSidebar && resolvedToolbarPadding.left != 0)
        SizedBox(width: resolvedToolbarPadding.left),
      if (showOpenSidebar)
        Button.icon(ToggleLeftSidebarCommand(isVisible: false)),
    ];

    final Widget titleSection = _searchExpanded
        ? _buildSearchField(context, layoutState, state, notifier)
        : _buildTitleSection(
            context,
            layoutState,
            state,
            alignLeft: true,
          );

    final List<Widget> trailing = <Widget>[
      _searchButton(),
      if (!state.context.isTwistDev) Button.icon(NewThread()),
      Button.icon(_buildPriorityMenuCommand(state)),
      if (resolvedToolbarPadding.right != 0)
        SizedBox(width: resolvedToolbarPadding.right),
    ];

    return _wrapHeader(
      context,
      layoutState,
      [...leading, titleSection],
      suffixes: trailing,
    );
  }

  /// Wraps a text-bearing widget so its bounding box hugs the actual
  /// glyph metrics — the default text line box includes half-leading
  /// above ascent and below descent, which makes a Row of "text + icon"
  /// look mis-centered (the icon's box is tight; the text's is taller).
  /// Removing leading via [TextHeightBehavior] lets [CrossAxisAlignment]
  /// .center actually align the visible glyphs.
  static Widget _tightTextBox({required Widget child}) {
    return DefaultTextStyle.merge(
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
      child: child,
    );
  }

  Widget _searchButton() {
    // Keep the header-side button as the search icon even while search is
    // expanded — the close affordance lives inside the input as an X.
    return Button.icon(
      ToggleSearchCommand(searchExpanded: false, onToggle: _toggleSearch),
    );
  }

  /// Builds the title widget (priority/event title + tracking pill).
  /// When [alignLeft] is true the title hugs the start of its slot;
  /// otherwise it centers.
  Widget _buildTitleSection(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state, {
    required bool alignLeft,
  }) {
    final alignment = alignLeft
        ? Alignment.centerLeft
        : Alignment.center;

    Widget withTrackingPill(Widget title) {
      if (state.context.isTwistDev) return title;
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Strip the line box's leading/trailing half-leading so the
          // visible glyphs of the priority title vertically center
          // against the tracking icon/pill — without this the text box
          // includes descender space the icon's box doesn't, and the
          // text reads as nudged up by a couple of pixels.
          Flexible(child: _tightTextBox(child: title)),
          const SizedBox(width: 8),
          _PriorityHeaderTrackingControl(priority: state.context),
        ],
      );
    }

    final IconData scopeCaret = state.hideSubPriorities
        ? FontAwesomeIcons.chevronDown
        : FontAwesomeIcons.chevronRight;
    void toggleScope() => context.run(
      ToggleHideSubPriorities(context: context),
    );

    return Expanded(
      child: Align(
        alignment: alignment,
        child: BlocBuilder<NowBloc, NowState>(
          buildWhen: (prev, next) {
            final p = prev is NowLoaded ? prev.currentEvent : null;
            final n = next is NowLoaded ? next.currentEvent : null;
            return p?.id != n?.id ||
                p?.displayTitle != n?.displayTitle;
          },
          builder: (context, nowState) {
            final currentEvent =
                nowState is NowLoaded ? nowState.currentEvent : null;
            if (currentEvent != null) {
              return withTrackingPill(
                Text(
                  currentEvent.displayTitle,
                  overflow: TextOverflow.ellipsis,
                  // Drop the line box's half-leading; the wrapper in
                  // [withTrackingPill] supplies a default, but Text
                  // ignores that whenever it's set explicitly here.
                  textHeightBehavior: const TextHeightBehavior(
                    applyHeightToFirstAscent: false,
                    applyHeightToLastDescent: false,
                  ),
                  style: context.theme.typography.sm.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.theme.colors.foreground,
                  ),
                ),
              );
            }
            if (!layoutState.multiPanel) {
              return withTrackingPill(
                PriorityLabel(
                  priority: state.context,
                  boldLeaf: true,
                  leafTrailingIcon: scopeCaret,
                  onLeafTap: toggleScope,
                ),
              );
            }
            return withTrackingPill(
              PrioritySelector(
                selected: state.context,
                onSelect: (p) => context.run(ChangeCurrentPriority(p)),
                leafTrailingIcon: scopeCaret,
                onLeafTap: toggleScope,
              ),
            );
          },
        ),
      ),
    );
  }

  /// Single-panel thread title shown in place of the priority title +
  /// tracking pill while a thread is open. The thread body has no header
  /// of its own in single-panel mode, so this surfaces the thread's
  /// title up in the global header.
  Widget _buildThreadTitleSection(BuildContext context, Thread thread) {
    return Expanded(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          thread.displayTitle,
          overflow: TextOverflow.ellipsis,
          // Match the priority-title path: drop half-leading so the
          // glyphs sit at the visual center of the header band.
          textHeightBehavior: const TextHeightBehavior(
            applyHeightToFirstAscent: false,
            applyHeightToLastDescent: false,
          ),
          style: context.theme.typography.sm.copyWith(
            fontWeight: FontWeight.w600,
            color: context.theme.colors.foreground,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField(
    BuildContext context,
    LayoutState layoutState,
    PriorityState state,
    ThreadHeaderNotifier? notifier,
  ) {
    List<Command> buildFilters(BuildContext ctx) {
      final allTags = <Tag, (Tag, int)>{};
      for (final tagData in state.tags) {
        allTags[tagData.$1] = tagData;
      }
      if (notifier?.isThreadVisible == true) {
        for (final tagData in notifier!.tags) {
          allTags.putIfAbsent(tagData.$1, () => tagData);
        }
      }
      return [
        ...state.iconCounts.map((d) => ToggleIconFilter(d.$1, context: ctx)),
        ...allTags.keys.map((tag) => ToggleActivityFilter(tag, context: ctx)),
        ...state.filter
            .where((tag) => !allTags.containsKey(tag))
            .map((tag) => ToggleActivityFilter(tag, context: ctx)),
      ];
    }

    final hasActiveFilters =
        state.filter.isNotEmpty ||
        state.iconFilter.isNotEmpty ||
        (notifier?.filter.isNotEmpty == true);

    return Expanded(
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  _closeSearch();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: FTextField(
                control: .managed(controller: _searchController),
                focusNode: _searchFocusNode,
                hint: 'Search…',
                style: FTextFieldStyleDelta.delta(
                  contentPadding: EdgeInsetsGeometryDelta.value(
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  ),
                ),
                suffixBuilder: (context, style, states) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (buildFilters(context).isNotEmpty)
                        Button.icon(
                          PickFilterCommand(
                            filterCommandsBuilder: buildFilters,
                          ),
                          selected: hasActiveFilters,
                        ),
                      Button.icon(
                        ToggleSearchCommand(
                          searchExpanded: true,
                          onToggle: _closeSearch,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds the calendar + todo state toggle buttons matching ThreadWidget's
  /// leading icon behavior.
  Widget _buildTodoToggle(BuildContext context, Thread thread) {
    final threadColor = context.colour.colours.fromTheme(
      thread.priority.displayColor,
    );
    final isTodo = thread.todo;
    final isScheduled = isTodo && thread.isFuture;

    final calendarIcon = Button.icon(
      CommandWrapper(
        PickScheduleThread(thread),
        icon: Value(PlotIcon.schedule),
        title: 'Schedule',
      ),
      selected: isScheduled,
      selectedColor: threadColor,
    );

    final Widget todoIcon;
    if (!isTodo) {
      todoIcon = Button.icon(
        CommandWrapper(StartThread(thread), icon: Value(PlotIcon.addTodo)),
      );
    } else {
      todoIcon = Button.icon(
        CommandWrapper(
          FinishThread(thread),
          icon: Value(FontAwesomeIcons.circle),
          hoverIcon: Value(FontAwesomeIcons.circleCheck),
          title: 'Finish',
        ),
        selected: true,
        selectedColor: threadColor,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [todoIcon, calendarIcon],
    );
  }

  List<Widget> _buildActiveTagToggles(BuildContext context, Thread thread) {
    return thread.tags.keys
        .where((tag) {
          if (tag == Tag.todo) return false;
          if (!tag.addable) return false;
          if (tag == Tag.reply) {
            return thread.tags[tag]?.contains(Base.actorId) ?? false;
          }
          return true;
        })
        .take(3)
        .map((tag) => Button.icon(ToggleThreadTag(thread, tag)))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // No-priority fallback (Priorities tab) — shared by every variant since
  // it sits outside the [PriorityBloc] scope.

  List<Widget> _buildNoPriorityHeaderChildren(
    BuildContext context,
    LayoutState layoutState,
  ) {
    final resolvedToolbarPadding = Window.toolbarPadding.resolve(
      TextDirection.ltr,
    );
    return <Widget>[
      if (resolvedToolbarPadding.left != 0)
        SizedBox(width: resolvedToolbarPadding.left),
      const Expanded(child: SizedBox.shrink()),
    ];
  }

  Command _buildNoPriorityMenuCommand() {
    return ShowCommands(
      title: 'Menu',
      icon: PlotIcon.menu,
      commandsBuilder: (context) async {
        final showAll = context
            .read<LocalPreferencesBloc>()
            .state
            .showAllPriorities;
        return Commands(
          groups: [
            StaticCommandGroup(
              title: 'View',
              commands: [
                ToggleArchivedPrioritiesFilter(showAllPriorities: showAll),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Single-panel menu: thread-level commands + priority-level commands
  /// combined, since the squircle row doesn't exist.
  Command _buildPriorityAndThreadMenuCommand(
    PriorityState state,
    LayoutState layoutState,
    ThreadHeaderNotifier? notifier,
  ) {
    return ShowCommands(
      title: 'Menu',
      icon: PlotIcon.menu,
      commandsBuilder: (context) async {
        final thread = state.thread;
        final priorityBloc = context.read<PriorityBloc?>();
        final priorityGroups = currentPriorityCommandGroups(
          state.thread?.priority ?? state.context,
          context: context,
          nowState: context.read<NowBloc?>()?.state,
        );
        final threadGroups = thread != null
            ? await threadCommandGroups(thread, priorityBloc: priorityBloc)
            : <StaticCommandGroup>[];
        return Commands(
          groups: [...threadGroups, ...priorityGroups],
        );
      },
    );
  }

  /// Multi-panel main-header menu: priority-level commands only. Thread
  /// commands live in the thread squircle's own "..." menu.
  Command _buildPriorityMenuCommand(PriorityState state) {
    return ShowCommands(
      title: 'Menu',
      icon: PlotIcon.menu,
      commandsBuilder: (context) async {
        final priorityGroups = currentPriorityCommandGroups(
          state.context,
          context: context,
          nowState: context.read<NowBloc?>()?.state,
        );
        return Commands(groups: priorityGroups);
      },
    );
  }
}

/// Compact time-tracking pill in the priority header.
///
/// Sits beside the header title and reads as one unit with it. Two states:
///
/// Pomodoro-style countdown pill that lives next to the priority title.
///
/// Three visible states, all derived from
/// `NowLoaded.pomodoroState`:
/// * **Inactive** — outline pill with a play glyph + planned duration.
///   Tap to start a session; +/− (on hover) stage the duration.
/// * **Active** — outline pill with a clockwise progress ring tracing
///   elapsed/planned, label showing rounded-up remaining minutes. Tap
///   to pause (the remaining time is preserved so a later Start picks
///   up exactly where it left off). `+` snaps remaining UP to the next
///   [kPomodoroStep] boundary; `−` shaves the same step off, or snaps
///   remaining to [kMinPomodoro] when less than a step is left.
/// * **Grace** — pomodoro expired, session still recording for an
///   additional [kPomodoroGrace]. Label pulses "0m" against the muted
///   color. Tap to pause; + extends, − also lands through
///   [RemoveTime] (which floors at [kMinPomodoro]).
///
/// All taps run through [Command] subclasses so analytics fire and
/// keyboard shortcuts can be attached without changing the widget.
class _PriorityHeaderTrackingControl extends StatefulWidget {
  const _PriorityHeaderTrackingControl({required this.priority});

  final Priority priority;

  @override
  State<_PriorityHeaderTrackingControl> createState() =>
      _PriorityHeaderTrackingControlState();
}

class _PriorityHeaderTrackingControlState
    extends State<_PriorityHeaderTrackingControl>
    with TickerProviderStateMixin {
  bool _hovered = false;
  bool _centerHovered = false;
  late final Ticker _ticker;
  // Drives a periodic rebuild so the countdown text and progress ring
  // stay in sync with wall-clock time without depending on NowBloc to
  // emit (it doesn't refresh on its own — it only re-emits when the
  // upstream streams change).
  Duration _lastTick = Duration.zero;
  late final AnimationController _pulseController;

  // Narrow stadium pill that now only shows the countdown text. The
  // play affordance lives outside the pill as a separate header icon
  // button, freed up width that previously held the play glyph.
  static const double _pillWidth = 88;
  static const double _pillHeight = 22;
  // Ghost +/− button hit areas. Sized to abut the centered countdown
  // text on each side so every horizontal pixel of the pill is one of
  // three clear targets: −, duration/pause, +.
  static const double _buttonWidth = 22;

  @override
  void initState() {
    super.initState();
    // Tick at ~4Hz: fast enough that the rounded-up countdown flips
    // promptly at minute boundaries and the ring fill stays smooth,
    // but cheap enough to keep on a single Ticker.
    _ticker = createTicker((elapsed) {
      if (elapsed - _lastTick < const Duration(milliseconds: 250)) return;
      _lastTick = elapsed;
      if (mounted) setState(() {});
    });
    _ticker.start();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
      builder: (context, nowState) {
        if (nowState is! NowLoaded) return const SizedBox.shrink();
        // Show the pill against whichever priority is currently in
        // context — the BlocBuilder rebuilds on context changes, but
        // pomodoro state is per the context priority.
        final isContext = nowState.context?.id == widget.priority.id;
        if (!isContext) return const SizedBox.shrink();

        // Auto-display the event timer when an in-progress event for
        // the context priority exists. The skip stream lets us hide
        // the pill the moment the user pauses/stops the event timer.
        final event = nowState.inProgressEventForContext;
        if (event == null || event.scheduleId == null) {
          return _buildWithLive(context, nowState, null, null);
        }
        return StreamBuilder<Session?>(
          stream: Session.watchSkipFor(
            event.scheduleId!,
            occurrenceAt: event.at?.start,
          ),
          builder: (context, snapshot) {
            return _buildWithLive(context, nowState, event, snapshot.data);
          },
        );
      },
    );
  }

  Widget _buildWithLive(
    BuildContext context,
    NowLoaded nowState,
    Thread? inProgressEvent,
    Session? eventSkip,
  ) {
    final live = _LivePomodoro.compute(
      nowState,
      inProgressEvent: inProgressEvent,
      eventSkip: eventSkip,
    );
    final isInactive = live.state == PomodoroState.inactive;

    // When the pill collapses to the play button, the MouseRegions
    // inside _buildPill are unmounted without firing onExit, so
    // _hovered / _centerHovered would otherwise stay `true` from the
    // pause click. Next time the pill remounts, _PillLabel would
    // render the pause icon (centerHovered) instead of the duration.
    // Reset both flags so the MouseRegions re-fire onEnter cleanly
    // when the pill comes back.
    if (isInactive && (_hovered || _centerHovered)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_hovered && !_centerHovered) return;
        setState(() {
          _hovered = false;
          _centerHovered = false;
        });
      });
    }

    // Inactive: render a plain header-style "Start timer" icon
    // button. Active/grace: render the countdown pill. AnimatedSize
    // animates the trailing-widget width so the title slides
    // smoothly across the swap.
    final Widget child = isInactive
        ? Button.icon(StartTimer())
        : _buildPill(context, nowState, live);

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.centerLeft,
      child: child,
    );
  }

  /// Active/grace pill. Inactive state never reaches this method —
  /// [build] swaps in a header-style start button instead.
  Widget _buildPill(BuildContext context, NowLoaded state, _LivePomodoro live) {
    final accent = context.colour.colours.fromTheme(
      widget.priority.displayColor,
    );
    final muted = context.theme.plotColors.muted;
    final foreground = context.theme.colors.foreground;
    final isGrace = live.state == PomodoroState.grace;
    final progress = isGrace ? 1.0 : live.progress;

    final ringBackground = accent.withValues(alpha: 0.20);
    final ringForeground = accent.withValues(alpha: _hovered ? 1.0 : 0.85);
    final backgroundColor = _hovered
        ? accent.withValues(alpha: 0.08)
        : const Color(0x00000000);

    // For the event-derived pill, Pause and Stop collapse to a single
    // action: write a 'skip' marker covering the rest of the event so
    // the server finalizer credits only the engaged time. The +/−
    // buttons mutate the event's scheduled duration directly (extends
    // or shrinks the calendar event itself, not a separate pomodoro).
    final VoidCallback stopHandler = live.fromEvent
        ? () => _stopEventEarly(live.event!)
        : () => context.run(StopTimer());
    final String centerTooltip = live.fromEvent
        ? 'End event'
        : (isGrace ? 'Stop timer' : 'Pause timer');
    final ShortcutActivator? centerTooltipShortcut = live.fromEvent
        ? null
        : (isGrace ? timerEndShortcut : timerToggleShortcut);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: _pillWidth,
        height: _pillHeight,
        child: Stack(
          alignment: Alignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(999),
              ),
              child: const SizedBox.expand(),
            ),
            CustomPaint(
              size: const Size(_pillWidth, _pillHeight),
              painter: PomodoroRingPainter(
                progress: progress,
                backgroundColor: ringBackground,
                foregroundColor: ringForeground,
              ),
            ),
            // Fallback tap layer covering the full pill — for touch
            // users, where +/− are invisible (IgnorePointer-ignored)
            // and the center band doesn't span the whole pill. Lets a
            // tap anywhere on the pill still pause the timer.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: stopHandler,
              ),
            ),
            // Center band — sized exactly between the +/− hit zones so
            // hovering on +/− doesn't trigger the center swap. Owns the
            // duration text and the on-hover swap (pause icon while
            // active; stop icon + "Stop" label during grace, since the
            // pomodoro has expired and the click ends the session
            // rather than preserving remaining time).
            Positioned(
              left: _buttonWidth,
              right: _buttonWidth,
              top: 0,
              bottom: 0,
              child: MouseRegion(
                onEnter: (_) => setState(() => _centerHovered = true),
                onExit: (_) => setState(() => _centerHovered = false),
                child: FTooltip(
                  tipBuilder: (context, controller) => _TooltipText(
                    label: centerTooltip,
                    shortcut: centerTooltipShortcut,
                  ),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: stopHandler,
                    child: _PillLabel(
                      live: live,
                      accent: accent,
                      foreground: foreground,
                      pulseController: _pulseController,
                      centerHovered: _centerHovered,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _buttonWidth,
              child: live.remaining <= kMinPomodoro && !live.fromEvent
                  // Below the 5-minute floor there's nothing left to
                  // shave — the minus button becomes a Stop affordance
                  // so the position still has a useful action instead
                  // of going inert.
                  ? _HoverButton(
                      visible: _hovered,
                      icon: FontAwesomeIcons.stop,
                      color: muted,
                      hoverColor: foreground,
                      tooltip: 'Stop',
                      shortcut: live.fromEvent ? null : timerEndShortcut,
                      onTap: () => context.run(EndTimer()),
                      enabled: true,
                    )
                  : _HoverButton(
                      visible: _hovered,
                      icon: FontAwesomeIcons.minus,
                      color: muted,
                      hoverColor: foreground,
                      tooltip: live.fromEvent
                          ? 'Shorten event'
                          : (live.remaining > kPomodoroStep
                              ? 'Remove 15 minutes'
                              : 'Set to 5 minutes'),
                      shortcut: live.fromEvent ? null : timerRemoveShortcut,
                      onTap: live.fromEvent
                          ? () => _shrinkEvent(live.event!)
                          : () => context.run(RemoveTime()),
                      enabled: live.fromEvent
                          ? _canShrinkEvent(live.event!)
                          : RemoveTime().enabled(context),
                    ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: _buttonWidth,
              child: _HoverButton(
                visible: _hovered,
                icon: FontAwesomeIcons.plus,
                color: muted,
                hoverColor: foreground,
                tooltip: live.fromEvent ? 'Extend event' : 'Add time',
                shortcut: live.fromEvent ? null : timerAddShortcut,
                onTap: live.fromEvent
                    ? () => _extendEvent(live.event!)
                    : () => context.run(AddTime()),
                enabled: live.fromEvent ? true : AddTime().enabled(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Pause/Stop on the auto-displayed event timer: write a 'skip'
  /// session covering [now, event.end] so the server event finalizer
  /// clamps the eventual `source='event'` row to the engaged time and
  /// the pill hides immediately on the local client.
  Future<void> _stopEventEarly(Thread event) async {
    final scheduleId = event.scheduleId;
    final end = event.at?.end;
    if (scheduleId == null || end == null) return;
    final now = Time.now();
    if (!end.isAfter(now)) return;
    await Session.writeSkip(
      priority: event.priority,
      scheduleId: scheduleId,
      occurrenceAt: event.at?.start,
      from: now,
      to: end,
    );
  }

  Future<void> _extendEvent(Thread event) async {
    final start = event.at?.start;
    final end = event.at?.end;
    if (start == null || end == null) return;
    // Snap UP to the next 15-minute boundary of duration so repeated
    // presses produce predictable steps, matching how AddTime advances
    // the pomodoro window.
    final currentSeconds = end.difference(start).inSeconds;
    final stepSeconds = kPomodoroStep.inSeconds;
    final ceiledMinutes = (currentSeconds + 59) ~/ 60;
    final ceiledSeconds = ceiledMinutes * 60;
    final nextSeconds =
        ((ceiledSeconds ~/ stepSeconds) + 1) * stepSeconds;
    await SetThreadDuration(event, Duration(seconds: nextSeconds))
        .run(context);
  }

  bool _canShrinkEvent(Thread event) {
    final start = event.at?.start;
    final end = event.at?.end;
    if (start == null || end == null) return false;
    final now = Time.now();
    // Allow shrinking only down to "ends now" — never to a point in the
    // past, since the event is currently in progress.
    final minDuration = now.difference(start);
    return end.difference(start) > minDuration;
  }

  Future<void> _shrinkEvent(Thread event) async {
    final start = event.at?.start;
    final end = event.at?.end;
    if (start == null || end == null) return;
    final now = Time.now();
    final minDuration = now.difference(start);
    final current = end.difference(start);
    final candidate = current - kPomodoroStep;
    final newDuration = candidate < minDuration ? minDuration : candidate;
    if (newDuration <= Duration.zero) return;
    if (newDuration == current) return;
    await SetThreadDuration(event, newDuration).run(context);
  }
}

/// Snapshot of the pomodoro at a specific [Time.now()] moment.
///
/// `NowLoaded.now` is frozen at the moment the bloc last emitted, so
/// `state.pomodoroProgress` / `state.pomodoroRemaining` would only
/// advance when an upstream stream pushed. The pill needs sub-minute
/// updates (smooth ring fill, prompt countdown flips at the minute
/// boundary), so the pill recomputes these values from `Time.now()` on
/// every frame tick.
class _LivePomodoro {
  const _LivePomodoro({
    required this.state,
    required this.remaining,
    required this.progress,
    this.fromEvent = false,
    this.event,
  });

  final PomodoroState state;
  final Duration remaining;
  final double progress;

  /// True when this snapshot was synthesized from an in-progress
  /// scheduled event rather than an explicit `source='active'` session.
  /// Drives the pill's pause/stop and ±15m handlers to operate on the
  /// event (writing a 'skip' marker / mutating the schedule duration)
  /// instead of the session.
  final bool fromEvent;

  /// The in-progress event this snapshot was derived from, if any. Only
  /// set when [fromEvent] is true.
  final Thread? event;

  /// Computes the live snapshot from [loaded].
  ///
  /// Resolution:
  ///   1. An active `source='active'` session for the context priority
  ///      drives the regular pomodoro state machine (active/grace/inactive).
  ///   2. Otherwise, if there's an in-progress scheduled event for the
  ///      context priority and the user hasn't already opted out via a
  ///      'skip' marker, synthesize an active state from the event
  ///      window. `pomodoroAt = event.start`, `pomodoro = event.duration`.
  ///   3. Otherwise inactive.
  static _LivePomodoro compute(
    NowLoaded loaded, {
    Thread? inProgressEvent,
    Session? eventSkip,
  }) {
    final session = loaded.session;
    final ctx = loaded.context;
    final hasActiveSession =
        session != null
        && ctx != null
        && session.archivedAt == null
        && session.source == 'active'
        && session.priority?.id == ctx.id
        && session.at.isNow()
        && session.pomodoroAt != null
        && session.pomodoro != null;
    if (hasActiveSession) {
      final now = Time.now();
      final pomodoroAt = session.pomodoroAt!;
      final pomodoro = session.pomodoro!;
      final end = pomodoroAt.add(pomodoro);
      final graceEnd = end.add(kPomodoroGrace);

      if (!now.isBefore(graceEnd)) {
        return const _LivePomodoro(
          state: PomodoroState.inactive,
          remaining: Duration.zero,
          progress: 0,
        );
      }
      if (!now.isBefore(end)) {
        return const _LivePomodoro(
          state: PomodoroState.grace,
          remaining: Duration.zero,
          progress: 1,
        );
      }
      final remaining = end.difference(now);
      final totalMs = pomodoro.inMilliseconds;
      final elapsedMs = now.difference(pomodoroAt).inMilliseconds;
      final ratio =
          totalMs <= 0 ? 1.0 : (elapsedMs / totalMs).clamp(0.0, 1.0);
      return _LivePomodoro(
        state: PomodoroState.active,
        remaining: remaining.isNegative ? Duration.zero : remaining,
        progress: ratio,
      );
    }

    // Auto-displayed event timer: synthesize from the in-progress event
    // when present and not opted out via a 'skip' marker.
    if (inProgressEvent != null
        && eventSkip == null
        && inProgressEvent.at?.start != null
        && inProgressEvent.at?.end != null) {
      final now = Time.now();
      final start = inProgressEvent.at!.start!;
      final end = inProgressEvent.at!.end!;
      if (now.isBefore(end) && !now.isBefore(start)) {
        final total = end.difference(start);
        final remaining = end.difference(now);
        final elapsed = now.difference(start);
        final ratio = total.inMilliseconds <= 0
            ? 1.0
            : (elapsed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        return _LivePomodoro(
          state: PomodoroState.active,
          remaining: remaining,
          progress: ratio,
          fromEvent: true,
          event: inProgressEvent,
        );
      }
    }

    return const _LivePomodoro(
      state: PomodoroState.inactive,
      remaining: Duration.zero,
      progress: 0,
    );
  }
}

/// Centered label for the pill. Picks one of these rendering branches:
///   * Hover (grace)  → stop glyph + "Stop" label (foreground). The
///     click ends the expired session rather than preserving remaining
///     time, so the affordance differs from the active-state pause.
///   * Hover (active) → pause glyph (foreground)
///   * Grace          → pulsing `0m`
///   * Active         → `Nm` (remaining, rounded up)
class _PillLabel extends StatelessWidget {
  const _PillLabel({
    required this.live,
    required this.accent,
    required this.foreground,
    required this.pulseController,
    required this.centerHovered,
  });

  final _LivePomodoro live;
  final Color accent;
  final Color foreground;
  final AnimationController pulseController;
  final bool centerHovered;

  @override
  Widget build(BuildContext context) {
    final pomoState = live.state;
    final fontSize = context.theme.typography.sm.fontSize;

    final Widget child = centerHovered
        ? _buildHoverContent(pomoState, fontSize)
        : _buildDurationContent(pomoState, fontSize);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: KeyedSubtree(
        key: ValueKey<bool>(centerHovered),
        child: child,
      ),
    );
  }

  Widget _buildHoverContent(PomodoroState pomoState, double? fontSize) {
    if (pomoState == PomodoroState.grace) {
      return Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(FontAwesomeIcons.stop, size: 9, color: foreground),
            const SizedBox(width: 5),
            Text(
              'Stop',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
                color: foreground,
                height: 1,
              ),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Icon(FontAwesomeIcons.pause, size: 10, color: foreground),
    );
  }

  Widget _buildDurationContent(PomodoroState pomoState, double? fontSize) {
    if (pomoState == PomodoroState.grace) {
      return Center(
        child: AnimatedBuilder(
          animation: pulseController,
          builder: (context, _) {
            // Pulse between accent and a muted accent so "0m" reads as
            // urgent without strobing.
            final color = Color.lerp(
              accent.withValues(alpha: 0.30),
              accent,
              Curves.easeInOut.transform(pulseController.value),
            )!;
            return Text(
              '0m',
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
                color: color,
                height: 1,
              ),
            );
          },
        ),
      );
    }

    return Center(
      child: Text(
        _formatMinutes(live.remaining),
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: accent,
          height: 1,
        ),
      ),
    );
  }

  /// Round up to the nearest minute and format as `Nm` / `Hh Mm`.
  /// Zero clamps to `0m` so the grace pulse always has text to lerp.
  static String _formatMinutes(Duration d) {
    if (d <= Duration.zero) return '0m';
    final totalMinutes =
        (d.inSeconds + 59) ~/ 60; // ceil
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
}

/// Ghost +/- button. Fades in only while the pill is hovered. Sized to
/// fill its parent's height; the glyph is centered inside it.
///
/// Tracks its own hover and swaps from [color] (rest) to [hoverColor]
/// when the cursor is directly over it — matches the header-icon
/// pattern so the three pill regions (−, duration, +) read as distinct
/// clickable targets.
class _HoverButton extends StatefulWidget {
  const _HoverButton({
    required this.visible,
    required this.icon,
    required this.color,
    required this.hoverColor,
    required this.tooltip,
    required this.onTap,
    required this.enabled,
    this.shortcut,
  });

  final bool visible;
  final IconData icon;
  final Color color;
  final Color hoverColor;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;
  final ShortcutActivator? shortcut;

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _selfHovered = false;

  @override
  Widget build(BuildContext context) {
    final Color resolved;
    if (!widget.enabled) {
      resolved = widget.color.withValues(alpha: 0.5);
    } else {
      resolved = _selfHovered ? widget.hoverColor : widget.color;
    }
    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: widget.visible ? 1.0 : 0.0,
        child: MouseRegion(
          onEnter: (_) => setState(() => _selfHovered = true),
          onExit: (_) => setState(() => _selfHovered = false),
          child: FTooltip(
            tipBuilder: (context, controller) => _TooltipText(
              label: widget.tooltip,
              shortcut: widget.shortcut,
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.enabled ? widget.onTap : null,
              child: Center(
                child: Icon(widget.icon, size: 9, color: resolved),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tooltip body with an optional shortcut hint below the label. Mirrors
/// the [Button] tooltip layout so keyboard discovery is consistent
/// across the header pill's hover affordances and command-driven
/// icon buttons. The shortcut row is suppressed on touch-only devices
/// where the chord is unreachable.
class _TooltipText extends StatelessWidget {
  const _TooltipText({required this.label, this.shortcut});

  final String label;
  final ShortcutActivator? shortcut;

  @override
  Widget build(BuildContext context) {
    final showShortcut = shortcut != null && hasPhysicalKeyboard();
    if (!showShortcut) return Text(label);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Text(
          formatShortcut(shortcut),
          style: context.theme.typography.xs.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
  }
}
