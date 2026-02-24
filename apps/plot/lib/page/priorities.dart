import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/api/broadcast.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/user.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/priorities_list.dart';
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/theme.dart';

@RoutePage(name: 'PrioritiesRoute')
class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LocalPreferencesBloc, LocalPreferencesState>(
      builder: (context, localPrefsState) {
        return BlocBuilder<PriorityBloc, PriorityState>(
          buildWhen: (prev, curr) =>
              prev.search != curr.search || prev.filter != curr.filter,
          builder: (context, priorityState) {
            // Sync archived filter: show all if local prefs say so OR if
            // the search archive filter is active
            final prioritiesBloc = context.read<PrioritiesBloc>();
            final showAll = localPrefsState.showAllPriorities ||
                priorityState.filter.contains(Tag.archived);
            final expectedFilter = showAll ? null : false;
            if (prioritiesBloc.state.archivedFilter != expectedFilter) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                prioritiesBloc.setArchivedFilter(showAll);
              });
            }

            // Sync search from PriorityBloc to PrioritiesBloc
            if (prioritiesBloc.state.search != priorityState.search) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                prioritiesBloc.updateSearch(priorityState.search);
              });
            }

        return Scaffold(
          childPad: false,
          scrollable: false,
          body: BlocBuilder<LayoutBloc, LayoutState>(
            builder: (context, layoutState) {
              return Column(
                children: [
                  Expanded(
                    child: BlocBuilder<PrioritiesBloc, PrioritiesState>(
                      builder: (builderContext, state) {
                        return BlocBuilder<NowBloc, NowState>(
                          builder: (builderContext, nowState) {
                            return PrioritiesList(
                              root: state.root!,
                              priorities: state.priorities,
                              selected: nowState is NowLoaded
                                  ? nowState.context
                                  : null,
                            );
                          },
                        );
                      },
                    ),
                  ),
                  if (layoutState.multiPanel)
                    FAnimatedTheme(
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
                                width: 0.5,
                              ),
                            ),
                          ),
                          child: Column(
                            children: [
                              SizedBox(height: 8),
                              ValueListenableBuilder<bool>(
                                valueListenable:
                                    BroadcastClient.instance.connectionState,
                                builder: (context, isConnected, _) {
                                  if (isConnected) {
                                    return ListTile(
                                      title: 'Twists',
                                      textStyle: context.theme.typography.sm,
                                      trailingBuilder:
                                          (isHovered, hasFocus) => Padding(
                                            padding: const EdgeInsets.only(
                                              left: 4,
                                              right: 16,
                                            ),
                                            child: Icon(
                                              PlotIcon.twist,
                                              size:
                                                  context.theme.iconSizes.sm,
                                              color: context
                                                  .theme
                                                  .colors
                                                  .mutedForeground,
                                            ),
                                          ),
                                      command: CommandWrapper(
                                        ManageTwists(),
                                        icon: Value(null),
                                      ),
                                    );
                                  }
                                  return ListTile(
                                    title: 'Offline',
                                    textStyle: context.theme.typography.sm,
                                    trailingBuilder:
                                        (isHovered, hasFocus) => Padding(
                                          padding: const EdgeInsets.only(
                                            left: 4,
                                            right: 16,
                                          ),
                                          child: Icon(
                                            PlotIcon.offline,
                                            size: context.theme.iconSizes.sm,
                                            color: context
                                                .theme
                                                .colors
                                                .mutedForeground,
                                          ),
                                        ),
                                    command: CommandWrapper(
                                      ShowOfflineInfo(),
                                      icon: Value(null),
                                    ),
                                  );
                                },
                              ),
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
                                      textStyle: context.theme.typography.sm,
                                      trailingBuilder: (isHovered, hasFocus) =>
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 4,
                                              right: 16,
                                            ),
                                            child: Icon(
                                              PlotIcon.settings,
                                              size: context.theme.iconSizes.sm,
                                              color: context
                                                  .theme
                                                  .colors
                                                  .mutedForeground,
                                            ),
                                          ),
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
          ),
        );
          },
        );
      },
    );
  }
}
