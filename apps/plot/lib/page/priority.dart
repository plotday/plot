import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_feed_drag.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/block_list_separator.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'package:plot/widget/unified_header.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/page/agenda.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';

import 'package:plot/command/command.dart';
import 'package:plot/router.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'priorities.dart';
import 'loading.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper implements AutoRouteWrapper {
  PriorityWrapper({@PathParam("priorityId") required String priorityIdString})
    : priorityId = PriorityId.tryFromShortString(priorityIdString),
      _routerKey = GlobalKey(debugLabel: 'PriorityWrapper_$priorityIdString');

  final PriorityId? priorityId;
  final GlobalKey _routerKey;

  @override
  Widget wrappedRoute(BuildContext context) {
    final priorityId = this.priorityId;
    if (priorityId == null) {
      // Invalid base58 priority id (e.g. /p/login from a stale or
      // malformed link). Redirect to the user's default landing instead
      // of crashing in the parser.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        context.router.replaceAll([const RootRoute()]);
      });
      return const SizedBox.shrink();
    }
    return _build(context, priorityId);
  }

  Widget _build(BuildContext context, PriorityId priorityId) {
    return PriorityBlocProvider(
      priorityId: priorityId,
      child: _PriorityCommandScope(
        child: _PriorityShortcutsProvider(
          priorityId: priorityId,
          child: ThreadHeaderNotifierProvider(
            child: BlocBuilder<LayoutBloc, LayoutState>(
              builder: (context, layoutState) {
                Widget body = Column(
                  children: [
                    const UnifiedHeader(),
                    Expanded(
                      child: ResizablePanelLayout(
                        leftTop: const LeftPanelAgendaView(),
                        left: PrioritiesPanelContent(),
                        middle: PriorityPage(priorityId: priorityId),
                        child: BlocSelector<PriorityBloc, PriorityState, int>(
                          selector: (state) =>
                              (state.thread?.priority.displayColor ??
                                      state.draft.priority.displayColor)
                                  .index,
                          builder: (context, threadColorIndex) {
                            final threadColor = ThemeColor(threadColorIndex);
                            final brightness = context.colour.brightness;
                            return ProxyProvider0<ColourSchemeData>(
                              update: (_, _) => ColourSchemeData(
                                themeColor: threadColor,
                                brightness: brightness,
                              ),
                              child: AutoRouter(
                                key: _routerKey,
                                placeholder: (context) => const LoadingPage(),
                                clipBehavior: Clip.none,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                );

                if (layoutState.multiPanel) {
                  body = DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: context.colour.frameBackgroundGradient,
                    ),
                    child: body,
                  );
                }
                // PriorityPage doesn't use the Plot Scaffold (it owns its
                // own Column/UnifiedHeader/ResizablePanelLayout), so the
                // route-level DefaultTextStyle override in app.dart is
                // the only thing standing between this content and
                // MaterialApp's `_errorTextStyle` (yellow double-underline).
                // On mobile, descendants here can end up resolving to a
                // Material-injected DefaultTextStyle whose decoration
                // leaks through. Force forui defaults with an explicit
                // `decoration: TextDecoration.none` so headers and any
                // other Text in this subtree paint cleanly.
                return DefaultTextStyle(
                  style: context.theme.typography.md.copyWith(
                    color: context.theme.colors.foreground,
                    decoration: TextDecoration.none,
                  ),
                  child: body,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _PriorityCommandScope extends StatelessWidget {
  const _PriorityCommandScope({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bloc = context.watch<PriorityBloc>();
    return CommandScope(
      commands: currentPriorityCommandGroups(
        bloc.state.thread?.priority ?? bloc.state.context,
      ),
      child: child,
    );
  }
}

/// Provides global keyboard shortcuts for PriorityPage list navigation
/// that work even when focus is in ThreadPage (e.g., ThreadEditor).
/// - Plain Up/Down: Navigate threads once focused
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
  InfiniteListController? _priorityListController;
  InfiniteListController? _activityListController;
  VoidCallback? _activityEditorFocusCallback;
  VoidCallback? _searchToggleCallback;
  bool _isSearchExpanded = false;

  void updateSearchExpanded(bool expanded) {
    if (_isSearchExpanded != expanded) {
      setState(() {
        _isSearchExpanded = expanded;
      });
    }
  }

  /// Closes search if it's open. Returns true if search was closed.
  bool tryCloseSearch() {
    if (_isSearchExpanded && _searchToggleCallback != null) {
      _searchToggleCallback!();
      return true;
    }
    return false;
  }

  void registerController(InfiniteListController controller) {
    _priorityListController = controller;
  }

  /// Returns the controller for the priority page's activity feed list.
  InfiniteListController? _resolveController(BuildContext context) {
    return _priorityListController;
  }

  void registerSearchToggle(VoidCallback callback) {
    _searchToggleCallback = callback;
  }

  void unregisterSearchToggle() {
    _searchToggleCallback = null;
  }

  /// Returns the thread at the currently focused list index, or falls back
  /// to the currently opened thread (`priorityBloc.state.thread`).
  Thread? _resolveFocusedOrCurrentThread(BuildContext context) {
    final priorityBloc = context.read<PriorityBloc>();
    final controller = _resolveController(context);
    if (controller != null && controller.focusedIndex != null) {
      final items = priorityBloc.state.activityFeedItems;
      final idx = controller.focusedIndex!;
      if (idx >= 0 && idx < items.length && items[idx] is AgendaThreadItem) {
        return (items[idx] as AgendaThreadItem).thread;
      }
    }
    return priorityBloc.state.thread;
  }

  /// Moves focus to the next/previous thread item, skipping headers.
  /// When nothing is focused, starts from the currently opened thread
  /// (or lastFocusedIndex), falling back to the first thread item.
  void _moveFocusOrStart(
    InfiniteListController controller,
    int offset,
    BuildContext context,
  ) {
    final priorityBloc = context.read<PriorityBloc>();
    final items = priorityBloc.state.activityFeedItems;

    // Determine current position
    int? current = controller.focusedIndex ?? controller.lastFocusedIndex;

    // If no prior focus, find the currently opened thread's index
    if (current == null) {
      final currentThread = priorityBloc.state.thread;
      if (currentThread != null) {
        for (int i = 0; i < items.length; i++) {
          if (items[i] is AgendaThreadItem &&
              (items[i] as AgendaThreadItem).thread.id == currentThread.id) {
            current = i;
            break;
          }
        }
      }
    }

    // If still nothing, find the first thread item
    if (current == null) {
      for (int i = 0; i < items.length; i++) {
        if (items[i] is AgendaThreadItem) {
          controller.requestFocus(i);
          return;
        }
      }
      return;
    }

    // Move in the given direction, skipping headers
    final direction = offset > 0 ? 1 : -1;
    int next = current + direction;
    while (next >= 0 && next < items.length) {
      if (items[next] is AgendaThreadItem) {
        controller.requestFocus(next);
        return;
      }
      next += direction;
    }

    // Already at boundary — stay on current if it's a thread
    if (current >= 0 &&
        current < items.length &&
        items[current] is AgendaThreadItem) {
      controller.requestFocus(current);
    }
  }

  /// Focuses the priority page's activity feed list, requesting focus on
  /// the currently opened thread or the first thread item.
  void _focusList(BuildContext context) {
    final controller = _priorityListController;
    if (controller == null) return;

    final priorityBloc = context.read<PriorityBloc>();
    final items = priorityBloc.state.activityFeedItems;

    // Try to find the currently opened thread's index
    int? targetIndex;
    final currentThread = priorityBloc.state.thread;
    if (currentThread != null) {
      for (int i = 0; i < items.length; i++) {
        if (items[i] is AgendaThreadItem &&
            (items[i] as AgendaThreadItem).thread.id == currentThread.id) {
          targetIndex = i;
          break;
        }
      }
    }

    // Fall back to first thread item
    if (targetIndex == null) {
      for (int i = 0; i < items.length; i++) {
        if (items[i] is AgendaThreadItem) {
          targetIndex = i;
          break;
        }
      }
    }

    if (targetIndex == null) return;

    priorityBloc.threadListSource = ThreadListSource.activityFeed;
    controller.requestFocus(targetIndex);
  }

  void registerActivityPanel({
    InfiniteListController? listController,
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
            // On mobile, wrap with PopScope to close search on back gesture.
            // canPop is false only when search is expanded, so normal
            // back navigation is unaffected when search is closed.
            // This must live here (not in the parent) because setState on
            // _isSearchExpanded triggers a rebuild of this widget.
            Widget child = Actions(
              actions: {
                MoveFocusUpIntent: CallbackAction<MoveFocusUpIntent>(
                  onInvoke: (_) {
                    final controller = _resolveController(context);
                    if (controller != null) {
                      _moveFocusOrStart(controller, -1, context);
                    }
                    return null;
                  },
                ),
                MoveFocusDownIntent: CallbackAction<MoveFocusDownIntent>(
                  onInvoke: (_) {
                    final controller = _resolveController(context);
                    if (controller != null) {
                      _moveFocusOrStart(controller, 1, context);
                    }
                    return null;
                  },
                ),
                ClearItemFocusIntent: CallbackAction<ClearItemFocusIntent>(
                  onInvoke: (_) {
                    // When ThreadPage or NewThreadPage is open, Escape should focus ThreadEditor
                    _activityEditorFocusCallback?.call();
                    return null;
                  },
                ),
                ToggleSearchIntent: CallbackAction<ToggleSearchIntent>(
                  onInvoke: (_) {
                    _searchToggleCallback?.call();
                    return null;
                  },
                ),
                ToggleStartFinishCurrentThreadIntent:
                    CallbackAction<ToggleStartFinishCurrentThreadIntent>(
                      onInvoke: (_) {
                        final thread = _resolveFocusedOrCurrentThread(context);
                        if (thread != null) {
                          if (thread.todo) {
                            FinishThread(thread).run(context);
                          } else {
                            StartThread(thread).run(context);
                          }
                        }
                        return null;
                      },
                    ),
                ArchiveCurrentThreadIntent:
                    CallbackAction<ArchiveCurrentThreadIntent>(
                      onInvoke: (_) {
                        final thread = _resolveFocusedOrCurrentThread(context);
                        if (thread != null) {
                          ArchiveThread(thread).run(context);
                        }
                        return null;
                      },
                    ),
                FocusOrToggleAgendaActivityIntent:
                    CallbackAction<FocusOrToggleAgendaActivityIntent>(
                      onInvoke: (_) {
                        // PriorityPage now renders only the activity feed,
                        // so this shortcut just focuses that list.
                        _focusList(context);
                        return null;
                      },
                    ),
                ScheduleCurrentThreadIntent:
                    CallbackAction<ScheduleCurrentThreadIntent>(
                      onInvoke: (_) {
                        final thread = _resolveFocusedOrCurrentThread(context);
                        if (thread != null) {
                          PickScheduleThread(thread).run(context);
                        }
                        return null;
                      },
                    ),
              },
              child: Shortcuts(
                shortcuts: <ShortcutActivator, Intent>{
                  platformSingleActivator(LogicalKeyboardKey.keyA, shift: true):
                      const FocusOrToggleAgendaActivityIntent(),
                  platformSingleActivator(LogicalKeyboardKey.slash):
                      const ToggleSearchIntent(),
                  platformSingleActivator(LogicalKeyboardKey.keyD):
                      const ToggleStartFinishCurrentThreadIntent(),
                  platformSingleActivator(LogicalKeyboardKey.keyD, shift: true):
                      const ScheduleCurrentThreadIntent(),
                  platformSingleActivator(LogicalKeyboardKey.backspace):
                      const ArchiveCurrentThreadIntent(),
                  // Global Escape handler - focus ThreadEditor when ThreadPage is open
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

            if (!layoutState.multiPanel) {
              child = PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, result) {
                  if (!didPop) {
                    if (_isSearchExpanded) {
                      tryCloseSearch();
                    } else {
                      AutoTabsRouter.of(context).setActiveIndex(0);
                    }
                  }
                },
                child: child,
              );
            }

            return child;
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

/// InheritedWidget to provide access to ThreadPage panel state for focus coordination
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
  }) : priorityId = PriorityId.tryFromShortString(priorityIdString);

  final PriorityId? priorityId;

  @override
  State<PriorityOnlyPage> createState() => _PriorityOnlyPageState();
}

class _PriorityOnlyPageState extends State<PriorityOnlyPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // This route means no thread is selected — clear any stale thread state.
      // Handles browser back / gesture back which bypass PopScope.
      context.read<PriorityBloc>().setThread(null);
      final layoutState = context.read<LayoutBloc>().state;
      if (layoutState.middlePanelVisible) {
        context.router.navigate(NewThreadRoute());
      }
    });
  }

  @override
  void didUpdateWidget(PriorityOnlyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final layoutState = context.read<LayoutBloc>().state;
    if (layoutState.middlePanelVisible) {
      context.router.navigate(NewThreadRoute());
    }
  }

  @override
  Widget build(BuildContext context) {
    final priorityId = widget.priorityId;
    if (priorityId == null) {
      // Parent PriorityWrapper handles redirect for invalid ids.
      return const SizedBox.shrink();
    }
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        if (layoutState.middlePanelVisible) {
          // In multi-panel mode, always redirect to /new — NewThreadPage
          // handles special cases (twist dev, viewer) itself.
          if (!context.router.currentPath.endsWith('/new')) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && layoutState.middlePanelVisible) {
                context.router.navigate(NewThreadRoute());
              }
            });
          }
          return const LoadingPage();
        }
        return PriorityPage(priorityId: priorityId);
      },
    );
  }
}

class PriorityPage extends StatefulWidget {
  const PriorityPage({required this.priorityId, super.key});

  final PriorityId priorityId;

  @override
  State<PriorityPage> createState() => _PriorityPageState();
}

class _PriorityPageState extends State<PriorityPage>
    with TickerProviderStateMixin {
  late final BlockDragController _activityFeedDragController =
      BlockDragController(vsync: this);

  /// Memoized drop-boundary computation. Recomputing on every parent
  /// rebuild would re-walk the entire feed and re-parse every section
  /// marker. Cache by `displayItems` identity — `_rebuildActivityFeedSections`
  /// produces a fresh `List.unmodifiable` on each emit, so reference
  /// equality is the right key.
  List<AgendaItem>? _cachedDropBoundaryItems;
  ({Map<int, FeedDropSlot> before, FeedDropSlot? afterList})?
  _cachedDropBoundaries;

  @override
  void dispose() {
    _activityFeedDragController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<PriorityBloc, PriorityState>(
          listenWhen: (previous, current) =>
              previous.context.id != current.context.id,
          listener: (context, state) {
            final nowBloc = context.read<NowBloc>();
            nowBloc.setFocus(state.context);
            nowBloc.setContext(state.context);
            // Reset scroll to top on priority switch
            final scrollController = ScrollControllerContext.of(context);
            if (scrollController != null && scrollController.hasClients) {
              scrollController.jumpTo(0);
            }
          },
        ),
        // Mirror NowBloc.currentEvent into PriorityBloc so the activity
        // feed can render the "Event Agenda" section.
        BlocListener<NowBloc, NowState>(
          listenWhen: (previous, current) {
            final p = previous is NowLoaded ? previous.currentEvent : null;
            final n = current is NowLoaded ? current.currentEvent : null;
            return p?.id != n?.id || p?.occurrence != n?.occurrence;
          },
          listener: (context, nowState) {
            final event = nowState is NowLoaded ? nowState.currentEvent : null;
            context.read<PriorityBloc>().setCurrentEventForFeed(event);
          },
        ),
      ],
      child: BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, state) {
          return _buildBody(context, state);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, PriorityState state) {
    return Builder(
      builder: (context) {
        final items = state.activityFeedItems;

        // Build shortcuts map for plain Up/Down navigation
        final shortcuts = <ShortcutActivator, Intent>{
          const SingleActivator(LogicalKeyboardKey.enter):
              const OpenFocusedItemActionsIntent(),
          const SingleActivator(LogicalKeyboardKey.escape):
              const ClearItemFocusIntent(),
          const SingleActivator(LogicalKeyboardKey.arrowUp):
              const MoveFocusUpIntent(),
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              const MoveFocusDownIntent(),
        };

        // Get activity panel provider to check if ThreadPage is open
        final activityProvider = ActivityPanelControllerProvider.maybeOf(
          context,
        );

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
                event.logicalKey == LogicalKeyboardKey.arrowUp && !hasModifiers;
            final isPlainDown =
                event.logicalKey == LogicalKeyboardKey.arrowDown &&
                !hasModifiers;

            if ((isPlainUp || isPlainDown) &&
                activityProvider?._activityListController != null) {
              // Transfer focus to ThreadPage list
              activityProvider!._activityListController!.moveFocus(
                isPlainUp ? -1 : 1,
              );
              return KeyEventResult.handled;
            }

            // Let other keys (including Cmd-Up/Down) propagate to shortcuts
            return KeyEventResult.ignored;
          },
          child: InfiniteListSelector(
            onActivate: (index) {
              final item = index >= 0 && index < items.length
                  ? items[index]
                  : null;
              item?.when(
                header: (header) => null,
                activity: (agendaActivity) =>
                    context.run(ChangeCurrentThread(agendaActivity.thread)),
              );
            },
            builder: (context, listController) {
              final provider = _PriorityListControllerProvider.maybeOf(context);
              provider?.registerController(listController);

              return Shortcuts(
                shortcuts: shortcuts,
                child: Actions(
                  actions: {
                    MoveFocusUpIntent: CallbackAction<MoveFocusUpIntent>(
                      onInvoke: (intent) {
                        provider?._moveFocusOrStart(
                          listController,
                          -1,
                          context,
                        );
                        return null;
                      },
                    ),
                    MoveFocusDownIntent: CallbackAction<MoveFocusDownIntent>(
                      onInvoke: (intent) {
                        provider?._moveFocusOrStart(listController, 1, context);
                        return null;
                      },
                    ),
                    OpenFocusedItemActionsIntent:
                        CallbackAction<OpenFocusedItemActionsIntent>(
                          onInvoke: (_) {
                            final priorityBloc = context.read<PriorityBloc>();
                            final focusedIndex = listController.focusedIndex;
                            if (focusedIndex != null &&
                                focusedIndex >= 0 &&
                                focusedIndex < items.length) {
                              // Capture bloc here so dispatched commands
                              // (e.g. Archive) keep their optimistic path
                              // alive when the modal context can't resolve
                              // PriorityBloc.
                              final capturedBloc = priorityBloc;
                              context.run(
                                OpenFocusedItemActions(listController, (
                                  index,
                                ) async {
                                  final item =
                                      index >= 0 && index < items.length
                                      ? items[index]
                                      : null;
                                  if (item == null) {
                                    return <StaticCommandGroup>[];
                                  }
                                  return await item
                                      .when<Future<List<StaticCommandGroup>>>(
                                        activity: (agendaActivity) =>
                                            threadCommandGroups(
                                              agendaActivity.thread,
                                              priorityBloc: capturedBloc,
                                            ),
                                        header: (_) async =>
                                            <StaticCommandGroup>[],
                                      );
                                }),
                              );
                            }
                            return null;
                          },
                        ),
                    ClearItemFocusIntent: CallbackAction<ClearItemFocusIntent>(
                      onInvoke: (_) {
                        listController.clearFocus();
                        // When ThreadPage is open, also focus ThreadEditor
                        activityProvider?._activityEditorFocusCallback?.call();
                        return null;
                      },
                    ),
                  },
                  child: CommandScope(
                    commandsBuilder: () {
                      final index = listController.lastFocusedIndex;
                      if (index == null) {
                        return <StaticCommandGroup>[];
                      }
                      final item = index >= 0 && index < items.length
                          ? items[index]
                          : null;
                      return item?.when<List<StaticCommandGroup>>(
                            activity: (agendaActivity) =>
                                threadCommandGroupsSync(agendaActivity.thread),
                            header: (_) => <StaticCommandGroup>[],
                          ) ??
                          <StaticCommandGroup>[];
                    },
                    listenable: listController,
                    child: Scaffold(
                      scrollable: false,
                      translucent: true,
                      childPad: false,
                      body: ThreadListSourceProvider(
                        source: ThreadListSource.activityFeed,
                        child: _buildActivityFeed(
                          context,
                          state,
                          items,
                          listController,
                          ScrollControllerContext.of(context),
                          scrollStorageKey: PageStorageKey(
                            'priority_feed_${widget.priorityId}',
                          ),
                        ),
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
  }

  Widget _buildSeparator(
    BuildContext context,
    List<AgendaItem> listItems,
    int index,
    PriorityState state,
    InfiniteListController controller,
  ) {
    final selectedId = state.thread?.id;
    return BlockListSeparator(
      prev: index > 0 && index - 1 < listItems.length
          ? listItems[index - 1]
          : null,
      next: index < listItems.length ? listItems[index] : null,
      controller: controller,
      dragController: _activityFeedDragController,
      index: index,
      selectedAccent: (item) {
        if (item is AgendaThreadItem && item.thread.id == selectedId) {
          return context.colour.colours.fromTheme(
            item.thread.priority.displayColor,
          );
        }
        return null;
      },
      canHighlight: (item) => item is AgendaThreadItem,
      // Activity-feed threads carry their thread id as the drag block id
      // (each row is its own one-row "block"), so match next thread ids
      // directly against the controller's draggingBlockId.
      dragSourceId: (item) =>
          item is AgendaThreadItem ? item.thread.id.toString() : null,
    );
  }

  Widget _buildActivityFeed(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
    InfiniteListController controller,
    ScrollController? scrollController, {
    PageStorageKey<String>? scrollStorageKey,
  }) {
    // Append remote search extras (threads surfaced by the server that
    // aren't visible locally) with a section header. Only when searching.
    //
    // Reuse the incoming `items` reference unchanged in the common case
    // (no extras) so the boundary-cache below can hit by identity.
    final isSearching = state.search.isNotEmpty;
    final List<AgendaItem> displayItems;
    if (isSearching && state.remoteSearchExtras.isNotEmpty) {
      final merged = <AgendaItem>[...items];
      merged.add(const AgendaHeaderItem(text: 'From the server'));
      for (final t in state.remoteSearchExtras) {
        merged.add(AgendaThreadItem(t));
      }
      displayItems = merged;
    } else {
      displayItems = items;
    }

    // A trailing synthetic row is appended when a search footer (spinner,
    // archived hint, or offline note) should be shown.
    final showFooter =
        isSearching &&
        (state.remoteSearchInProgress ||
            state.remoteSearchOffline ||
            (state.hasArchivedMatches && !state.showArchived));

    final hasAnyThread = displayItems.whereType<AgendaThreadItem>().isNotEmpty;
    if (!hasAnyThread &&
        !showFooter &&
        state.activityFeedDoneEnd &&
        state.activityFeedLoaded) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.contentPaddingH,
          vertical: context.theme.spacing.xl,
        ),
        child: Text(
          'Threads track your specific goals and activities, with tasks, notes, and linked documents in one place.\nCreate a thread or add a connection to add threads here.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.theme.plotColors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      );
    }

    final bloc = context.read<PriorityBloc>();
    final footerIndex = showFooter ? displayItems.length : -1;
    final totalCount = displayItems.length + (showFooter ? 1 : 0);

    // Drop boundaries depend only on `displayItems`, which gets a fresh
    // identity from `_rebuildActivityFeedSections`. Cache by reference so
    // unrelated parent rebuilds (e.g. RSVP changes elsewhere on the page)
    // don't re-walk the list and re-parse every section marker.
    final ({Map<int, FeedDropSlot> before, FeedDropSlot? afterList}) boundaries;
    if (identical(_cachedDropBoundaryItems, displayItems) &&
        _cachedDropBoundaries != null) {
      boundaries = _cachedDropBoundaries!;
    } else {
      boundaries = computeActivityFeedDropBoundaries(items: displayItems);
      _cachedDropBoundaryItems = displayItems;
      _cachedDropBoundaries = boundaries;
    }
    _activityFeedDragController.dispatcher = (payload, target) {
      dispatchActivityFeedThreadDrop(
        bloc: bloc,
        payload: payload,
        target: target,
      );
    };
    // No preview builder for the activity feed: the drop zone shows a
    // plain expanded gap. The floating drag-feedback already represents
    // the thread under the cursor, so a dimmed-thread preview inside
    // the gap would render the same row twice (once under the pointer,
    // once at the destination).
    _activityFeedDragController.previewBuilder = null;

    final list = InfiniteList(
      controller: controller,
      scrollController: scrollController,
      scrollStorageKey: scrollStorageKey,
      initialScrollOffset: bloc.activityFeedScrollOffset,
      onScrollOffsetChanged: (offset) => bloc.activityFeedScrollOffset = offset,
      count: totalCount,
      doneEnd: state.activityFeedDoneEnd,
      fetcher: (first, count) => bloc.fetchMoreActivityFeedItems(first, count),
      separatorBuilder: (context, index) =>
          _buildSeparator(context, displayItems, index, state, controller),
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= totalCount) {
          return null;
        }
        if (index == footerIndex) {
          return _SearchFooter(state: state);
        }
        final current = displayItems[index];
        final dropAbove = boundaries.before[index];
        // Trailing boundary attached to the last list item (skip when the
        // search footer occupies the last index).
        final isLast = !showFooter && index == displayItems.length - 1;
        final tail = isLast ? boundaries.afterList : null;

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey(
            current.when(
              header: (h) => h.date != null
                  ? 'feed_header_date_${h.date}'
                  : 'feed_header_${h.text}',
              activity: (a) => 'feed_activity_${a.thread.id}',
            ),
          ),
          children: [
            if (dropAbove != null)
              BlockDropZone(
                target: dropAbove.target,
                silent: dropAbove.silent,
                slotKey: 'feed_drop_above_$index',
                // Active gap sits directly above the next row in this
                // column — paint a 1px divider at the bottom of the
                // expanded gap so the row below isn't flush against
                // the dimmed preview.
                dividerBelow: true,
              ),
            ...current.when(
              header: (header) {
                String? displayText = header.text;
                final marker = displayText == null
                    ? null
                    : ActivitySectionMarker.tryDecode(displayText);
                if (marker != null) displayText = marker.label;
                // Activity-feed section headers (Today / New / Scheduled
                // day buckets / Done) are all just text labels and must
                // render through AgendaTile's text-only heading path so
                // they share color and vertical padding. Scheduled-day
                // headers carry a `date` for drag/keyboard targeting,
                // but passing that into AgendaTile would route them
                // through the date-header path (veryMuted + spacing.md)
                // and they'd stand out from their siblings — drop it
                // here when a section marker is present.
                final tileDate = marker != null ? null : header.date;
                final tile = AgendaTile(
                  dateTimeRange: header.dateTimeRange,
                  date: tileDate,
                  now: header.now,
                  thread: header.thread,
                  focusNode: focusNode,
                  text: displayText,
                  scheduleAt: header.scheduleAt,
                );

                // "Reschedule all" affordance for the Today block and
                // every future Scheduled-day block. Collect the threads
                // that follow this header until the next section header
                // and skip rendering the button when the block is empty.
                final canRescheduleAll =
                    marker != null &&
                    (marker.section == ActivitySection.today ||
                        marker.section == ActivitySection.scheduled);
                if (canRescheduleAll) {
                  final sectionThreads = <Thread>[];
                  for (var j = index + 1; j < displayItems.length; j++) {
                    final next = displayItems[j];
                    if (next is AgendaHeaderItem) break;
                    if (next is AgendaThreadItem) {
                      sectionThreads.add(next.thread);
                    }
                  }
                  if (sectionThreads.isNotEmpty) {
                    return [
                      _SectionHeaderWithRescheduleAll(
                        tile: tile,
                        threads: sectionThreads,
                        sectionLabel: marker.label,
                      ),
                    ];
                  }
                }

                return [tile];
              },
              activity: (agendaActivity) {
                final baseThread = agendaActivity.thread;
                final rowKey = agendaActivity.isAssociated
                    ? ValueKey(
                        'feed_activitywidget_${baseThread.id}_assoc_${agendaActivity.associationParentId ?? ''}',
                      )
                    : ValueKey('feed_activitywidget_${baseThread.id}');
                final item = _ActivityFeedItem(
                  key: rowKey,
                  baseThread: baseThread,
                  selected:
                      state.thread != null && baseThread.id == state.thread!.id,
                  now: agendaActivity.now,
                  focusNode: focusNode,
                  priorityContext: state.context,
                  isAssociated: agendaActivity.isAssociated,
                );
                if (agendaActivity.pinned) {
                  // Pinned event row: not draggable, not a drop target —
                  // it always leads the Event Agenda section.
                  return [item];
                }
                return [
                  ActivityFeedDraggableRow(
                    threadId: baseThread.id,
                    priorityContext: state.context,
                    child: item,
                  ),
                ];
              },
            ),
            if (tail != null)
              BlockDropZone(
                target: tail.target,
                silent: tail.silent,
                slotKey: 'feed_drop_tail',
              ),
          ],
        );
      },
    );

    return BlockDragScope(
      controller: _activityFeedDragController,
      child: ScrollEdgeFade(background: context.colour.background, child: list),
    );
  }
}

class _SearchFooter extends StatelessWidget {
  const _SearchFooter({required this.state});

  final PriorityState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.plotColors;
    final padding = EdgeInsets.symmetric(
      horizontal: context.contentPaddingH,
      vertical: context.theme.spacing.md,
    );

    if (state.remoteSearchInProgress) {
      return Padding(
        padding: padding,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [const Spinner()],
        ),
      );
    }

    if (state.hasArchivedMatches && !state.showArchived) {
      return Padding(
        padding: padding,
        child: Align(
          alignment: Alignment.center,
          child: FButton(
            variant: FButtonVariant.ghost,
            onPress: () => context.read<PriorityBloc>().toggleShowArchived(),
            child: const Text('View archived items matching this search'),
          ),
        ),
      );
    }

    if (state.remoteSearchOffline) {
      return Padding(
        padding: padding,
        child: Text(
          'Offline — showing local matches only',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }
}

class _ActivityFeedItem extends StatefulWidget {
  const _ActivityFeedItem({
    super.key,
    required this.baseThread,
    required this.selected,
    required this.now,
    required this.focusNode,
    required this.priorityContext,
    this.isAssociated = false,
  });

  final Thread baseThread;
  final bool selected;
  final bool now;
  final FocusNode focusNode;
  final Priority priorityContext;
  final bool isAssociated;

  @override
  State<_ActivityFeedItem> createState() => _ActivityFeedItemState();
}

class _ActivityFeedItemState extends State<_ActivityFeedItem> {
  late Future<Thread?> _representative;

  @override
  void initState() {
    super.initState();
    _representative = context.read<PriorityBloc>().loadRepresentativeForFeed(
      widget.baseThread,
    );
  }

  @override
  void didUpdateWidget(covariant _ActivityFeedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.baseThread.id != widget.baseThread.id ||
        oldWidget.baseThread.scheduleId != widget.baseThread.scheduleId ||
        oldWidget.baseThread.currentUserRsvp !=
            widget.baseThread.currentUserRsvp) {
      _representative = context.read<PriorityBloc>().loadRepresentativeForFeed(
        widget.baseThread,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Thread?>(
      future: _representative,
      builder: (context, snapshot) {
        final rep = snapshot.data;
        // Compose the live baseThread with the cached representative's
        // picked schedule + flags so the row reflects up-to-date sync
        // state (unread, title, tags, …) instead of the snapshot taken
        // when the representative was resolved. See
        // PriorityBloc._representativeCache for why we cache.
        final display = rep != null
            ? widget.baseThread.withRepresentativeFrom(rep)
            : widget.baseThread;
        // Key intentionally excludes the resolved scheduleId — including
        // it would change identity once the Future resolves and force
        // every ThreadWidget to remount, dropping focus and re-running
        // layout.
        return ThreadWidget(
          key: ValueKey('feed_activitywidget_${widget.baseThread.id}'),
          activity: display,
          selected: widget.selected,
          now: widget.now,
          focusNode: widget.focusNode,
          context: widget.priorityContext,
          showSubPriority: true,
          bump: false,
          showEventTiming: rep != null,
          isAssociated: widget.isAssociated,
        );
      },
    );
  }
}

/// Section header (Today or a future Scheduled day) overlaid with a small
/// "Reschedule all" affordance on the trailing edge. The underlying
/// [AgendaTile] keeps its centered text and dark band; the button floats
/// above it via a [Stack] so the section label stays visually centered.
class _SectionHeaderWithRescheduleAll extends StatelessWidget {
  const _SectionHeaderWithRescheduleAll({
    required this.tile,
    required this.threads,
    required this.sectionLabel,
  });

  final Widget tile;
  final List<Thread> threads;
  final String sectionLabel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        tile,
        Positioned.fill(
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.theme.spacing.sm,
              ),
              child: Button.icon(
                RescheduleAllInBlock(threads, sectionLabel: sectionLabel),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
