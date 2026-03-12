import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
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

        return Scaffold(
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
                      final plotPriority = state.root?.children
                          .firstWhereOrNull((p) => p.key == '@plot');

                      return Column(
                        children: [
                          if (!layoutState.multiPanel)
                            SizedBox(
                              height: MediaQuery.of(context).padding.top,
                            ),
                          Expanded(
                            child: PrioritiesList(
                              root: state.root!,
                              priorities: state.priorities,
                              selected: selected,
                              showPlotSection: false,
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
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                  child: Builder(
                                    builder: (context) {
                                      // Extract @plot children by key
                                      final gettingStarted = plotPriority
                                          ?.children
                                          .firstWhereOrNull(
                                            (c) =>
                                                c.key ==
                                                '@plot.getting-started',
                                          );
                                      final whatsNew = plotPriority?.children
                                          .firstWhereOrNull(
                                            (c) => c.key == '@whats-new',
                                          );
                                      final helpFeedback = plotPriority
                                          ?.children
                                          .firstWhereOrNull(
                                            (c) =>
                                                c.key?.startsWith(
                                                  '@help-feedback',
                                                ) ==
                                                true,
                                          );
                                      final twistDev = plotPriority?.children
                                          .firstWhereOrNull(
                                            (c) => c.key == '@plot.twist-dev',
                                          );

                                      return Column(
                                        children: [
                                          SizedBox(height: 8),
                                          // 1. Getting Started
                                          if (gettingStarted != null &&
                                              gettingStarted.archivedAt == null)
                                            ListTile(
                                              title: 'Getting started',
                                              textStyle:
                                                  context.theme.typography.sm,
                                              icon: PlotIcon.gettingStarted,
                                              muted: true,
                                              selected:
                                                  selected?.id ==
                                                  gettingStarted.id,
                                              selectedBorder: false,
                                              command: CommandWrapper(
                                                ChangeCurrentPriority(
                                                  gettingStarted,
                                                ),
                                                icon: Value(null),
                                                subtitle: Value(null),
                                              ),
                                            ),
                                          // 2. What's New
                                          if (whatsNew != null)
                                            ListTile(
                                              title: "What's New",
                                              textStyle:
                                                  context.theme.typography.sm,
                                              icon: PlotIcon.sparkles,
                                              muted: true,
                                              selected:
                                                  selected?.id == whatsNew.id,
                                              selectedBorder: false,
                                              command: CommandWrapper(
                                                OpenWhatsNew(whatsNew),
                                                icon: Value(null),
                                                subtitle: Value(null),
                                              ),
                                              leadingBuilder:
                                                  (
                                                    isHovered,
                                                    hasFocus,
                                                  ) => SizedBox(
                                                    width: 20,
                                                    child: whatsNew.unread
                                                        ? Center(
                                                            child: Container(
                                                              width: 6.0,
                                                              height: 6.0,
                                                              decoration: BoxDecoration(
                                                                color: context
                                                                    .theme
                                                                    .colors
                                                                    .foreground,
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                            ),
                                                          )
                                                        : null,
                                                  ),
                                            ),
                                          // 3. Connections + Twists
                                          ValueListenableBuilder<bool>(
                                            valueListenable: BroadcastClient
                                                .instance
                                                .connectionState,
                                            builder: (context, isConnected, _) {
                                              if (isConnected) {
                                                return ListTile(
                                                  title: 'Connections + Twists',
                                                  textStyle: context
                                                      .theme
                                                      .typography
                                                      .sm,
                                                  icon: PlotIcon.connection,
                                                  muted: true,
                                                  command: CommandWrapper(
                                                    ManageConnectionsAndTwists(),
                                                    icon: Value(null),
                                                  ),
                                                );
                                              }
                                              return ListTile(
                                                title: 'Offline',
                                                textStyle:
                                                    context.theme.typography.sm,
                                                icon: PlotIcon.offline,
                                                muted: true,
                                                command: CommandWrapper(
                                                  ShowOfflineInfo(),
                                                  icon: Value(null),
                                                ),
                                              );
                                            },
                                          ),
                                          // 3. Twist Development
                                          if (twistDev != null &&
                                              twistDev.archivedAt == null)
                                            ListTile(
                                              title: 'Twist Development',
                                              textStyle:
                                                  context.theme.typography.sm,
                                              icon: PlotIcon.code,
                                              muted: true,
                                              selected:
                                                  selected?.id == twistDev.id,
                                              selectedBorder: false,
                                              command: CommandWrapper(
                                                ChangeCurrentPriority(twistDev),
                                                icon: Value(null),
                                                subtitle: Value(null),
                                              ),
                                            ),
                                          // 4. Help + Feedback
                                          if (helpFeedback != null &&
                                              helpFeedback.archivedAt == null)
                                            ListTile(
                                              title: 'Help + Feedback',
                                              textStyle:
                                                  context.theme.typography.sm,
                                              icon: PlotIcon.help,
                                              muted: true,
                                              selected:
                                                  selected?.id ==
                                                  helpFeedback.id,
                                              selectedBorder: false,
                                              command: CommandWrapper(
                                                ChangeCurrentPriority(
                                                  helpFeedback,
                                                ),
                                                icon: Value(null),
                                                subtitle: Value(null),
                                              ),
                                              leadingBuilder:
                                                  (
                                                    isHovered,
                                                    hasFocus,
                                                  ) => SizedBox(
                                                    width: 20,
                                                    child: helpFeedback.unread
                                                        ? Center(
                                                            child: Container(
                                                              width: 6.0,
                                                              height: 6.0,
                                                              decoration: BoxDecoration(
                                                                color: context
                                                                    .theme
                                                                    .colors
                                                                    .foreground,
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                            ),
                                                          )
                                                        : null,
                                                  ),
                                            ),
                                          // 5. Account
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
