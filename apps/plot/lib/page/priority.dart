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
    : priorityId = PriorityId.fromShortString(priorityIdString),
      _routerKey = GlobalKey(
        debugLabel:
            'PriorityWrapper_${PriorityId.fromShortString(priorityIdString).toShortString()}',
      );

  final PriorityId priorityId;
  final GlobalKey _routerKey;

  @override
  Widget wrappedRoute(BuildContext context) {
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
                  key: _routerKey,
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
        final nowBloc = context.read<NowBloc>();
        nowBloc.setFocus(state.context);
        // Update theme when priority switch loading completes
        if (state.targetPriority == null) {
          nowBloc.setContext(state.context);
        }
      },
      listenWhen: (previous, current) =>
          previous.context.id != current.context.id ||
          (previous.targetPriority != null && current.targetPriority == null),
      builder: (context, state) {
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
                        item?.when(
                          header: (header) => null,
                          activity: (agendaActivity) => context.run(
                            ChangeCurrentActivity(agendaActivity.activity),
                          ),
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
                                              return item?.when<
                                                    List<StaticCommandGroup>
                                                  >(
                                                    activity: (agendaActivity) =>
                                                        activityCommandGroups(
                                                          agendaActivity
                                                              .activity,
                                                        ),
                                                    header: (header) {
                                                      if (header.priority ==
                                                              null ||
                                                          header.priority!.id ==
                                                              state
                                                                  .context
                                                                  .id) {
                                                        return <
                                                          StaticCommandGroup
                                                        >[];
                                                      }
                                                      return [
                                                        StaticCommandGroup(
                                                          title: header
                                                              .priority!
                                                              .title,
                                                          commands:
                                                              priorityCommands(
                                                                header
                                                                    .priority!,
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
                                return item?.when<List<StaticCommandGroup>>(
                                      activity: (agendaActivity) =>
                                          activityCommandGroups(
                                            agendaActivity.activity,
                                          ),
                                      header: (header) {
                                        // Skip if priority is null or this is the context priority (already added by outer CommandScope)
                                        if (header.priority == null ||
                                            header.priority!.id ==
                                                state.context.id) {
                                          return <StaticCommandGroup>[];
                                        }
                                        return [
                                          StaticCommandGroup(
                                            title: header.priority!.title,
                                            commands: priorityCommands(
                                              header.priority!,
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
                                header: Header(
                                  title: state.context.title,
                                  main: PrioritySelector(
                                    selected: state.context,
                                    onSelect: (p) =>
                                        context.run(ChangeCurrentPriority(p)),
                                  ),
                                  onSearchChanged: (search) => context
                                      .read<PriorityBloc>()
                                      .updateSearch(search),
                                  onSearchClosed: () => context
                                      .read<PriorityBloc>()
                                      .updateFilter([]),
                                  filterCommands: state.tags
                                      .map(
                                        (tagData) => ToggleActivityFilter(
                                          tagData.$1,
                                          context: context,
                                        ),
                                      )
                                      .toList(),
                                  commands: [
                                    if (layoutState.multiPanel) NewActivity(),
                                    ShowPriorityCommands(
                                      state.context,
                                      current: true,
                                    ),
                                  ],
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
                                          header: (h) => h.date != null
                                              ? 'header_date_${h.date}'
                                              : h.dateTimeRange != null
                                              ? 'header_event_${h.priority?.id ?? 'null'}_${h.dateTimeRange}'
                                              : 'header_priority_${h.priority?.id ?? 'null'}',
                                          activity: (a) =>
                                              'activity_${a.activity.id}',
                                        ),
                                      ),
                                      children: [
                                        ...current.when(
                                          header: (header) => [
                                            AgendaHeader(
                                              key: ValueKey(
                                                header.date != null
                                                    ? 'agendaheader_date_${header.date}'
                                                    : header.dateTimeRange !=
                                                          null
                                                    ? 'agendaheader_event_${header.priority?.id ?? 'null'}_${header.dateTimeRange}'
                                                    : 'agendaheader_priority_${header.priority?.id ?? 'null'}',
                                              ),
                                              priority: header.priority,
                                              priorityContext: state.context,
                                              dateTimeRange:
                                                  header.dateTimeRange,
                                              date: header.date,
                                              now: header.now,
                                              activity: header.activity,
                                              focusNode: focusNode,
                                              text: header.text,
                                              scheduleAt: header.scheduleAt,
                                            ),
                                          ],
                                          activity: (agendaActivity) => [
                                            ActivityWidget(
                                              key: ValueKey(
                                                'activitywidget_${agendaActivity.activity.id}',
                                              ),
                                              activity: agendaActivity.activity,
                                              selected:
                                                  state.activity != null &&
                                                  agendaActivity.activity.id ==
                                                      state.activity!.id,
                                              now: agendaActivity.now,
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
                                    final activity = item.when<Activity?>(
                                      header: (header) => null,
                                      activity: (agendaActivity) =>
                                          agendaActivity.activity,
                                    );
                                    if (activity?.todo != true ||
                                        activity == null) {
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
                                      // activity is guaranteed non-null here due to the check above
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
      header: (header) => null,
      activity: (agendaActivity) => agendaActivity.activity,
    );
    final nextActivity = next?.when<Activity?>(
      header: (header) => null,
      activity: (agendaActivity) => agendaActivity.activity,
    );
    final priority = prev?.when<Priority?>(
      header: (header) => header.priority,
      activity: (agendaActivity) => agendaActivity.activity.priority,
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
