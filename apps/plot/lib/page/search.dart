import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
// OutlineInputBorder is the only material type used here — to recreate the
// borderless search-field chrome from UnifiedHeader's `_buildSearchField`,
// which uses the same `show`-scoped import. No material widgets are used.
import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/screenshot/scenes.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/router.dart';
import 'package:plot/widget/activity_feed_thread_row.dart';
import 'package:plot/widget/priorities_shell.dart'
    show BottomNavInset, returnFromSecondaryTab;
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/scroll_edge_fade.dart';
import 'package:plot/widget/search_footer.dart';
import 'package:plot/widget/window_controls_inset.dart';

/// Global Search tab (single-panel). Hosts its own [PriorityBloc] scoped to
/// the default/root priority in `everything: true` mode, so search spans every
/// focus. The bloc's query/search machinery produces the results we render as
/// a flat list of [ActivityFeedThreadRow] rows (so calendar-event results get
/// the same representative-occurrence resolution as the activity feed).
///
/// The bloc is provided with `setContext: false` so merely mounting this page
/// (or emitting search results) never publishes a current-focus to [NowBloc] —
/// only [PriorityPage]'s own listener does that, and we deliberately do not
/// mount [PriorityPage] here.
@RoutePage(name: 'SearchRoute')
class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  /// Bumped by the bottom-nav "Search" tap so the field (re)focuses each time
  /// the tab is shown. The Search tab is kept alive by [AutoTabsRouter], so the
  /// field's first-mount autofocus (in [_SearchViewState.initState]) fires only
  /// once — this re-triggers focus on every subsequent entry.
  static final ValueNotifier<int> focusRequest = ValueNotifier<int>(0);

  /// Request the Search field take focus (when its query is empty). Called from
  /// the bottom-nav Search slot. Safe to call when the page isn't mounted yet —
  /// the first mount focuses on its own.
  static void requestFocus() => focusRequest.value++;

  @override
  Widget build(BuildContext context) {
    return PriorityBlocProvider(
      // Scope to the user's default (root) priority via the intentional
      // `useDefault` path (no priorityId/threadId, no error fallback, no
      // WARNING on mount). `everything: true` is applied by [_SearchView]
      // once mounted so results span all focuses.
      useDefault: true,
      setContext: false,
      child: const _SearchView(),
    );
  }
}

class _SearchView extends StatefulWidget {
  const _SearchView();

  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounceTimer;
  String _lastSearchText = '';

  /// One [FocusNode] per result row, keyed by thread id. [ActivityFeedThreadRow]
  /// (and the [ThreadWidget] it wraps) expects a non-null focus node for
  /// keyboard handling, and giving each row its own node avoids the focus
  /// thrash a single shared node would cause. Created lazily as rows build and
  /// disposed together in [dispose].
  final Map<ThreadId, FocusNode> _rowFocusNodes = {};

  FocusNode _focusNodeFor(ThreadId threadId) =>
      _rowFocusNodes.putIfAbsent(threadId, FocusNode.new);

