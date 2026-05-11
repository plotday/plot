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
import 'package:plot/widget/priorities_list.dart';
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/scroll_edge_fade.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/connection_status_tile.dart';
import 'package:plot/widget/unified_header.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';

@RoutePage(name: 'PrioritiesRoute')
class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    // In single-panel mode the Priorities tab stands alone, so it renders
    // its own UnifiedHeader (multi-panel mode hoists UnifiedHeader to the
    // priority page above the layout).
    return Scaffold(
      header: context.isMultiPanel ? null : const UnifiedHeader(),
      childPad: false,
      scrollable: false,
      body: const PrioritiesPanelContent(),
    );
  }
}

/// The priorities-list + footer body of the priorities panel, without the
/// surrounding [Scaffold]/[FScaffold] wrapping. Used directly inside the
/// left panel of the multi-panel layout so it can shrink-wrap to its
/// content height (FScaffold's internal `Expanded(child)` would otherwise
/// force the panel to fill its full allotted height).
class PrioritiesPanelContent extends StatelessWidget {
  const PrioritiesPanelContent({super.key});

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
        try {
          priorityShowArchived = context.select<PriorityBloc, bool>(
            (bloc) => bloc.state.showArchived,
          );
          prioritySearch = context.select<PriorityBloc, String>(
            (bloc) => bloc.state.search,
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

        // Sync search from PriorityBloc to PrioritiesBloc
        final search = prioritySearch ?? '';
        if (prioritiesBloc.state.search != search) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            prioritiesBloc.updateSearch(search);
          });
        }

        return BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {
            return BlocBuilder<PrioritiesBloc, PrioritiesState>(
              builder: (builderContext, state) {
                return BlocBuilder<NowBloc, NowState>(
                  builder: (builderContext, nowState) {
                    final selected = nowState is NowLoaded
                        ? nowState.context
                        : null;
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
                          child: ScrollEdgeFade(
                            child: PrioritiesList(
                              root: root,
                              priorities: state.priorities,
                              selected: selected,
                            ),
                          ),
                        ),
                          // Footer renders at the same depth as the rest
                          // of the priorities panel — no nested darkenTheme.
                          // The divider above keeps it visually separated.
                          if (layoutState.multiPanel)
                            Padding(
                              padding: EdgeInsets.only(
                                top: context.theme.spacing.sm,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border(
                                    top: BorderSide(
                                      color: context.theme.colors.border,
                                      width: 1,
                                    ),
                                  ),
                                ),
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    top: context.theme.spacing.sm,
                                  ),
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
                                              subtitle:
                                                  userState.user.primaryEmail,
                                              textStyle: context.theme.typography
                                                  .sm
                                                  .copyWith(
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                              leadingBuilder: (h, f) => Padding(
                                                padding: EdgeInsets.only(
                                                  left: context
                                                      .theme
                                                      .spacing
                                                      .lg,
                                                  right: context
                                                      .theme
                                                      .spacing
                                                      .sm,
                                                ),
                                                child: SizedBox.square(
                                                  dimension: context
                                                      .theme
                                                      .iconSizes
                                                      .base,
                                                  child: Center(
                                                    child: Icon(
                                                      PlotIcon.account,
                                                      size: context
                                                          .theme
                                                          .iconSizes
                                                          .base,
                                                      color: (h || f)
                                                          ? context
                                                                .theme
                                                                .colors
                                                                .foreground
                                                          : context
                                                                .theme
                                                                .plotColors
                                                                .muted,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              muted: true,
                                              highlightColor:
                                                  const Color(0x00000000),
                                              command: CommandWrapper(
                                                ShowSettings(),
                                                icon: Value(null),
                                              ),
                                            );
                                          }
                                          return const SizedBox.shrink();
                                        },
                                      ),
                                      SizedBox(height: 12),
                                    ],
                                  ),
                                ),
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

