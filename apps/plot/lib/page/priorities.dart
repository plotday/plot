import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';
import 'package:flutter/foundation.dart';

import 'package:plot/api/broadcast.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/user.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/priorities_list.dart';
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/header.dart';
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
        // Sync filter when local prefs change
        final prioritiesBloc = context.read<PrioritiesBloc>();
        final expectedFilter = localPrefsState.showAllPriorities ? null : false;
        if (prioritiesBloc.state.archivedFilter != expectedFilter) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            prioritiesBloc.setArchivedFilter(localPrefsState.showAllPriorities);
          });
        }

        return Scaffold(
          childPad: false,
          scrollable: false,
          header: Header(
            title: defaultTargetPlatform == TargetPlatform.macOS
                ? null
                : 'Priorities',
            commands: [
              ToggleArchivedPrioritiesFilter(
                showAllPriorities: localPrefsState.showAllPriorities,
              ),
              NewPriority(),
            ],
          ),
          body: BlocBuilder<LayoutBloc, LayoutState>(
            builder: (context, layoutState) {
              return Column(
                children: [
                  Expanded(
                    child: BlocBuilder<PrioritiesBloc, PrioritiesState>(
                      builder: (builderContext, state) {
                        return BlocBuilder<NowBloc, NowState>(
                          builder: (builderContext, priorityState) {
                            return PrioritiesList(
                              root: state.root!,
                              priorities: state.priorities,
                              selected: priorityState is NowLoaded
                                  ? priorityState.context
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
  }
}