  @override
  void initState() {
    super.initState();
    // Force the spanning "Everything" feed so search covers every focus.
    final bloc = context.read<PriorityBloc>();
    bloc.setEverything(true);
    // Seed the field from any query the bloc already holds (it survives tab
    // switches via AutoTabsRouter), and only autofocus on the first entry
    // (empty query) — not when resuming a tab that already has a search.
    _searchController.text = bloc.state.search;
    _lastSearchText = bloc.state.search;
    // Focus on first mount (only when there's no resumed query), and again
    // every time the Search tab is re-entered (the bottom-nav bumps
    // [SearchPage.focusRequest], since the kept-alive tab never re-runs
    // initState).
    _focusFieldIfEmpty();
    SearchPage.focusRequest.addListener(_focusFieldIfEmpty);
    _searchController.addListener(_onSearchChanged);
    // Scene S6: pre-seed the search field so cross-source results render
    // immediately for the screenshot capture.
    final sceneQuery = Scenes.searchQuery;
    if (Scenes.active && sceneQuery != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _searchController.text = sceneQuery;
        _lastSearchText = sceneQuery;
        context.read<PriorityBloc>().updateSearch(sceneQuery);
      });
    }
  }

  /// Request focus on the search field, but only when the query is empty — a
  /// resumed tab with an existing search keeps its results visible without the
  /// keyboard popping back open.
  void _focusFieldIfEmpty() {
    if (!mounted) return;
    if (_searchController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    SearchPage.focusRequest.removeListener(_focusFieldIfEmpty);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    for (final node in _rowFocusNodes.values) {
      node.dispose();
    }
    _debounceTimer?.cancel();
    super.dispose();
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
      _debounceTimer = Timer(const Duration(milliseconds: 500), _dispatchSearch);
    }
  }

  void _dispatchSearch() {
    if (!mounted) return;
    context.read<PriorityBloc>().executeSearch(_searchController.text);
  }

  /// Open a result inside the Search tab. Pushes a [PriorityRoute] +
  /// [ThreadRoute] onto the Search stack — [PriorityWrapper] supplies every
  /// provider [ThreadPage] needs, the bar hides (4 URL segments), and Back
  /// pops past the priority route to these results.
  void _openThread(Thread thread) {
    context.pushRoute(
      PriorityRoute(
        priorityIdString: thread.priority.id.toShortString(),
        children: [
          ThreadRoute(threadIdString: thread.id.toShortString()),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        // Intercept the single-panel back gesture: the Search tab sits at the
        // root of its own navigator with nothing to pop, so without this the
        // back gesture falls through every navigator and exits the app. The
        // first back clears a typed query (results collapse back to the prompt)
        // without leaving the tab; a back on an empty field returns to the tab
        // the user came from. The Search tab only mounts single-panel (the
        // multi-panel layout searches inline in the priority panel), so no
        // layout gate is needed here.
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (_searchController.text.isNotEmpty) {
              _searchController.clear();
              return;
            }
            returnFromSecondaryTab(context);
          },
          child: _buildScaffold(context, state),
        );
      },
    );
  }

  Widget _buildScaffold(BuildContext context, PriorityState state) {
    // Match the per-focus feed (the "usual threads view"). The feed wraps
        // its list in `ScrollEdgeFade(background: context.colour.background)`,
        // which paints a solid [background] fill behind the rows (NOT the
        // darker [panelDarkestBackground], which is only the header/frame
        // shade). The Search tab renders the same [ActivityFeedThreadRow]s, so
        // it must sit on the same [background] surface — previously it had no
        // Scaffold at all and fell through to the frosted window gradient.
        // The default (non-translucent) Scaffold paints [background] for the
        // field area and, single-panel, injects the Windows drag bar / hosts
        // modals like the other tab roots; the results get the feed's exact
        // [ScrollEdgeFade] treatment (same fill + scroll-edge fades) below.
        //
        // Inset below the status bar (top) like every other single-panel tab
        // (Focus/Agenda/More). The bottom nav is overlaid as a separate layer,
        // so [bottom] is false here and the results list adds [BottomNavInset]
        // padding itself so its last row clears the bar.
        return Scaffold(
          scrollable: false,
          childPad: false,
          body: SafeArea(
            top: true,
            bottom: false,
            left: false,
            right: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Desktop (macOS) traffic-light clearance; nothing on mobile.
                const WindowControlsInset(),
                _SearchField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                ),
                Expanded(
                  child: ScrollEdgeFade(
                    background: context.colour.background,
                    child: _buildResults(context, state),
                  ),
                ),
              ],
            ),
          ),
        );
  }

  Widget _buildResults(BuildContext context, PriorityState state) {
    // The view-narrowed items already drop muted/scoped rows; in everything
    // mode (no scope, no muteOnly) this is just the raw feed.
    final items = state.activityFeedViewItems;
    final threads = <Thread>[
      for (final item in items)
        if (item is AgendaThreadItem) item.thread,
      // Remote extras: threads the server surfaced that aren't visible
      // locally. Append directly — no section header, mirroring the feed.
      ...state.remoteSearchExtras,
    ];

    final isSearching = state.search.isNotEmpty;
    final showFooter =
        isSearching &&
        (state.remoteSearchInProgress ||
            state.remoteSearchOffline ||
            (state.hasArchivedMatches && !state.showArchived));

    if (threads.isEmpty && !showFooter) {
      // Before any query: a gentle prompt. After a query with no matches and
      // the remote search settled: the empty state.
      if (!isSearching) {
        return _centeredMessage(context, 'Search across all your threads.');
      }
      if (state.activityFeedLoaded && !state.remoteSearchInProgress) {
        return _centeredMessage(context, 'No threads match your search.');
      }
      // Query armed but results still loading — keep a blank area (the footer
      // spinner covers the in-flight case once remoteSearchInProgress is set).
      return const SizedBox.shrink();
    }

    return ListView.builder(
      padding: EdgeInsets.only(bottom: BottomNavInset.of(context)),
      itemCount: threads.length + (showFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == threads.length) {
          return SearchFooter(state: state);
        }
        final thread = threads[index];
        // [onActivate] routes the row's own tap to [_openThread], which pushes
        // the Search tab's PriorityRoute→ThreadRoute stack — replacing the
        // ThreadWidget's default ChangeCurrentThread navigation (which would
        // resolve against the wrong/ambiguous PriorityRoute from the Search
        // stack and no-op).
        return ActivityFeedThreadRow(
          key: ValueKey('search_thread_${thread.id}'),
          baseThread: thread,
          selected: false,
          now: false,
          focusNode: _focusNodeFor(thread.id),
          priorityContext: thread.priority,
          isSearch: true,
          onActivate: () => _openThread(thread),
        );
      },
    );
  }

  Widget _centeredMessage(BuildContext context, String message) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.contentPaddingH,
        vertical: context.theme.spacing.xl,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.theme.plotColors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      ),
    );
  }
}

/// Borderless search prompt mirroring [UnifiedHeader]'s inline search field
/// (`_buildSearchField`): transparent fill in every state, no border, "Search…"
/// hint at body size.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final typography = context.theme.typography;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.contentPaddingH,
        vertical: context.theme.spacing.sm,
      ),
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            controller.clear();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: FTextField(
          control: .managed(controller: controller),
          focusNode: focusNode,
          hint: 'Search…',
          style: FTextFieldStyleDelta.delta(
            contentPadding: EdgeInsetsGeometryDelta.value(
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            ),
            color: FVariantsValueDelta.delta([
              FVariantValueDeltaOperation.all(const Color(0x00000000)),
              FVariantValueDeltaOperation.exact(
                {FTextFieldVariantConstraint.focused},
                const Color(0x00000000),
              ),
            ]),
            contentTextStyle: FVariantsDelta.delta([
              FVariantOperation.all(
                TextStyleDelta.delta(fontSize: typography.md.fontSize),
              ),
            ]),
            hintTextStyle: FVariantsDelta.delta([
              FVariantOperation.all(
                TextStyleDelta.delta(fontSize: typography.md.fontSize),
              ),
            ]),
            border: FVariantsValueDelta.delta([
              FVariantValueDeltaOperation.all(
                const OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.zero,
                ),
              ),
              FVariantValueDeltaOperation.exact(
                {FTextFieldVariantConstraint.focused},
                const OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
