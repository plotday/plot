import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/user.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/priorities_list.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/scroll_edge_fade.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/connection_status_tile.dart';
import 'package:plot/widget/header.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';

@RoutePage(name: 'PrioritiesRoute')
class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    // No per-page header on either layout. Single-panel (mobile) drops
    // the empty-title bar entirely — its only menu item (toggle archived)
    // now lives in the bottom-nav More menu. Multi-panel layouts hoist
    // UnifiedHeader to the priority page above this one.
    return Scaffold(
      header: null,
      childPad: false,
      scrollable: false,
      body: context.isMultiPanel
          ? const PrioritiesPanelContent()
          : const SafeArea(
              top: true,
              bottom: false,
              left: false,
              right: false,
              child: PrioritiesPanelContent(),
            ),
    );
  }
}

/// The priorities-list + footer body of the priorities panel, without the
/// surrounding [Scaffold]/[FScaffold] wrapping. Used directly inside the
/// left panel of the multi-panel layout so it can shrink-wrap to its
/// content height (FScaffold's internal `Expanded(child)` would otherwise
/// force the panel to fill its full allotted height).
class PrioritiesPanelContent extends StatefulWidget {
  const PrioritiesPanelContent({super.key});

  @override
  State<PrioritiesPanelContent> createState() => _PrioritiesPanelContentState();
}

class _PrioritiesPanelContentState extends State<PrioritiesPanelContent> {
  /// The view (priority + Everything flag) the user was on before a global
  /// view — search or filter — took over. Restored when search/filter
  /// clears, but only if the user did not deliberately pick a different
  /// priority meanwhile (in which case it is cleared).
  ({Priority? context, bool everything})? _viewBeforeGlobal;

