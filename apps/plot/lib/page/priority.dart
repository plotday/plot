import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/router.dart';
import 'priorities.dart';
import 'loading.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper implements AutoRouteWrapper {
  PriorityWrapper({@PathParam("priorityId") required String priorityIdString})
    : priorityId = PriorityId.fromShortString(priorityIdString);

  final PriorityId priorityId;
  static final Map<PriorityId, GlobalKey> _routerKeys = {};
  static GlobalKey _getRouterKey(PriorityId priorityId) {
    return _routerKeys.putIfAbsent(
      priorityId,
      () => GlobalKey(
        debugLabel: 'PriorityWrapper_${priorityId.toShortString()}',
      ),
    );
  }

  @override
  Widget wrappedRoute(BuildContext context) {
    final routerKey = _getRouterKey(priorityId);

    return PriorityBlocProvider(
      priorityId: priorityId,
      child: BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, state) {
          return CommandScope(
            commands: [
              StaticCommandGroup(
                title: state.context.title,
                commands: currentPriorityCommands(state.context),
              ),
            ],
            child: _PriorityShortcutsProvider(
              priorityId: priorityId,
              child: ResizablePanelLayout(
                left: PrioritiesPage(),
                middle: PriorityPage(priorityId: priorityId),
                child: AutoRouter(
                  key: routerKey,
                  placeholder: (context) => const LoadingPage(),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Provides global keyboard shortcuts (Cmd-Up/Down) for PriorityPage list navigation
/// that work even when focus is in ActivityPage (e.g., ActivityEditor).
class _PriorityShortcutsProvider extends StatefulWidget {
  const _PriorityShortcutsProvider({
    required this.priorityId,
    required this.child,
  });

  final PriorityId priorityId;
  final Widget child;

  @override
  State<_PriorityShortcutsProvider> createState() =>
      PriorityShortcutsProviderState();
}

class PriorityShortcutsProviderState extends State<_PriorityShortcutsProvider> {
  BidirectionalListController? _priorityListController;
  BidirectionalListController? _activityListController;
  VoidCallback? _activityEditorFocusCallback;

  void registerController(BidirectionalListController controller) {
    _priorityListController = controller;
  }

  void registerActivityPanel({
    BidirectionalListController? listController,
    VoidCallback? editorFocusCallback,
  }) {
    setState(() {
      _activityListController = listController;
      _activityEditorFocusCallback = editorFocusCallback;
    });
  }

  void unregisterActivityPanel() {
    // Just update the variables directly without setState
    // No need to rebuild when unregistering during disposal
    _activityListController = null;
    _activityEditorFocusCallback = null;
  }

  @override
  Widget build(BuildContext context) {
    return _PriorityListControllerProvider(
      state: this,
      child: ActivityPanelControllerProvider(
        state: this,
        child: BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {
            // Always register Cmd-Up/Down for Priority list navigation
            // These should take priority over ActivityPage shortcuts
            return Actions(
              actions: {
                MoveFocusUpIntent: CallbackAction<MoveFocusUpIntent>(
                  onInvoke: (_) {
                    // Only handle if we have a controller (meaning PriorityPage is visible)
                    if (_priorityListController != null) {
                      _priorityListController!.moveFocus(-1);
                    }
                    return null;
                  },
                ),
                MoveFocusDownIntent: CallbackAction<MoveFocusDownIntent>(
                  onInvoke: (_) {
                    if (_priorityListController != null) {
                      _priorityListController!.moveFocus(1);
                    }
                    return null;
                  },
                ),
                ClearItemFocusIntent: CallbackAction<ClearItemFocusIntent>(
                  onInvoke: (_) {
                    // When ActivityPage or NewActivityPage is open, Escape should focus ActivityEditor
                    _activityEditorFocusCallback?.call();
                    return null;
                  },
                ),
              },
              child: Shortcuts(
                shortcuts: <ShortcutActivator, Intent>{
                  const SingleActivator(LogicalKeyboardKey.arrowUp, meta: true):
                      const MoveFocusUpIntent(),
                  const SingleActivator(
                    LogicalKeyboardKey.arrowDown,
                    meta: true,
                  ): const MoveFocusDownIntent(),
                  // Global Escape handler - focus ActivityEditor when ActivityPage is open
                  if (_activityEditorFocusCallback != null)
                    const SingleActivator(LogicalKeyboardKey.escape):
                        const ClearItemFocusIntent(),
                  // When middle panel is hidden, also handle plain Up/Down at global level
                  if (!layoutState
                      .middlePanelVisible) ...<ShortcutActivator, Intent>{
                    const SingleActivator(LogicalKeyboardKey.arrowUp):
                        const MoveFocusUpIntent(),
                    const SingleActivator(LogicalKeyboardKey.arrowDown):
                        const MoveFocusDownIntent(),
                  },
                },
                child: widget.child,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// InheritedWidget to provide access to the shortcuts provider state
class _PriorityListControllerProvider extends InheritedWidget {
  const _PriorityListControllerProvider({
    required this.state,
    required super.child,
  });

  final PriorityShortcutsProviderState state;

  static PriorityShortcutsProviderState? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_PriorityListControllerProvider>()
        ?.state;
  }

  @override
  bool updateShouldNotify(_PriorityListControllerProvider oldWidget) => false;
}

/// InheritedWidget to provide access to ActivityPage panel state for focus coordination
class ActivityPanelControllerProvider extends InheritedWidget {
  const ActivityPanelControllerProvider({
    required this.state,
    required super.child,
    super.key,
  });

  final PriorityShortcutsProviderState state;

  static PriorityShortcutsProviderState? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ActivityPanelControllerProvider>()
        ?.state;
  }

  @override
  bool updateShouldNotify(ActivityPanelControllerProvider oldWidget) => false;
}

@RoutePage(name: "PriorityOnlyRoute")
class PriorityOnlyPage extends StatefulWidget {
  PriorityOnlyPage({
    @PathParam.inherit("priorityId") required String priorityIdString,
    super.key,
  }) : priorityId = PriorityId.fromShortString(priorityIdString);

  final PriorityId priorityId;

  @override
  State<PriorityOnlyPage> createState() => _PriorityOnlyPageState();
}

class _PriorityOnlyPageState extends State<PriorityOnlyPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final layoutState = context.read<LayoutBloc>().state;
      if (layoutState.middlePanelVisible) {
        context.router.navigate(NewActivityRoute());
      }
    });
  }

  @override
  void didUpdateWidget(PriorityOnlyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final layoutState = context.read<LayoutBloc>().state;
    if (layoutState.middlePanelVisible) {
      context.router.navigate(NewActivityRoute());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        if (layoutState.middlePanelVisible) {
          return const LoadingPage();
        }
        return PriorityPage(priorityId: widget.priorityId);
      },
    );
  }
}

class PriorityPage extends StatelessWidget {
  const PriorityPage({required this.priorityId, super.key});

  final PriorityId priorityId;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PriorityBloc, PriorityState>(
      listener: (context, state) {
        context.read<NowBloc>().setPriority(state.context);
      },
      listenWhen: (previous, current) =>
          previous.context.id != current.context.id,
      builder: (context, state) {
        // Find the index of the current activity in the agenda items
        int? selected;
        if (state.activity != null) {
          for (int i = 0; i < state.agendaItems.length; i++) {
            final activity = state.agendaItems[i].iff<Activity>(
              activity: (a) => a,
            );
            if (activity?.id == state.activity!.id) {
              selected = state.first + i;
              break;
            }
          }
        }

        return (state.agendaItems.isEmpty &&
                !(state.doneStart && state.doneEnd))
            ? const Center(child: Spinner())
            : BlocBuilder<LayoutBloc, LayoutState>(
                builder: (context, layoutState) {
                  // Build shortcuts map conditionally based on panel visibility
                  final shortcuts = <ShortcutActivator, Intent>{
                    const SingleActivator(
                      LogicalKeyboardKey.arrowUp,
                      meta: true,
                    ): const MoveFocusUpIntent(),
                    const SingleActivator(
                      LogicalKeyboardKey.arrowDown,
                      meta: true,
                    ): const MoveFocusDownIntent(),
                    const SingleActivator(LogicalKeyboardKey.enter):
                        const OpenFocusedItemActionsIntent(),
                    const SingleActivator(LogicalKeyboardKey.escape):
                        const ClearItemFocusIntent(),
                    // Always register plain Up/Down to handle focus transfer to ActivityPage
                    const SingleActivator(LogicalKeyboardKey.arrowUp):
                        const MoveFocusUpIntent(),
                    const SingleActivator(LogicalKeyboardKey.arrowDown):
                        const MoveFocusDownIntent(),
                  };

                  // Get activity panel provider to check if ActivityPage is open
                  final activityProvider =
                      ActivityPanelControllerProvider.maybeOf(context);

                  return Focus(
                    onKeyEvent: (node, event) {
                      // Only handle key down events for plain Up/Down (no modifiers)
                      if (event is! KeyDownEvent) {
                        return KeyEventResult.ignored;
                      }

                      // Check if this is plain Up/Down with no modifiers
                      final hasModifiers =
                          HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed ||
                          HardwareKeyboard.instance.isShiftPressed ||
                          HardwareKeyboard.instance.isAltPressed;
                      final isPlainUp =
                          event.logicalKey == LogicalKeyboardKey.arrowUp &&
                          !hasModifiers;
                      final isPlainDown =
                          event.logicalKey == LogicalKeyboardKey.arrowDown &&
                          !hasModifiers;

                      if ((isPlainUp || isPlainDown) &&
                          activityProvider?._activityListController != null) {
                        // Transfer focus to ActivityPage list
                        activityProvider!._activityListController!.moveFocus(
                          isPlainUp ? -1 : 1,
                        );
                        return KeyEventResult.handled;
                      }

                      // Let other keys (including Cmd-Up/Down) propagate to shortcuts
                      return KeyEventResult.ignored;
                    },
                    child: BidirectionalListSelector(
                      onActivate: (index) {
                        final item =
                            index >= state.first &&
                                index - state.first < state.agendaItems.length
                            ? state.agendaItems[index - state.first]
                            : null;
                        item?.iff(
                          activity: (activity) =>
                              context.run(ChangeCurrentActivity(activity)),
                        );
                      },
                      builder: (context, listController) {
                        // Register this controller with the global shortcuts provider
                        final provider =
                            _PriorityListControllerProvider.maybeOf(context);
                        provider?.registerController(listController);

                        return Shortcuts(
                          shortcuts: shortcuts,
                          child: Actions(
                            actions: {
                              MoveFocusUpIntent: CallbackAction<MoveFocusUpIntent>(
                                onInvoke: (intent) {
                                  // For Cmd-Up/Down: always move focus in PriorityPage
                                  // This is triggered by global shortcuts for Cmd-Up/Down
                                  listController.moveFocus(-1);
                                  return null;
                                },
                              ),
                              MoveFocusDownIntent: CallbackAction<MoveFocusDownIntent>(
                                onInvoke: (intent) {
                                  // For Cmd-Down: always move focus in PriorityPage
                                  // This is triggered by global shortcuts for Cmd-Up/Down
                                  listController.moveFocus(1);
                                  return null;
                                },
                              ),
                              OpenFocusedItemActionsIntent:
                                  CallbackAction<OpenFocusedItemActionsIntent>(
                                    onInvoke: (_) {
                                      final focusedIndex =
                                          listController.focusedIndex;
                                      if (focusedIndex != null &&
                                          focusedIndex >= state.first &&
                                          focusedIndex - state.first <
                                              state.agendaItems.length) {
                                        context.run(
                                          OpenFocusedItemActions(
                                            listController,
                                            (index) {
                                              final item =
                                                  index >= state.first &&
                                                      index - state.first <
                                                          state
                                                              .agendaItems
                                                              .length
                                                  ? state.agendaItems[index -
                                                        state.first]
                                                  : null;
                                              return item?.iff(
                                                    activity: (activity) =>
                                                        activityCommandGroups(
                                                          activity,
                                                        ),
                                                    priority: (priority) {
                                                      if (priority.id ==
                                                          state.context.id) {
                                                        return <
                                                          StaticCommandGroup
                                                        >[];
                                                      }
                                                      return [
                                                        StaticCommandGroup(
                                                          title: priority.title,
                                                          commands:
                                                              priorityCommands(
                                                                priority,
                                                              ),
                                                        ),
                                                      ];
                                                    },
                                                  ) ??
                                                  <StaticCommandGroup>[];
                                            },
                                          ),
                                        );
                                      }
                                      return null;
                                    },
                                  ),
                              ClearItemFocusIntent:
                                  CallbackAction<ClearItemFocusIntent>(
                                    onInvoke: (_) {
                                      listController.clearFocus();
                                      // When ActivityPage is open, also focus ActivityEditor
                                      activityProvider
                                          ?._activityEditorFocusCallback
                                          ?.call();
                                      return null;
                                    },
                                  ),
                            },
                            child: SelectionCommandScope(
                              actionBuilder: (index) {
                                final item =
                                    index >= state.first &&
                                        index - state.first <
                                            state.agendaItems.length
                                    ? state.agendaItems[index - state.first]
                                    : null;
                                return item?.iff(
                                      activity: (activity) =>
                                          activityCommandGroups(activity),
                                      priority: (priority) {
                                        // Skip if this is the context priority (already added by outer CommandScope)
                                        if (priority.id == state.context.id) {
                                          return <StaticCommandGroup>[];
                                        }
                                        return [
                                          StaticCommandGroup(
                                            title: priority.title,
                                            commands: priorityCommands(
                                              priority,
                                            ),
                                          ),
                                        ];
                                      },
                                    ) ??
                                    <StaticCommandGroup>[];
                              },
                              listController: listController,
                              child: Scaffold(
                                scrollable: false,
                                translucent: true,
                                header: StreamBuilder<List<(Tag, int)>>(
                                  stream: Activity.watchTagsForPriority(
                                    state.context.path,
                                  ),
                                  builder: (context, snapshot) {
                                    final tagCommands =
                                        snapshot.data
                                            ?.map(
                                              (tagData) => ToggleActivityFilter(
                                                tagData.$1,
                                                context: context,
                                              ),
                                            )
                                            .toList() ??
                                        [];

                                    return Header(
                                      title: state.context.title,
                                      main: PrioritySelector(
                                        selected: state.context,
                                        onSelect: (p) => context.run(
                                          ChangeCurrentPriority(p),
                                        ),
                                      ),
                                      onSearchChanged: (search) => context
                                          .read<PriorityBloc>()
                                          .updateSearch(search),
                                      onSearchClosed: () => context
                                          .read<PriorityBloc>()
                                          .updateFilter([]),
                                      filterCommands: tagCommands,
                                      commands: [
                                        NewActivity(),
                                        ShowPriorityCommands(
                                          state.context,
                                          current: true,
                                        ),
                                      ],
                                    );
                                  },
                                ),
                                body: BidirectionalList(
                                  anchorOffset: 0.35,
                                  controller: listController,
                                  scrollController: ScrollControllerContext.of(
                                    context,
                                  ),
                                  first: state.first,
                                  count: state.agendaItems.length,
                                  doneStart: state.doneStart,
                                  doneEnd: state.doneEnd,
                                  fetcher: (first, count) => context
                                      .read<PriorityBloc>()
                                      .fetchMoreAgendaItems(first, count),
                                  builder: (context, index, focusNode, {reorderableIndex}) {
                                    final current =
                                        state.agendaItems[index - state.first];
                                    return Column(
                                      mainAxisSize: MainAxisSize.min,
                                      key: ValueKey(
                                        current.when(
                                          date: (d) => 'date_${d.toString()}',
                                          priority: (p) => 'priority_${p.id}',
                                          activity: (a) => a.id,
                                        ),
                                      ),
                                      children: [
                                        ...current.when(
                                          date: (date) => [
                                            DayHeader(
                                              key: ValueKey(
                                                'dayheader_${date.toString()}',
                                              ),
                                              date: date,
                                              now: date == Date.today(),
                                              focusNode: focusNode,
                                            ),
                                          ],
                                          priority: (priority) => [
                                            AgendaHeader(
                                              key: ValueKey(
                                                'agendaheader_priority_${priority.id}',
                                              ),
                                              priority: priority,
                                              context: state.context,
                                              focusNode: focusNode,
                                            ),
                                          ],
                                          activity: (activity) => [
                                            if (activity.type ==
                                                ActivityType.event)
                                              AgendaHeader(
                                                key: ValueKey(
                                                  'agendaheader_activity_${activity.id}',
                                                ),
                                                activity: activity,
                                                context: state.context,
                                                focusNode: focusNode,
                                              ),
                                            if (activity.type !=
                                                ActivityType.event)
                                              ActivityWidget(
                                                key: ValueKey(
                                                  'activitywidget_${activity.id}',
                                                ),
                                                activity: activity,
                                                selected: selected == index,
                                                focusNode: focusNode,
                                                context: state.context,
                                                reorderableIndex:
                                                    reorderableIndex,
                                              ),
                                          ],
                                        ),
                                      ],
                                    );
                                  },
                                  onReorder: (index) {
                                    final item =
                                        state.agendaItems[index - state.first];
                                    final activity = item.iff(
                                      activity: (activity) => activity,
                                    );
                                    if (activity == null) {
                                      return null;
                                    }
                                    return (int newIndex) {
                                      final oldListIndex = index - state.first;
                                      final newListIndex =
                                          newIndex - state.first;

                                      // Calculate prev/next BEFORE modifying state
                                      // so we get the correct adjacent items
                                      var prevIndex = newListIndex - 1;
                                      var nextIndex = newListIndex;
                                      // Adjust for the item being removed from oldListIndex
                                      if (oldListIndex < newListIndex) {
                                        prevIndex++;
                                        nextIndex++;
                                      }
                                      AgendaItem? prev;
                                      if (prevIndex >= 0 &&
                                          prevIndex <
                                              state.agendaItems.length) {
                                        prev = state.agendaItems[prevIndex];
                                      }
                                      AgendaItem? next;
                                      if (nextIndex <
                                          state.agendaItems.length) {
                                        next = state.agendaItems[nextIndex];
                                      }

                                      // Update state immediately to prevent jank
                                      context
                                          .read<PriorityBloc>()
                                          .moveAgendaItem(
                                            oldListIndex,
                                            newListIndex,
                                          );

                                      // Then update the database asynchronously with correct prev/next
                                      onReorderActivity(activity, prev, next);
                                    };
                                  },
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              );
      },
    );
  }

  static void onReorderActivity(
    Activity activity,
    AgendaItem? prev,
    AgendaItem? next,
  ) async {
    final prevActivity = prev?.when<Activity?>(
      date: (Date date) => null,
      priority: (Priority priority) => null,
      activity: (Activity a) => a,
    );
    final nextActivity = next?.when<Activity?>(
      date: (Date date) => null,
      priority: (Priority priority) => null,
      activity: (Activity a) => a,
    );
    final priority = prev?.when<Priority?>(
      date: (Date date) => null,
      priority: (Priority priority) => priority,
      activity: (Activity a) => a.priority,
    );
    activity
        .copyWith(
          priority: priority,
          order: Order.between(prevActivity?.order, nextActivity?.order),
          on: Value(prevActivity?.on ?? nextActivity?.on),
        )
        .save();
  }
}
