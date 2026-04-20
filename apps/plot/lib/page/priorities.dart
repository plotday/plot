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
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/unified_header.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';

@RoutePage(name: 'PrioritiesRoute')
class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LocalPreferencesBloc, LocalPreferencesState>(
      builder: (context, localPrefsState) {
        // PriorityBloc may not be available when the Priorities tab is
        // shown without a priority selected in a sibling route.
        // Use context.select (not context.read) so filter/search changes
        // trigger rebuilds of the priorities list.
        List<Tag>? priorityFilter;
        String? prioritySearch;
        try {
          priorityFilter = context.select<PriorityBloc, List<Tag>>(
            (bloc) => bloc.state.filter,
          );
          prioritySearch = context.select<PriorityBloc, String>(
            (bloc) => bloc.state.search,
          );
        } on ProviderNotFoundException {
          // No PriorityBloc in tree — use defaults below.
        }

        // Sync archived filter: show all if local prefs say so OR if
        // the search archive filter is active
        final prioritiesBloc = context.read<PrioritiesBloc>();
        final showAll =
            localPrefsState.showAllPriorities ||
            (priorityFilter?.contains(Tag.archived) ?? false);
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

        // In single-panel mode the Priorities tab stands alone, so it renders
        // its own UnifiedHeader (multi-panel mode hoists UnifiedHeader to the
        // priority page above the layout).
        return Scaffold(
          header: context.isMultiPanel ? null : const UnifiedHeader(),
          childPad: false,
          scrollable: false,
          body: BlocBuilder<LayoutBloc, LayoutState>(
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
                        children: [
                          Expanded(
                            child: PrioritiesList(
                              root: root,
                              priorities: state.priorities,
                              selected: selected,
                            ),
                          ),
                          if (layoutState.multiPanel)
                            FTheme(
                              data: darkenTheme(
                                context,
                                context.theme,
                                context.colour,
                                steps: 2,
                              ),
                              child: Builder(
                                builder: (context) => DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: context.theme.colors.background,
                                    border: Border(
                                      top: BorderSide(
                                        color: context.theme.colors.border,
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                  child: Builder(
                                    builder: (context) {
                                      return Column(
                                        children: [
                                          SizedBox(height: 8),
                                          BlocBuilder<UserBloc, UserState>(
                                            builder: (context, userState) {
                                              if (userState is UserReady) {
                                                final userName =
                                                    userState.user.name ??
                                                    userState
                                                        .user
                                                        .primaryEmail ??
                                                    'User';
                                                return ListTile(
                                                  title: userName,
                                                  subtitle: userState
                                                      .user
                                                      .primaryEmail,
                                                  textStyle: context
                                                      .theme
                                                      .typography
                                                      .sm,
                                                  icon: PlotIcon.account,
                                                  muted: true,
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
                                      );
                                    },
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
          ),
        );
      },
    );
  }
}

