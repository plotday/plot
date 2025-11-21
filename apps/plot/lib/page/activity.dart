import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;

@RoutePage(name: "ActivityRoute")
class ActivityPage implements AutoRouteWrapper {
  ActivityPage({@PathParam("activityId") required String activityIdString})
    : activityId = ActivityId.fromShortString(activityIdString);

  final ActivityId activityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return ActivityBlocProvider(
      activityId: activityId,
      activity: null, // Let the bloc load the activity
      child: BlocConsumer<ActivityBloc, ActivityState>(
        listener: (context, state) {
          context.read<PriorityBloc>().setActivity(state.activity);
        },
        listenWhen: (previous, current) =>
            previous.activity.id != current.activity.id,
        builder: (context, state) {
          return _ActivityPageContent();
        },
      ),
    );
  }
}

class _ActivityPageContent extends StatefulWidget {
  const _ActivityPageContent();

  @override
  State<_ActivityPageContent> createState() => _ActivityPageContentState();
}

class _ActivityPageContentState extends State<_ActivityPageContent> {
  final GlobalKey<ActivityEditorState> _activityEditorKey =
      GlobalKey<ActivityEditorState>();

  // Store reference to provider to avoid unsafe ancestor lookup in dispose()
  PriorityShortcutsProviderState? _provider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Save reference during a safe lifecycle method
    _provider = ActivityPanelControllerProvider.maybeOf(context);
  }

  @override
  void dispose() {
    // Unregister from the focus coordination provider
    // Use saved reference instead of looking up during dispose()
    _provider?.unregisterActivityPanel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ActivityBloc, ActivityState>(
      listener: (context, state) {
        // Focus ActivityEditor when activity thread changes
        // (BidirectionalListSelector is keyed by activity.id, so it creates a fresh controller)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _activityEditorKey.currentState?.focus();
        });
      },
      listenWhen: (previous, current) =>
          previous.activity.id != current.activity.id,
      child: BlocBuilder<ActivityBloc, ActivityState>(
        builder: (context, state) {
          return _buildContent(context, state);
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, ActivityState state) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutStateForPanels) {
        final prefixActions = <Command>[];

        // Add back button when middle panel is not visible
        if (!layoutStateForPanels.middlePanelVisible) {
          prefixActions.add(
            CommandWrapper(
              ChangeCurrentActivity(null),
              icon: Value(PlotIcon.back),
            ),
          );
        }

        return BidirectionalListSelector(
          key: ValueKey('activity_list_${state.activity.id}'),
          reverse: true,
          builder: (context, listController) {
            // Register this ActivityPage with the global focus coordination provider
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final provider = ActivityPanelControllerProvider.maybeOf(context);
              provider?.registerActivityPanel(
                listController: listController,
                editorFocusCallback: () =>
                    _activityEditorKey.currentState?.focus(),
              );
            });

            // Use Focus with onKeyEvent instead of Shortcuts to allow Cmd-Up/Down to bubble
            return Focus(
              onKeyEvent: (node, event) {
                // Only handle key down and repeat events
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }

                // Check if any modifier keys are pressed
                final hasModifiers =
                    HardwareKeyboard.instance.isMetaPressed ||
                    HardwareKeyboard.instance.isControlPressed ||
                    HardwareKeyboard.instance.isShiftPressed ||
                    HardwareKeyboard.instance.isAltPressed;

                // Only handle plain arrow keys/enter/escape (no modifiers)
                // Cmd-Up/Down should bubble up to global PriorityPage handler
                if (!hasModifiers) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    // Reversed list: moving up visually means higher index
                    listController.moveFocus(1);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    // Reversed list: moving down visually means lower index
                    listController.moveFocus(-1);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.enter) {
                    final focusedIndex = listController.focusedIndex;
                    if (focusedIndex != null) {
                      final activity = _getActivityAtIndex(state, focusedIndex);
                      if (activity != null) {
                        context.run(
                          OpenFocusedItemActions(listController, (index) {
                            final activity = _getActivityAtIndex(state, index);
                            if (activity == null) return [];
                            return activityCommandGroups(activity, open: false);
                          }),
                        );
                        return KeyEventResult.handled;
                      }
                    }
                  }
                  if (event.logicalKey == LogicalKeyboardKey.escape) {
                    listController.clearFocus();
                    // Focus ActivityEditor after clearing item focus
                    _activityEditorKey.currentState?.focus();
                    return KeyEventResult.handled;
                  }
                }

                // Let all other events (including Cmd-Up/Down) bubble up
                return KeyEventResult.ignored;
              },
              child: CommandScope(
                commands: [
                  StaticCommandGroup(
                    title: state.activity.displayTitle,
                    commands: activityCommands(state.activity),
                  ),
                ],
                child: Scaffold(
                  scrollable: false,
                  translucent: true,
                  header: StreamBuilder<List<(Tag, int)>>(
                    stream: Activity.watchTagsForActivityThread(
                      state.activity.path,
                    ),
                    builder: (context, snapshot) {
                      final tagCommands = snapshot.data
                              ?.map((tagData) => ToggleActivityFilter(
                                    tagData.$1,
                                    context: context,
                                  ))
                              .toList() ??
                          [];

                      return Header(
                        title: state.activity.displayTitle,
                        prefixCommands: prefixActions,
                        onSearchChanged: (search) => context
                            .read<ActivityBloc>()
                            .updateSearch(search),
                        onSearchClosed: () => context
                            .read<ActivityBloc>()
                            .updateFilter([]),
                        filterCommands: tagCommands,
                        commands: [
                          ShowActivityCommands(state.activity),
                        ],
                      );
                    },
                  ),
                  body: Column(
                    children: [
                      Flexible(
                        flex: 1,
                        fit: FlexFit.tight,
                        child: _buildActivityList(
                          state,
                          listController,
                          context,
                        ),
                      ),
                      ActivityEditor(
                        key: _activityEditorKey,
                        draft: state.draft,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  int _getTotalItemCount(ActivityState state) {
    return state.activityGroups.fold(
      0,
      (count, group) => count + 1 + group.activities.length,
    );
  }

  Activity? _getActivityAtIndex(ActivityState state, int index) {
    int currentIndex = 0;

    for (final group in state.activityGroups) {
      // Check activities in this group
      for (final activity in group.activities) {
        if (currentIndex == index) {
          return activity;
        }
        currentIndex++;
      }

      // Skip date header
      currentIndex++;
    }

    return null;
  }

  Widget _buildActivityList(
    ActivityState state,
    BidirectionalListController listController,
    BuildContext context,
  ) {
    final totalItems = _getTotalItemCount(state);

    return BidirectionalList(
      controller: listController,
      scrollController: ScrollControllerContext.of(context),
      first: 0,
      count: totalItems,
      reverse: true,
      doneStart: true,
      doneEnd: true,
      fetcher: (first, count) =>
          Future<void>.value(), // No pagination needed for ActivityPage
      builder: (context, index, focusNode) {
        return _buildItemAtIndex(state, index, focusNode);
      },
    );
  }

  Widget _buildItemAtIndex(
    ActivityState state,
    int index,
    FocusNode focusNode,
  ) {
    int currentIndex = 0;

    for (final group in state.activityGroups) {
      // Check activities in this group
      for (final activity in group.activities) {
        if (currentIndex == index) {
          return ActivityDetailWidget(
            activity: activity,
            context: null,
            selected: false, // No selection on ActivityPage
            focusNode: focusNode,
            key: ValueKey(activity.id),
          );
        }
        currentIndex++;
      }

      // Check if this is the date header
      if (currentIndex == index) {
        return DayHeader(
          date: group.date,
          now: group.date == Date.today(),
          focusNode: focusNode,
          key: ValueKey('date_${group.date.hashCode}'),
        );
      }
      currentIndex++;
    }

    // Fallback - should not happen
    return const SizedBox.shrink();
  }
}
