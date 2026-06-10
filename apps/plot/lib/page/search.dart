import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
// OutlineInputBorder is the only material type used here — to recreate the
// borderless search-field chrome from UnifiedHeader's `_buildSearchField`,
// which uses the same `show`-scoped import. No material widgets are used.
import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/layout.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/router.dart';
import 'package:plot/widget/spinner.dart';
import 'package:plot/widget/thread.dart';

/// Global Search tab (single-panel). Hosts its own [PriorityBloc] scoped to
/// the default/root priority in `everything: true` mode, so search spans every
/// focus. The bloc's query/search machinery produces the results we render as
/// a flat list of [ThreadWidget] rows.
///
/// The bloc is provided with `setContext: false` so merely mounting this page
/// (or emitting search results) never publishes a current-focus to [NowBloc] —
/// only [PriorityPage]'s own listener does that, and we deliberately do not
/// mount [PriorityPage] here.
@RoutePage(name: 'SearchRoute')
class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    return PriorityBlocProvider(
      // Scope to the user's default (root) priority. `everything: true` is
      // applied by [_SearchView] once mounted so results span all focuses.
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

  /// Reused per result row so [ThreadWidget] always has a non-null focus node
  /// (it expects one for keyboard handling). A single shared node is fine for a
  /// tap-driven flat list — we don't run arrow-key navigation across rows here.
  final FocusNode _rowFocusNode = FocusNode();

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
    if (bloc.state.search.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _rowFocusNode.dispose();
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SearchField(
              controller: _searchController,
              focusNode: _searchFocusNode,
            ),
            Expanded(child: _buildResults(context, state)),
          ],
        );
      },
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
      itemCount: threads.length + (showFooter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == threads.length) {
          return _SearchFooter(state: state);
        }
        final thread = threads[index];
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openThread(thread),
          child: ThreadWidget(
            key: ValueKey('search_thread_${thread.id}'),
            activity: thread,
            context: thread.priority,
            now: false,
            focusNode: _rowFocusNode,
            showSubPriority: true,
            isSearch: true,
          ),
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

/// Search footer mirroring [PriorityPage]'s `_SearchFooter`: spinner while a
/// remote search is in flight, an archived-matches hint, or an offline note.
class _SearchFooter extends StatelessWidget {
  const _SearchFooter({required this.state});

  final PriorityState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.plotColors;
    final padding = EdgeInsets.symmetric(
      horizontal: context.contentPaddingH,
      vertical: context.theme.spacing.md,
    );

    if (state.remoteSearchInProgress) {
      return Padding(
        padding: padding,
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [Spinner()],
        ),
      );
    }

    if (state.hasArchivedMatches && !state.showArchived) {
      return Padding(
        padding: padding,
        child: Align(
          alignment: Alignment.center,
          child: FButton(
            variant: FButtonVariant.ghost,
            onPress: () => context.read<PriorityBloc>().toggleShowArchived(),
            child: const Text('View archived items matching this search'),
          ),
        ),
      );
    }

    if (state.remoteSearchOffline) {
      return Padding(
        padding: padding,
        child: Text(
          'Offline — showing local matches only',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
