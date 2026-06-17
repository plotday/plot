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
import 'package:plot/widget/priorities_shell.dart';
import 'package:plot/widget/priority.dart';
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/scroll_edge_fade.dart';
import 'package:plot/widget/window_controls_inset.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/sidebar_leading.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/connection_status_tile.dart';
import 'package:plot/widget/header.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
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
          : SafeArea(
              top: true,
              bottom: false,
              left: false,
              right: false,
              // The bottom nav is overlaid on top of the page (see
              // _MobileShellChrome's Stack), so reserve its measured height
              // as bottom padding. Otherwise the pinned Inbox/Everything
              // tiles at the bottom of the focuses Column are painted under
              // the nav and become unreachable when many focuses fill the
              // list. The inset already includes the bottom safe-area, which
              // is why SafeArea keeps bottom: false.
              child: Padding(
                padding: EdgeInsets.only(bottom: BottomNavInset.of(context)),
                child: const Column(
                  children: [
                    // Desktop (macOS) traffic-light clearance; nothing on mobile.
                    WindowControlsInset(),
                    Expanded(child: PrioritiesPanelContent()),
                  ],
                ),
              ),
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
        Priority? globalViewScope;
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
          // The focus the active global view (search/filter) is narrowed to;
          // null = Everything. Drives the global-view sidebar highlight.
          globalViewScope = context.select<PriorityBloc, Priority?>(
            (bloc) => bloc.state.globalViewScope,
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
        // A global view is open whenever a search or any filter is active. It
        // shows the focus-as-filter sidebar and queries globally; focus scope
        // is driven by [globalViewScope] in the bloc, not by route navigation.
        final isGlobalView = isSearching || priorityFiltering;

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
                    // The accordion expands the selected focus's role; the
                    // Everything feed expands none. Computed here (page wires
                    // Bloc state) and handed to PrioritiesList.
                    final expandedRoleId = everything ? null : selected?.roleId;
                    return Column(
                      mainAxisSize: layoutState.multiPanel
                          ? MainAxisSize.min
                          : MainAxisSize.max,
                      children: [
                        Flexible(
                          fit: layoutState.multiPanel
                              ? FlexFit.loose
                              : FlexFit.tight,
                          child: isGlobalView
                              ? _GlobalViewSidebar(
                                  root: root,
                                  scope: globalViewScope,
                                )
                              : PrioritiesList(
                                  root: root,
                                  priorities: state.priorities,
                                  roles: state.sortedRoles,
                                  selected: selected,
                                  everything: everything,
                                  expandedRoleId: expandedRoleId,
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
}

/// Flat focus-as-filter sidebar shown in place of [PrioritiesList] while a
/// global view (an active search or filter) is open. Leads with a fixed
/// "Everything" tile, then an "Inbox" tile when the Inbox owns a match, then
/// every focus that owns a matching thread (each with its full ancestry).
///
/// Tapping a tile narrows the global view to that scope via
/// [SetGlobalViewScope] — it does NOT navigate, so the search/filter stays
/// active. The highlight is driven by [scope]
/// ([PriorityBloc.globalViewScope]); `null` = Everything (the full set).
class _GlobalViewSidebar extends StatelessWidget {
  const _GlobalViewSidebar({required this.root, required this.scope});

  final Priority root;

  /// The focus the global view is narrowed to; `null` = Everything.
  final Priority? scope;

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

    // The focuses that own a thread in the current (global) feed or the
    // remote-search extras, each listed once. The Inbox (root) is surfaced
    // as its own fixed tile below, so it is tracked separately and excluded
    // here to avoid the duplicate "Inbox" row.
    final feedItems = context.select<PriorityBloc, List<AgendaItem>>(
      (bloc) => bloc.state.activityFeedItems,
    );
    final remoteExtras = context.select<PriorityBloc, List<Thread>>(
      (bloc) => bloc.state.remoteSearchExtras,
    );
    final matchPriorities = <Priority>[];
    final seen = <PriorityId>{};
    bool hasInboxMatch = false;
    void addThread(Thread t) {
      final p = t.priority;
      if (p.isInbox) {
        hasInboxMatch = true;
        return;
      }
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
    matchPriorities.sort((a, b) {
      // Stable focus ordering by the sidebar `order` column; id as a final
      // tiebreaker so ties are deterministic (path-independent).
      final byOrder = a.order.value.compareTo(b.order.value);
      return byOrder != 0
          ? byOrder
          : a.id.toString().compareTo(b.id.toString());
    });

    // Fixed Everything/Inbox tiles share the focus tiles' resting weight.
    final fixedTileStyle = itemStyle.copyWith(fontWeight: FontWeight.w400);

    return ScrollEdgeFade(
      transparent: true,
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: context.theme.spacing.md),
            // All matches — the full, unscoped global result set. Selected by
            // default (no focus scope picked).
            FixedFocusTile(
              title: 'All matches',
              icon: PlotIcon.inboxes,
              isSelected: scope == null,
              command: SetGlobalViewScope(null),
              menuCommand: null,
              hasUnread: false,
              active: false,
              borderRadius: itemBorderRadius,
              textStyle: fixedTileStyle,
              monochrome: monochrome,
            ),
            // Inbox — narrows to unfiled matches. Only when the Inbox owns one.
            if (hasInboxMatch)
              FixedFocusTile(
                title: 'Inbox',
                icon: PlotIcon.inbox,
                isSelected: scope?.id == root.id,
                command: SetGlobalViewScope(root),
                menuCommand: null,
                hasUnread: false,
                active: false,
                borderRadius: itemBorderRadius,
                textStyle: fixedTileStyle,
                monochrome: monochrome,
              ),
            for (final priority in matchPriorities)
              PriorityWidget(
                key: ValueKey('global-${priority.id}'),
                priority: priority,
                monochrome: monochrome,
                selected: scope?.id == priority.id,
                selectedBorder: true,
                borderRadius: itemBorderRadius,
                showAncestry: true,
                // The flat search list drops the sidebar's role accordion, so
                // name a focus's role when the user has more than one — without
                // it, each role's "Inbox" is indistinguishable.
                showRole: true,
                // Search results read uniformly: no active-state bold and no
                // unread dot — those cues belong to normal navigation.
                boldActive: false,
                unread: false,
                // Tap narrows the global view to this focus without navigating.
                command: SetGlobalViewScope(priority),
                textStyle: itemStyle.copyWith(
                  color: context.colour.colours.fromTheme(
                    priority.displayColor,
                  ),
                ),
              ),
            if (matchPriorities.isEmpty && !hasInboxMatch)
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
                  // Flush-left sidebar leading slot (muted → foreground on
                  // hover, matching `muted: true`), so the account tile lines
                  // up with the focus and connection tiles above it.
                  leadingBuilder: (isHovered, hasFocus) {
                    final highlighted = isHovered || hasFocus;
                    return sidebarLeading(
                      context,
                      Icon(
                        PlotIcon.account,
                        size: context.theme.iconSizes.leading,
                        color: highlighted
                            ? context.theme.colors.foreground
                            : context.theme.plotColors.muted,
                      ),
                    );
                  },
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