  /// Tracks the previous global-view state (searching or filtering) so we
  /// can detect rising/falling edges in build.
  bool _wasGlobalActive = false;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LocalPreferencesBloc, LocalPreferencesState>(
      builder: (context, localPrefsState) {
        // PriorityBloc may not be available when the Priorities tab is
        // shown without a priority selected in a sibling route.
        // Use context.select (not context.read) so showArchived/search
        // changes trigger rebuilds of the priorities list.
        bool priorityShowArchived = false;
        String? prioritySearch;
        bool priorityFiltering = false;
        try {
          priorityShowArchived = context.select<PriorityBloc, bool>(
            (bloc) => bloc.state.showArchived,
          );
          prioritySearch = context.select<PriorityBloc, String>(
            (bloc) => bloc.state.search,
          );
          priorityFiltering = context.select<PriorityBloc, bool>(
            (bloc) =>
                bloc.state.filter.isNotEmpty ||
                bloc.state.reactionFilter.isNotEmpty ||
                bloc.state.iconFilter.isNotEmpty,
          );
        } on ProviderNotFoundException {
          // No PriorityBloc in tree — use defaults below.
        }

        // Sync archived filter: show all if local prefs say so OR if
        // the priority view is showing archived items.
        final prioritiesBloc = context.read<PrioritiesBloc>();
        final showAll =
            localPrefsState.showAllPriorities || priorityShowArchived;
        final expectedFilter = showAll ? null : false;
        if (prioritiesBloc.state.archivedFilter != expectedFilter) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            prioritiesBloc.setArchivedFilter(showAll);
          });
        }

        final search = prioritySearch ?? '';
        final isSearching = search.isNotEmpty;
        _handleGlobalViewTransition(
          context,
          isSearching: isSearching,
          isFiltering: priorityFiltering,
        );

        return BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {
            return BlocBuilder<PrioritiesBloc, PrioritiesState>(
              builder: (builderContext, state) {
                return BlocBuilder<NowBloc, NowState>(
                  builder: (builderContext, nowState) {
                    final selected = nowState is NowLoaded
                        ? nowState.context
                        : null;
                    final everything =
                        nowState is NowLoaded && nowState.everything;
                    final root = state.root;
                    if (root == null) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      mainAxisSize: layoutState.multiPanel
                          ? MainAxisSize.min
                          : MainAxisSize.max,
                      children: [
                        Flexible(
                          fit: layoutState.multiPanel
                              ? FlexFit.loose
                              : FlexFit.tight,
                          child: isSearching
                              ? _SearchMatchesList(
                                  root: root,
                                  selected: selected,
                                )
                              : PrioritiesList(
                                  root: root,
                                  priorities: state.priorities,
                                  selected: selected,
                                  everything: everything,
                                ),
                        ),
                      ],
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  /// Drive NowBloc.context off search/filter transitions so both behave the
  /// same way: querying globally and switching the highlight to the synthetic
  /// root feed, then coming back to where the user was when cleared.
  ///   - A search or filter starts: stash the current view (priority +
  ///     Everything flag) and switch the highlight to the root. A filter
  ///     opens the full Everything feed (`everything: true`); a bare search
  ///     keeps the view the user came from (Inbox-titled search, or
  ///     Everything if they were already in it), matching prior behaviour.
  ///   - The search/filter mix changes which mode the root view should be in
  ///     (e.g. a filter is added on top of a search): re-align the flag.
  ///   - The user picks a non-root priority meanwhile: clear the stash so a
  ///     later clear does not undo their pick.
  ///   - Everything clears: if the highlight is still the root, restore the
  ///     stashed view. Otherwise leave the user's pick in place.
  ///
  /// All NowBloc mutations are scheduled in a post-frame callback so they
  /// never run inside build.
  void _handleGlobalViewTransition(
    BuildContext context, {
    required bool isSearching,
    required bool isFiltering,
  }) {
    final active = isSearching || isFiltering;
    final nowBloc = context.read<NowBloc>();
    final nowState = nowBloc.state;
    if (nowState is! NowLoaded) {
      _wasGlobalActive = active;
      return;
    }
    final current = nowState.context;
    final root = context.read<PrioritiesBloc>().state.root;

    void schedule(VoidCallback fn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        fn();
      });
    }

    // Update the stash on edges first.
    if (active && !_wasGlobalActive) {
      // Entering a global view — remember where we were so we can come back.
      _viewBeforeGlobal = (context: current, everything: nowState.everything);
    } else if (active && current != null && !current.root) {
      // User picked a non-root priority while a global view was active —
      // drop the stash so clearing search/filter does not undo their pick.
      _viewBeforeGlobal = null;
    }

    if (active) {
      // A filter opens the full Everything feed; a bare search keeps the
      // view the user came from (Inbox-titled search, or Everything if they
      // were already in it), matching the pre-filter search behaviour.
      final priorEverything =
          _viewBeforeGlobal?.everything ?? nowState.everything;
      final desiredEverything = isFiltering || priorEverything;
      final entering = !_wasGlobalActive;
      final onRoot = current == null || current.root;
      // Steer the highlight to the root feed while the user is still on it
      // (or is just entering). If they navigated to a real priority we leave
      // them there — the stash was already cleared above.
      if (root != null &&
          (entering || onRoot) &&
          (current?.id != root.id || nowState.everything != desiredEverything)) {
        schedule(() => nowBloc.setContext(root, everything: desiredEverything));
      }
    } else if (_wasGlobalActive) {
      // Left every global view. Restore the stashed view, but only if the
      // user did not pick a different priority during search/filter.
      final stashed = _viewBeforeGlobal;
      _viewBeforeGlobal = null;
      if (stashed != null && (current == null || current.root)) {
        schedule(
          () => nowBloc.setContext(
            stashed.context,
            everything: stashed.everything,
          ),
        );
      }
    }

    _wasGlobalActive = active;
  }
}

/// Flat priority list shown in place of [PrioritiesList] while the user
/// has an active search. Renders the root "Everything" tile followed by
/// every priority that owns a thread in the current activity feed, each
/// with its full ancestry path (like the pinned/top section).
class _SearchMatchesList extends StatelessWidget {
  const _SearchMatchesList({required this.root, required this.selected});

  final Priority root;
  final Priority? selected;

  @override
  Widget build(BuildContext context) {
    final isLeftPanel =
        PanelPositionProvider.of(context) == HeaderPosition.left;
    final itemStyle =
        (isLeftPanel
                ? context.theme.typography.sm
                : context.theme.typography.md)
            .copyWith(fontWeight: FontWeight.w500);
    final BorderRadius? itemBorderRadius = isLeftPanel
        ? BorderRadius.circular(6)
        : null;
    final bool monochrome = isLeftPanel;

    // Pull the threads currently visible in the activity feed (after
    // remote-search hydration) and group by priority so each match-
    // bearing priority appears exactly once. Using the feed as the
    // source means picking a priority — which scopes the feed — also
    // narrows this list to that priority, matching the user-visible
    // results.
    final feedItems = context.select<PriorityBloc, List<AgendaItem>>(
      (bloc) => bloc.state.activityFeedItems,
    );
    final remoteExtras = context.select<PriorityBloc, List<Thread>>(
      (bloc) => bloc.state.remoteSearchExtras,
    );
    final matchPriorities = <Priority>[];
    final seen = <PriorityId>{};
    void addThread(Thread t) {
      final p = t.priority;
      if (seen.add(p.id)) {
        matchPriorities.add(p);
      }
    }

    for (final item in feedItems) {
      if (item is AgendaThreadItem) addThread(item.thread);
    }
    for (final t in remoteExtras) {
      addThread(t);
    }
    matchPriorities.sort((a, b) => a.path.value.compareTo(b.path.value));

    final everythingTile = _EverythingTileForSearch(
      root: root,
      isSelected: selected?.id == root.id,
      borderRadius: itemBorderRadius,
      textStyle: itemStyle,
      monochrome: monochrome,
    );

    return ScrollEdgeFade(
      transparent: true,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: context.theme.spacing.md),
            everythingTile,
            for (final priority in matchPriorities)
              PriorityWidget(
                key: ValueKey('search-${priority.id}'),
                priority: priority,
                monochrome: monochrome,
                selected: selected?.id == priority.id,
                selectedBorder: true,
                borderRadius: itemBorderRadius,
                showAncestry: true,
                boldLeaf: true,
                textStyle: itemStyle.copyWith(
                  color: context.colour.colours.fromTheme(
                    priority.displayColor,
                  ),
                ),
              ),
            if (matchPriorities.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.contentPaddingH,
                  vertical: context.theme.spacing.xl,
                ),
                child: Text(
                  'No focuses with matching threads yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.theme.plotColors.veryMuted,
                    fontSize: context.theme.typography.sm.fontSize,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Minimal "Everything" tile used inside [_SearchMatchesList]. The full
/// [PrioritiesList] variant carries hover/swipe/menu behaviour that does
/// not belong in the search view; this version only renders the highlight
/// and runs [ChangeCurrentPriority] on tap.
class _EverythingTileForSearch extends StatelessWidget {
  const _EverythingTileForSearch({
    required this.root,
    required this.isSelected,
    required this.borderRadius,
    required this.textStyle,
    required this.monochrome,
  });

  final Priority root;
  final bool isSelected;
  final BorderRadius? borderRadius;
  final TextStyle textStyle;
  final bool monochrome;

  @override
  Widget build(BuildContext context) {
    final rootAccent = context.colour.colours.fromTheme(root.displayColor);
    final rootAccentBg = monochrome
        ? context.colour.colours.backgroundFromTheme(root.displayColor)
        : null;

    return ListTile(
      title: root.title,
      command: ChangeCurrentPriority(root),
      longPressCommand: null,
      selected: isSelected,
      selectedColor: rootAccentBg,
      highlightColor: rootAccentBg,
      borderRadius: borderRadius,
      textStyle: textStyle.copyWith(color: rootAccent),
    );
  }
}

/// Connection status + account tiles shown at the bottom of the left
/// panel, below the agenda squircle. The squircle's lower edge separates
/// it from the agenda, so this widget paints no divider of its own.
class LeftPanelFooter extends StatelessWidget {
  const LeftPanelFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: context.theme.spacing.md),
      child: Column(
        children: [
          const ConnectionStatusTile(),
          BlocBuilder<UserBloc, UserState>(
            builder: (context, userState) {
              if (userState is UserReady) {
                final userName =
                    userState.user.name ??
                    userState.user.primaryEmail ??
                    'User';
                return ListTile(
                  title: userName,
                  subtitle: userState.user.primaryEmail,
                  textStyle: context.theme.typography.sm.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  icon: PlotIcon.account,
                  muted: true,
                  highlightColor: const Color(0x00000000),
                  command: CommandWrapper(ShowSettings(), icon: Value(null)),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }
}
