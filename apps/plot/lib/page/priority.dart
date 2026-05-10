import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_feed_drag.dart';
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/resizable_panel_layout.dart';
import 'package:plot/widget/unified_header.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:collection/collection.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';

import 'package:plot/command/command.dart';
import 'package:plot/router.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:logging/logging.dart';
import 'priorities.dart';
import 'loading.dart';

final _log = Logger('plot.page.priority');

enum PriorityTab { agenda, activityFeed }

class PriorityTabNotifier extends ValueNotifier<PriorityTab> {
  PriorityTabNotifier() : super(PriorityTab.agenda);

  /// Most recently-mounted notifier, exposed so callers outside the
  /// [PriorityTabProvider] subtree (e.g. the onboarding overlay) can drive
  /// the current priority's active tab. The PrioritiesShell mounts a single
  /// shell at any time so this is unambiguous in practice.
  static PriorityTabNotifier? current;
}

class PriorityTabProvider extends InheritedWidget {
  const PriorityTabProvider({
    required this.notifier,
    required super.child,
    super.key,
  });

  final PriorityTabNotifier notifier;

  static PriorityTabNotifier of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PriorityTabProvider>()!
        .notifier;
  }

  static PriorityTabNotifier? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PriorityTabProvider>()
        ?.notifier;
  }

  @override
  bool updateShouldNotify(PriorityTabProvider old) => notifier != old.notifier;
}

@RoutePage(name: "PriorityRoute")
class PriorityWrapper implements AutoRouteWrapper {
  PriorityWrapper({
    @PathParam("priorityId") required String priorityIdString,
    @QueryParam('tab') this.tab,
  }) : priorityId = PriorityId.tryFromShortString(priorityIdString),
       _routerKey = GlobalKey(
         debugLabel: 'PriorityWrapper_$priorityIdString',
       );

  final PriorityId? priorityId;
  final String? tab;
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
        context.router.replaceAll([EmptyShellRoute("Now")()]);
      });
      return const SizedBox.shrink();
    }
    return _build(context, priorityId);
  }

  Widget _build(BuildContext context, PriorityId priorityId) {
    // When a tab is specified (e.g. from notification tap), update the shared
    // notifier so all PriorityPage instances (including PriorityOnlyPage on
    // mobile) pick up the correct tab. Deferred to after this build frame
    // to avoid setState-during-build when the notifier triggers a rebuild
    // of an ancestor (PrioritiesShell).
    if (tab == 'activity') {
      final notifier = PriorityTabProvider.maybeOf(context);
      if (notifier != null && notifier.value != PriorityTab.activityFeed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          notifier.value = PriorityTab.activityFeed;
        });
      }
    }

    return PriorityBlocProvider(
      priorityId: priorityId,
      child: _AutoTabSwitcher(
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
                          left: PrioritiesPage(),
                          middle: PriorityPage(
                            priorityId: priorityId,
                            initialTab: tab == 'activity'
                                ? PriorityTab.activityFeed
                                : null,
                          ),
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

                  return body;
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Auto-switches `PriorityTab` to `activityFeed` when the open thread
/// isn't part of the agenda. Only ever switches *to* activityFeed —
/// manual user choices stick.
///
/// The empty-agenda case no longer triggers a switch: the agenda is
/// global across priorities (all blocks visible, just collapsed when
/// not in the current context), so there's always *something* in the
/// agenda for the user to see.
class _AutoTabSwitcher extends StatelessWidget {
  const _AutoTabSwitcher({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocListener<PriorityBloc, PriorityState>(
      listenWhen: (prev, current) {
        if (prev.context.id != current.context.id) return true;
        if (!prev.agendaLoaded && current.agendaLoaded) return true;
        if (prev.thread?.id != current.thread?.id && current.thread != null) {
          return true;
        }
        return false;
      },
      listener: (context, state) {
        if (!state.agendaLoaded) return;
        if (state.context.isActivityOnly) return;
        final notifier = PriorityTabProvider.maybeOf(context);
        if (notifier == null || notifier.value != PriorityTab.agenda) return;

        final thread = state.thread;
        if (thread == null) return;

        // Hidden rows belong to a collapsed block — the user can't see
        // them, so the agenda doesn't currently surface this thread.
        final threadInAgenda = state.agendaItems.any(
          (item) => item.when(
            header: (_) => false,
            activity: (a) => !a.hidden && a.thread.id == thread.id,
          ),
        );

        if (!threadInAgenda) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            notifier.value = PriorityTab.activityFeed;
          });
        }
      },
      child: child,
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
/// - Cmd+T: Focus a thread in the agenda list
/// - Cmd+Shift+T: Focus a thread in the activity list
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
  InfiniteListController? _priorityActivityFeedController;
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

  void registerController(
    InfiniteListController controller, {
    InfiniteListController? activityFeedController,
  }) {
    _priorityListController = controller;
    _priorityActivityFeedController = activityFeedController;
  }

  /// Returns the controller for the list matching the user's current source.
  InfiniteListController? _resolveController(BuildContext context) {
    final priorityBloc = context.read<PriorityBloc>();
    final source = priorityBloc.resolveThreadListSource();
    if (source == ThreadListSource.activityFeed &&
        _priorityActivityFeedController != null) {
      return _priorityActivityFeedController;
    }
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
      final source = priorityBloc.resolveThreadListSource();
      var items = source == ThreadListSource.agenda
          ? priorityBloc.state.agendaViewItems
          : priorityBloc.state.activityFeedItems;

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
    final source = priorityBloc.resolveThreadListSource();
    var items = source == ThreadListSource.agenda
        ? priorityBloc.state.agendaViewItems
        : priorityBloc.state.activityFeedItems;

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

  /// Focuses the thread list for the given source (agenda or activity feed),
  /// switching the active list source and requesting focus on the appropriate item.
  void _focusListSource(BuildContext context, ThreadListSource targetSource) {
    final priorityBloc = context.read<PriorityBloc>();
    final controller = targetSource == ThreadListSource.activityFeed
        ? _priorityActivityFeedController
        : _priorityListController;
    if (controller == null) return;

    final items = targetSource == ThreadListSource.agenda
        ? priorityBloc.state.agendaViewItems
        : priorityBloc.state.activityFeedItems;

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

    priorityBloc.threadListSource = targetSource;
    final tabNotifier = PriorityTabProvider.maybeOf(context);
    final targetTab = targetSource == ThreadListSource.agenda
        ? PriorityTab.agenda
        : PriorityTab.activityFeed;
    final tabChanged = tabNotifier != null && tabNotifier.value != targetTab;
    if (tabChanged) {
      tabNotifier.value = targetTab;
      // After a tab switch the target list's items load asynchronously via
      // the InfiniteList fetcher, so FocusNodes at targetIndex aren't
      // attached yet. Poll-retry requestFocus until it sticks or we give
      // up, so the very first tab switch still lands focus on the list.
      _pollRequestFocus(controller, targetIndex);
    } else {
      controller.requestFocus(targetIndex);
    }
  }

  /// Repeatedly calls [controller.requestFocus] until primary focus lands on
  /// one of the list's items, or we hit the attempt budget. Needed when the
  /// target list's FocusNodes haven't attached yet (async item fetcher).
  void _pollRequestFocus(
    InfiniteListController controller,
    int index, {
    int attempts = 30,
    Duration interval = const Duration(milliseconds: 16),
  }) async {
    for (var i = 0; i < attempts; i++) {
      controller.requestFocus(index);
      await Future<void>.delayed(interval);
      if (!mounted) return;
      if (controller.hasPrimaryFocus) return;
    }
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
                        // Trust the visible tab (what the user sees), not the
                        // bloc's inferred source — they can drift when no
                        // thread is open or the open thread isn't in agenda.
                        final tabNotifier = PriorityTabProvider.maybeOf(
                          context,
                        );
                        final visibleSource =
                            tabNotifier?.value == PriorityTab.activityFeed
                            ? ThreadListSource.activityFeed
                            : ThreadListSource.agenda;
                        final controller =
                            visibleSource == ThreadListSource.activityFeed
                            ? _priorityActivityFeedController
                            : _priorityListController;
                        if (controller?.hasPrimaryFocus != true) {
                          _focusListSource(context, visibleSource);
                        } else {
                          final target =
                              visibleSource == ThreadListSource.agenda
                              ? ThreadListSource.activityFeed
                              : ThreadListSource.agenda;
                          _focusListSource(context, target);
                        }
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
  const PriorityPage({required this.priorityId, this.initialTab, super.key});

  final PriorityId priorityId;
  final PriorityTab? initialTab;

  @override
  State<PriorityPage> createState() => _PriorityPageState();
}

class _PriorityPageState extends State<PriorityPage> {
  PriorityTab _currentTab = PriorityTab.agenda;
  PriorityTabNotifier? _tabNotifier;
  bool _appliedInitialTab = false;
  final InfiniteListController _agendaListController = InfiniteListController();
  final Map<String, GlobalKey<AnimatedRemovalState>> _removalKeys = {};
  final BlockDragController _blockDragController = BlockDragController();
  final BlockDragController _activityFeedDragController =
      BlockDragController();

  GlobalKey<AnimatedRemovalState> _getRemovalKey(String threadId) {
    return _removalKeys.putIfAbsent(
      threadId,
      () => GlobalKey<AnimatedRemovalState>(debugLabel: 'removal_$threadId'),
    );
  }

  void _onTabNotifierChanged() {
    if (_tabNotifier != null && _tabNotifier!.value != _currentTab) {
      // Defer setState — the notifier may fire during a build frame
      // (e.g. when didChangeDependencies forces the viewer tab).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _tabNotifier != null &&
            _tabNotifier!.value != _currentTab) {
          setState(() {
            _currentTab = _tabNotifier!.value;
          });
        }
      });
    }
  }

  @override
  void didUpdateWidget(PriorityPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab &&
        widget.initialTab != null) {
      _applyInitialTab();
    }
  }

  void _applyInitialTab() {
    final tab = widget.initialTab;
    if (tab == null) return;
    setState(() {
      _currentTab = tab;
    });
    if (_tabNotifier != null && _tabNotifier!.value != tab) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tabNotifier?.value = tab;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = PriorityTabProvider.maybeOf(context);
    if (notifier != _tabNotifier) {
      _tabNotifier?.removeListener(_onTabNotifierChanged);
      _tabNotifier = notifier;
      _tabNotifier?.addListener(_onTabNotifierChanged);
      if (_tabNotifier != null) {
        if (!_appliedInitialTab && widget.initialTab != null) {
          _appliedInitialTab = true;
          _applyInitialTab();
        } else {
          _currentTab = _tabNotifier!.value;
        }
        // Force activity feed for activity-only priorities (viewers and
        // priorities configured with `config.view == 'activity'`).
        final priorityBloc = context.read<PriorityBloc>();
        if (priorityBloc.state.context.isActivityOnly &&
            _currentTab == PriorityTab.agenda) {
          _currentTab = PriorityTab.activityFeed;
          // Defer notifier update — setting it synchronously during
          // didChangeDependencies triggers setState in ancestor listeners.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _tabNotifier?.value = PriorityTab.activityFeed;
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _agendaListController.dispose();
    _tabNotifier?.removeListener(_onTabNotifierChanged);
    _blockDragController.dispose();
    _activityFeedDragController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PriorityBloc, PriorityState>(
      listener: (context, state) {
        final nowBloc = context.read<NowBloc>();
        nowBloc.setFocus(state.context);
        nowBloc.setContext(state.context);
        // Reset scroll to top on priority switch
        _agendaListController.jumpToTop();
        _removalKeys.clear();
        final scrollController = ScrollControllerContext.of(context);
        if (scrollController != null && scrollController.hasClients) {
          scrollController.jumpTo(0);
        }
      },
      listenWhen: (previous, current) =>
          previous.context.id != current.context.id,
      builder: (context, state) {
        return BlocBuilder<LayoutBloc, LayoutState>(
          builder: (context, layoutState) {
            final isUpNext =
                _currentTab == PriorityTab.agenda &&
                !state.context.isActivityOnly;
            var items = isUpNext
                ? state.agendaViewItems
                : state.activityFeedItems;

            // Build shortcuts map conditionally based on panel visibility
            final shortcuts = <ShortcutActivator, Intent>{
              const SingleActivator(LogicalKeyboardKey.enter):
                  const OpenFocusedItemActionsIntent(),
              const SingleActivator(LogicalKeyboardKey.escape):
                  const ClearItemFocusIntent(),
              // Plain Up/Down to navigate threads and handle focus transfer to ThreadPage
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
                    event.logicalKey == LogicalKeyboardKey.arrowUp &&
                    !hasModifiers;
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
                  final activeController =
                      layoutState.multiPanel &&
                          _currentTab == PriorityTab.agenda
                      ? _agendaListController
                      : listController;

                  final provider = _PriorityListControllerProvider.maybeOf(
                    context,
                  );
                  provider?.registerController(
                    layoutState.multiPanel
                        ? _agendaListController
                        : activeController,
                    activityFeedController: layoutState.multiPanel
                        ? listController
                        : null,
                  );

                  return Shortcuts(
                    shortcuts: shortcuts,
                    child: Actions(
                      actions: {
                        MoveFocusUpIntent: CallbackAction<MoveFocusUpIntent>(
                          onInvoke: (intent) {
                            final provider =
                                _PriorityListControllerProvider.maybeOf(
                                  context,
                                );
                            final controller =
                                provider?._resolveController(context) ??
                                activeController;
                            provider?._moveFocusOrStart(
                              controller,
                              -1,
                              context,
                            );
                            return null;
                          },
                        ),
                        MoveFocusDownIntent:
                            CallbackAction<MoveFocusDownIntent>(
                              onInvoke: (intent) {
                                final provider =
                                    _PriorityListControllerProvider.maybeOf(
                                      context,
                                    );
                                final controller =
                                    provider?._resolveController(context) ??
                                    activeController;
                                provider?._moveFocusOrStart(
                                  controller,
                                  1,
                                  context,
                                );
                                return null;
                              },
                            ),
                        OpenFocusedItemActionsIntent:
                            CallbackAction<OpenFocusedItemActionsIntent>(
                              onInvoke: (_) {
                                // Resolve the controller and items for
                                // whichever list the user is interacting
                                // with (agenda or activity feed).
                                final resolvedController =
                                    provider?._resolveController(context) ??
                                    activeController;
                                final priorityBloc = context
                                    .read<PriorityBloc>();
                                final source = priorityBloc
                                    .resolveThreadListSource();
                                final resolvedItems =
                                    source == ThreadListSource.agenda
                                    ? items
                                    : state.activityFeedItems;
                                final focusedIndex =
                                    resolvedController.focusedIndex;
                                if (focusedIndex != null &&
                                    focusedIndex >= 0 &&
                                    focusedIndex < resolvedItems.length) {
                                  // Capture bloc here so dispatched commands
                                  // (e.g. Archive) keep their optimistic path
                                  // alive when the modal context can't
                                  // resolve PriorityBloc.
                                  final capturedBloc = priorityBloc;
                                  context.run(
                                    OpenFocusedItemActions(resolvedController, (
                                      index,
                                    ) async {
                                      final item =
                                          index >= 0 &&
                                              index < resolvedItems.length
                                          ? resolvedItems[index]
                                          : null;
                                      if (item == null) {
                                        return <StaticCommandGroup>[];
                                      }
                                      return await item.when<
                                        Future<List<StaticCommandGroup>>
                                      >(
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
                            // Clear the resolved controller (may differ
                            // from activeController when navigating the
                            // activity feed on desktop)
                            final controller =
                                provider?._resolveController(context) ??
                                activeController;
                            controller.clearFocus();
                            if (controller != activeController) {
                              activeController.clearFocus();
                            }
                            // When ThreadPage is open, also focus ThreadEditor
                            activityProvider?._activityEditorFocusCallback
                                ?.call();
                            return null;
                          },
                        ),
                      },
                      child: CommandScope(
                        commandsBuilder: () {
                          final index = activeController.lastFocusedIndex;
                          if (index == null) {
                            return <StaticCommandGroup>[];
                          }
                          final item = index >= 0 && index < items.length
                              ? items[index]
                              : null;
                          return item?.when<List<StaticCommandGroup>>(
                                activity: (agendaActivity) =>
                                    threadCommandGroupsSync(
                                      agendaActivity.thread,
                                    ),
                                header: (_) => <StaticCommandGroup>[],
                              ) ??
                              <StaticCommandGroup>[];
                        },
                        listenable: activeController,
                        child: Scaffold(
                          scrollable: false,
                          translucent: true,
                          childPad: false,
                          body: layoutState.multiPanel
                              ? _buildDesktopBody(
                                  context,
                                  state,
                                  listController,
                                )
                              : isUpNext
                              ? ThreadListSourceProvider(
                                  source: ThreadListSource.agenda,
                                  child: _buildList(
                                    context,
                                    state,
                                    items,
                                    listController,
                                    ScrollControllerContext.of(context),
                                    enableReorder: !state.context.isViewer,
                                    doneEnd: state.doneEnd,
                                    scrollStorageKey: PageStorageKey(
                                      'priority_agenda_${widget.priorityId}',
                                    ),
                                  ),
                                )
                              : ThreadListSourceProvider(
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
      },
    );
  }

  Widget _buildDesktopBody(
    BuildContext context,
    PriorityState state,
    InfiniteListController activityController,
  ) {
    final isSearching =
        state.search.isNotEmpty ||
        state.filter.isNotEmpty ||
        state.iconFilter.isNotEmpty;

    // When searching, show only the activity feed at full height
    if (isSearching) {
      return ThreadListSourceProvider(
        source: ThreadListSource.activityFeed,
        child: _buildActivityFeed(
          context,
          state,
          state.activityFeedItems,
          activityController,
          ScrollControllerContext.of(context),
        ),
      );
    }

    final agendaItems = state.agendaViewItems;

    final isNowTab =
        _currentTab == PriorityTab.agenda && !state.context.isActivityOnly;

    return Column(
      children: [
        if (!state.context.isActivityOnly)
          BlocSelector<PrioritiesBloc, PrioritiesState, bool>(
            selector: (prioritiesState) {
              final p = prioritiesState.priorities.firstWhereOrNull(
                (p) => p.id == state.context.id,
              );
              if (p == null) return false;
              return prioritiesState.priorities.any(
                (d) => (d.id == p.id || p.path.isParent(d.path)) && d.unread,
              );
            },
            builder: (context, hasUnread) => _DesktopTabBar(
              currentTab: _currentTab,
              onTabChanged: _onDesktopTabChanged,
              hasUnreadActivity: hasUnread,
              priority: state.context,
            ),
          ),
        Expanded(
          child: isNowTab
              ? ThreadListSourceProvider(
                  source: ThreadListSource.agenda,
                  child: _buildList(
                    context,
                    state,
                    agendaItems,
                    _agendaListController,
                    null,
                    enableReorder: !state.context.isViewer,
                    doneEnd: state.doneEnd,
                    scrollStorageKey: PageStorageKey(
                      'priority_agenda_${widget.priorityId}',
                    ),
                  ),
                )
              : ThreadListSourceProvider(
                  source: ThreadListSource.activityFeed,
                  child: _buildActivityFeed(
                    context,
                    state,
                    state.activityFeedItems,
                    activityController,
                    ScrollControllerContext.of(context),
                    scrollStorageKey: PageStorageKey(
                      'priority_feed_${widget.priorityId}',
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  void _onDesktopTabChanged(PriorityTab tab) {
    setState(() {
      _currentTab = tab;
    });
    if (_tabNotifier != null && _tabNotifier!.value != tab) {
      _tabNotifier!.value = tab;
    }
  }

  /// Always 1px tall for stable layout. Default renders as 0.5px border +
  /// 0.5px background (thin). Active states fill the full 1px (bolder, and
  /// immune to sub-pixel anti-aliasing that dims the top border).
  Widget _buildSeparator(
    BuildContext context,
    List<AgendaItem> listItems,
    int index,
    PriorityState state,
    InfiniteListController controller,
  ) {
    final borderColor = context.theme.colors.border;
    final bg = context.colour.background;
    final AgendaItem? prev = index > 0 && index - 1 < listItems.length
        ? listItems[index - 1]
        : null;
    final AgendaItem? next = index < listItems.length ? listItems[index] : null;

    final selectedId = state.thread?.id;
    final hovered = controller.hoveredIndex;
    final focused = controller.focusedIndex;

    // The block drag controller drives two divider behaviours: hide
    // separators inside the collapsed source block, and suppress the
    // bright hover/focus highlight on adjacent threads (so dividers
    // don't read like drop targets while a block is being dragged).
    // Wrapping in [ListenableBuilder] guarantees the separator
    // re-evaluates when drag state changes, even if the InfiniteList
    // controller itself doesn't fire.
    final nextParentId = next is AgendaHeaderItem
        ? next.parentBlockId
        : next is AgendaThreadItem
        ? next.parentBlockId
        : null;

    // Hide every separator that sits directly above a hidden thread
    // row. With the row itself at zero height, a stack of 1px lines
    // would otherwise pile up at the collapsed block's location.
    // The trailing separator (the one above the *next* block's header)
    // remains and serves as the visible boundary between blocks.
    // [AnimatedSize] below interpolates the height change so the
    // separators slide closed in sync with the thread rows during a
    // priority context switch.
    final isAboveHiddenThread = next is AgendaThreadItem && next.hidden;
    return ListenableBuilder(
      listenable: _blockDragController,
      builder: (context, _) {
        // Hide separators inside the collapsing source block. Wrapped in
        // [AnimatedSize] below so the 1px collapse runs in sync with the
        // source header / thread row [AnimatedSize]s and the active drop
        // zone's [AnimatedContainer]. Hiding instantly here would yank
        // the separators out of layout one frame before the rest of the
        // block starts animating — visible as a brief upward jump in
        // everything below the source while the surrounding animations
        // catch up.
        final shouldHide =
            isAboveHiddenThread ||
            (nextParentId != null &&
                _blockDragController.draggingBlockId == nextParentId &&
                !_blockDragController.isSourceVisible);

        // Selected: full 1px tinted border (still shown during a drag —
        // selection is a persistent state, not a hover affordance).
        final baseBorder = Color.alphaBlend(borderColor, bg);
        Widget separator;
        if (prev is AgendaThreadItem && prev.thread.id == selectedId) {
          final accent = context.colour.colours
              .fromTheme(prev.thread.priority.displayColor)
              .withValues(alpha: 0.3);
          separator = Container(
            height: 1,
            color: Color.alphaBlend(accent, baseBorder),
          );
        } else if (next is AgendaThreadItem && next.thread.id == selectedId) {
          final accent = context.colour.colours
              .fromTheme(next.thread.priority.displayColor)
              .withValues(alpha: 0.3);
          separator = Container(
            height: 1,
            color: Color.alphaBlend(accent, baseBorder),
          );
        } else {
          // Hover/focus (threads only): full 1px bright border. Skip the
          // bright style if the adjacent item is being dragged in the
          // thread reorder list, or if any block-level drag is in
          // progress.
          final isBlockDragging = _blockDragController.isDragging;
          final dragging = controller.draggingIndex;
          final prevHighlighted =
              prev is AgendaThreadItem &&
              !isBlockDragging &&
              (hovered == index - 1 || focused == index - 1) &&
              dragging != index - 1;
          final nextHighlighted =
              next is AgendaThreadItem &&
              !isBlockDragging &&
              (hovered == index || focused == index) &&
              dragging != index;
          if (prevHighlighted || nextHighlighted) {
            final bright = borderColor.withValues(
              alpha: (borderColor.a * 2).clamp(0.0, 1.0),
            );
            separator = Container(
              height: 1,
              color: Color.alphaBlend(bright, bg),
            );
          } else {
            // Default: transparent for first item (avoids double border
            // with header), otherwise the standard border color.
            separator = Container(
              height: 1,
              color: prev == null ? bg : baseBorder,
            );
          }
        }

        return AnimatedSize(
          duration: kBlockBoundaryAnimDuration,
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: shouldHide ? const SizedBox.shrink() : separator,
        );
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    PriorityState state,
    List<AgendaItem> items,
    InfiniteListController controller,
    ScrollController? scrollController, {
    required bool enableReorder,
    required bool doneEnd,
    PageStorageKey<String>? scrollStorageKey,
  }) {
    final listItems = items;

    final hasThreads = listItems.any((item) => item is AgendaThreadItem);
    final showEmptyHint = !hasThreads;

    // Precompute block-boundary metadata for [BlockDropZone] insertion.
    // See [computeBlockDropBoundaries] for the period-attribution rules.
    final boundaries = computeBlockDropBoundaries(items: listItems);
    final beforeBoundaries = boundaries.before;
    final afterBoundaries = boundaries.after;
    final afterListBoundary = boundaries.afterList;

    final bloc = context.read<PriorityBloc>();
    final list = InfiniteList(
      controller: controller,
      scrollController: scrollController,
      scrollStorageKey: scrollStorageKey,
      initialScrollOffset: bloc.agendaScrollOffset,
      onScrollOffsetChanged: (offset) => bloc.agendaScrollOffset = offset,
      count: listItems.length,
      doneEnd: doneEnd,
      itemKey: (index) {
        if (index < 0 || index >= listItems.length) return 'empty_$index';
        return listItems[index].stableKey;
      },
      nonReorderablePrefixCount:
          enableReorder &&
              listItems.isNotEmpty &&
              listItems.first is AgendaHeaderItem &&
              (listItems.first as AgendaHeaderItem).date == null
          ? 1
          : 0,
      fetcher: (first, count) =>
          context.read<PriorityBloc>().fetchMoreAgendaItems(first, count),
      separatorBuilder: (context, index) =>
          _buildSeparator(context, listItems, index, state, controller),
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= listItems.length) {
          return null;
        }
        final current = listItems[index];
        final beforeBoundary = beforeBoundaries[index];
        // After-boundary sources: empty-date-section slot (anchored to a
        // date header), or end-of-list afterListBoundary on the last
        // item. They never both apply to the same row — empty-section
        // slots attach to date headers; afterListBoundary attaches only
        // to the final list item, which is a date header only when the
        // last section is empty (in which case afterListBoundary is
        // null because prevBlockId was reset).
        final afterBoundary =
            afterBoundaries[index] ??
            ((index == listItems.length - 1) ? afterListBoundary : null);

        // Gap headers render their before-boundary BELOW the row
        // instead of above. Blocks can only land in gaps, so the
        // drop preview should appear inside the gap (after the gap
        // header) rather than in the empty space between the
        // preceding event and the gap header.
        final isGapHeader = current is AgendaHeaderItem &&
            current.dateTimeRange != null &&
            current.thread == null &&
            current.parentBlockId != null &&
            current.sourcePeriodStart != null;

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey(current.stableKey),
          children: [
            if (beforeBoundary != null && !isGapHeader)
              BlockDropZone(
                key: ValueKey('block_drop_before_${current.stableKey}'),
                slotKey: 'block_drop_before_${current.stableKey}',
                target: beforeBoundary,
              ),
            ...current.when(
              header: (header) {
                return [
                  if (showEmptyHint && index == 0) ...[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.contentPaddingH,
                        vertical: context.theme.spacing.xl,
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Threads you ',
                            style: TextStyle(
                              color: context.theme.plotColors.veryMuted,
                              fontSize: context.theme.typography.sm.fontSize,
                            ),
                          ),
                          FaIcon(
                            PlotIcon.addTodo,
                            size: context.theme.typography.sm.fontSize,
                            color: context.theme.plotColors.veryMuted,
                          ),
                          Text(
                            ' start or ',
                            style: TextStyle(
                              color: context.theme.plotColors.veryMuted,
                              fontSize: context.theme.typography.sm.fontSize,
                            ),
                          ),
                          FaIcon(
                            PlotIcon.schedule,
                            size: context.theme.typography.sm.fontSize,
                            color: context.theme.plotColors.veryMuted,
                          ),
                          Text(
                            ' schedule will appear here.',
                            style: TextStyle(
                              color: context.theme.plotColors.veryMuted,
                              fontSize: context.theme.typography.sm.fontSize,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(height: 1, color: context.theme.colors.border),
                  ],
                  AgendaHeader(
                    key: ValueKey('agendaheader_${header.stableKey}'),
                    priorityContext: state.context,
                    dateTimeRange: header.dateTimeRange,
                    date: header.date,
                    now: header.now,
                    isNext: header.isNext,
                    thread: header.thread,
                    focusNode: focusNode,
                    text: header.text,
                    scheduleAt: header.scheduleAt,
                    blockPriority: header.blockPriority,
                    parentBlockId: header.parentBlockId,
                    sourceDate: header.sourceDate,
                    sourcePeriodStart: header.sourcePeriodStart,
                    parentBlockVisibleCount: header.parentBlockVisibleCount,
                    isOutsidePriority: header.isOutsidePriority,
                  ),
                ];
              },
              activity: (agendaActivity) {
                final isBeingDragged = controller.draggingIndex == index;
                final itemKey = agendaActivity.stableKey;
                final removalKey = _getRemovalKey(itemKey);
                final row = BlockDragHidden(
                  parentBlockId: agendaActivity.parentBlockId,
                  child: AnimatedRemoval(
                    key: removalKey,
                    onRemoved: () {
                      // Drop the cached GlobalKey so the next render builds
                      // a fresh AnimatedRemoval (with _removed=false). When
                      // the thread is associated, the bloc rebuild puts A
                      // back under its parent event with the same stableKey;
                      // without clearing this we'd reparent the just-collapsed
                      // State and render an empty box forever.
                      _removalKeys.remove(itemKey);
                      context.read<PriorityBloc>().optimisticallyRemoveThread(
                        agendaActivity.thread.id,
                        finishTodo: true,
                      );
                    },
                    child: ThreadWidget(
                      key: ValueKey('widget_$itemKey'),
                      activity: agendaActivity.thread,
                      selected:
                          !isBeingDragged &&
                          state.thread != null &&
                          agendaActivity.thread.id == state.thread!.id,
                      now: agendaActivity.now,
                      isNext: agendaActivity.isNext,
                      isAssociated: agendaActivity.isAssociated,
                      isOutsidePriority: agendaActivity.isOutsidePriority,
                      focusNode: focusNode,
                      context: state.context,
                      onSwipeExit: (command) async {
                        // Swipeable already slid the thread off-screen.
                        // Now collapse the gap, then execute the command.
                        await removalKey.currentState?.remove();
                        if (context.mounted) {
                          await context.run(command);
                        }
                      },
                      onMobileFinish: () async {
                        await removalKey.currentState?.remove();
                      },
                      onDesktopFinish: () async {
                        await removalKey.currentState?.remove(fade: true);
                      },
                      reorderableIndex:
                          enableReorder &&
                              !agendaActivity.thread.isLinkScheduleInstance
                          ? reorderableIndex
                          : null,
                    ),
                  ),
                );
                // Animate expand/collapse: rows for collapsed blocks are
                // mounted but rendered as zero-height. [AnimatedSize]
                // smoothly interpolates the layout slot when [hidden]
                // flips, so toggling a priority context slides the
                // affected blocks open/closed instead of jumping.
                return [
                  AnimatedSize(
                    duration: kBlockExpandAnimDuration,
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: agendaActivity.hidden
                        ? const SizedBox(width: double.infinity, height: 0)
                        : row,
                  ),
                ];
              },
            ),
            if (beforeBoundary != null && isGapHeader)
              // Gap headers: the slot is rendered HERE, below the
              // gap header row, so the drop preview opens in the
              // gap rather than between the preceding block and the
              // gap header. Distinct slotKey from block_drop_before_*
              // and block_drop_after_* so the State machinery doesn't
              // confuse it with either category.
              BlockDropZone(
                key: ValueKey('block_drop_in_gap_${current.stableKey}'),
                slotKey: 'block_drop_in_gap_${current.stableKey}',
                target: beforeBoundary,
              ),
            if (afterBoundary != null)
              BlockDropZone(
                key: ValueKey('block_drop_after_${current.stableKey}'),
                slotKey: 'block_drop_after_${current.stableKey}',
                target: afterBoundary,
              ),
          ],
        );
      },
      onReorder: enableReorder
          ? (index) {
              if (index < 0 || index >= listItems.length) {
                return null;
              }
              final item = listItems[index];

              // Block-header drag is now handled out-of-band by the
              // [BlockDragPayload] / [BlockDropZone] system, not the
              // SliverReorderableList. Block headers do not produce
              // reorderable indices; this branch remains as a safety
              // net (e.g. if a future change re-introduces a header
              // path we'll still no-op rather than crash).
              if (item is AgendaHeaderItem &&
                  item.blockPriority != null &&
                  item.thread == null &&
                  item.date == null &&
                  item.dateTimeRange == null &&
                  !item.isOutsidePriority) {
                return _buildBlockHeaderReorderCallback(
                  context: context,
                  listItems: listItems,
                  oldIndex: index,
                  sourcePriority: item.blockPriority!,
                );
              }

              final activity = item.when<Thread?>(
                header: (header) => null,
                activity: (agendaActivity) => agendaActivity.thread,
              );
              final isAssociated = item.when(
                header: (_) => false,
                activity: (a) => a.isAssociated,
              );
              if (activity == null || activity.isLinkScheduleInstance) {
                return null;
              }
              // Allow dragging todos and associated threads
              if (activity.todo != true && !isAssociated) {
                return null;
              }
              return (int newIndex) {
                final oldListIndex = index;
                var newListIndex = newIndex;

                // Identify the destination block by inspecting items
                // adjacent to the drop position. Order.between across
                // blocks is meaningless — different priority blocks have
                // wildly different order scales (a block whose threads
                // were created from emails has tiny orders, while a
                // user-created block uses recent timestamps), so a
                // midpoint can land anywhere relative to the same-block
                // neighbors and undo the visual move.
                final dropAnchor = oldListIndex < newListIndex
                    ? newListIndex
                    : newListIndex - 1;
                String? destBlockId;
                for (var i = dropAnchor; i >= 0; i--) {
                  if (i == oldListIndex) continue;
                  final li = listItems[i];
                  if (li is AgendaHeaderItem && li.date != null) break;
                  final blockId = li.when<String?>(
                    header: (h) => h.parentBlockId,
                    activity: (a) => a.parentBlockId,
                  );
                  if (blockId != null) {
                    destBlockId = blockId;
                    break;
                  }
                }
                if (destBlockId == null) {
                  for (var i = dropAnchor + 1; i < listItems.length; i++) {
                    if (i == oldListIndex) continue;
                    final li = listItems[i];
                    if (li is AgendaHeaderItem && li.date != null) break;
                    final blockId = li.when<String?>(
                      header: (h) => h.parentBlockId,
                      activity: (a) => a.parentBlockId,
                    );
                    if (blockId != null) {
                      destBlockId = blockId;
                      break;
                    }
                  }
                }

                // Build list of todo items with their indices (excluding
                // the dragged item) so we can find the correct neighbors.
                // Stop at the first date header past both old and new
                // positions so items from later sections don't pollute
                // the order calculation. Restrict to the destination
                // block so Order.between operates within a single order
                // space.
                final dropBound = oldListIndex > newListIndex
                    ? oldListIndex
                    : newListIndex;
                final todoItems = <(int, Thread)>[];
                for (var i = 0; i < listItems.length; i++) {
                  if (i == oldListIndex) continue;
                  final li = listItems[i];
                  if (li is AgendaHeaderItem &&
                      li.date != null &&
                      i > dropBound) {
                    break;
                  }
                  final liBlockId = li.when<String?>(
                    header: (h) => h.parentBlockId,
                    activity: (a) => a.parentBlockId,
                  );
                  if (destBlockId != null && liBlockId != destBlockId) {
                    continue;
                  }
                  final t = li.when<Thread?>(
                    header: (_) => null,
                    activity: (a) => a.thread,
                  );
                  final liAssocOrder = li.when<Order?>(
                    header: (_) => null,
                    activity: (a) => a.associationOrder,
                  );
                  if (t != null && (t.todo || liAssocOrder != null)) {
                    // For associated items, create a proxy with the
                    // association order so Order.between sees correct
                    // neighbors.
                    final effective = liAssocOrder != null
                        ? t.copyWith(order: liAssocOrder)
                        : t;
                    todoItems.add((i, effective));
                  }
                }

                // Find the target section's date-header boundaries in the
                // original (pre-removal) list so prevTodo/nextTodo stay
                // within the same day.
                var sectionStartIdx = 0;
                var sectionEndIdx = listItems.length;
                {
                  final scanRef = oldListIndex < newListIndex
                      ? newListIndex
                      : newListIndex - 1;
                  for (var i = scanRef; i >= 0; i--) {
                    if (i == oldListIndex) continue;
                    final li = listItems[i];
                    if (li is AgendaHeaderItem && li.date != null) {
                      sectionStartIdx = i;
                      break;
                    }
                  }
                  for (var i = scanRef + 1; i < listItems.length; i++) {
                    if (i == oldListIndex) continue;
                    final li = listItems[i];
                    if (li is AgendaHeaderItem && li.date != null) {
                      sectionEndIdx = i;
                      break;
                    }
                  }
                }

                // Find the insertion point among todos. The dragged item
                // should be inserted at the position corresponding to
                // newListIndex, but only relative to other todo items
                // within the same section.
                Thread? prevTodo;
                Thread? nextTodo;
                for (var i = 0; i < todoItems.length; i++) {
                  final (todoIdx, todo) = todoItems[i];
                  if (todoIdx < sectionStartIdx || todoIdx >= sectionEndIdx) {
                    if (todoIdx >= sectionEndIdx) break;
                    continue;
                  }
                  // Adjust for the removed item when comparing positions
                  final adjustedIdx = oldListIndex < todoIdx
                      ? todoIdx - 1
                      : todoIdx;
                  if (adjustedIdx < newListIndex) {
                    prevTodo = todo;
                  } else {
                    nextTodo = todo;
                    break;
                  }
                }

                // Determine target day and event from drop position.
                // newListIndex is in post-removal coordinates, but
                // listItems is pre-removal. When dragging down,
                // indices after oldListIndex shift by 1, so adjust
                // the scan start back to original-list coordinates.
                Date? targetDate;
                Thread? targetEvent;
                Priority? targetBlockPriority;
                final scanStart = oldListIndex < newListIndex
                    ? newListIndex // +1 for pre-removal, -1 for "before"
                    : newListIndex - 1;
                DateTime? nearestGapStart;
                var passedGap = false;
                for (var i = scanStart; i >= 0; i--) {
                  if (i == oldListIndex) continue;
                  final item = listItems[i];
                  if (item is AgendaHeaderItem) {
                    // First block header above the drop point identifies
                    // the destination block — its priority becomes the
                    // thread's priority (per "drop into a different
                    // priority block adopts that priority").
                    if (targetBlockPriority == null &&
                        item.blockPriority != null) {
                      targetBlockPriority = item.blockPriority;
                    }
                    // Track gap headers to distinguish "after event"
                    // from "in gap" — they use different pin times.
                    if (item.dateTimeRange != null &&
                        item.date == null &&
                        item.text == null &&
                        targetEvent == null) {
                      passedGap = true;
                      nearestGapStart ??= item.dateTimeRange!.start;
                    }
                    if (item.date != null) {
                      targetDate = item.date;
                      break;
                    }
                  } else if (item is AgendaThreadItem) {
                    // Detect scheduled events — event headers are stripped
                    // by agendaViewItems, so we detect from threads
                    // directly. Matches both link schedule instances and
                    // regular timed activities.
                    if (targetEvent == null &&
                        !item.thread.todo &&
                        item.thread.at?.end != null) {
                      targetEvent = item.thread;
                    }
                  }
                }
                // If no date header found, target is "Now" (null date).

                // For within-section drops, align the dragged item's date
                // with its prev (or next) neighbor's [todoSortDate]. The
                // agenda's [AgendaSort.compareThreadsInBlock] sorts most-
                // recently-arrived first then by order ASC; tying arrival
                // with prev (or next) ensures the order tiebreak places
                // the dragged item in the user-chosen position. Without
                // this, sections that mix overdue + scheduled + "now"
                // todos (each clamped into today by [Thread.agendaAt])
                // re-promote the drop to the wrong slot because the items
                // have different real dates. For cross-section drops, fall
                // back to the section header's date so the move actually
                // changes the section.
                final activitySectionDate = activity.agendaAt.toDate();
                final crossingSection = activitySectionDate != targetDate;
                final prevTodoDate = prevTodo?.todoSortDate.toDate();
                final nextTodoDate = nextTodo?.todoSortDate.toDate();
                final Date? effectiveTargetDate;
                if (crossingSection) {
                  effectiveTargetDate = targetDate;
                } else {
                  effectiveTargetDate =
                      prevTodoDate ?? nextTodoDate ?? targetDate;
                }

                // Restrict the order math to neighbors in the same
                // arrival-time group as effectiveTargetDate. Overdue
                // todos roll forward into today's section but keep
                // their original todoSortDate, so a today-todo and a
                // yesterday-todo can be visually adjacent yet sit in
                // different arrival groups. Averaging across that
                // boundary produces a manual order that lands inside
                // the user's previous position (e.g. midpoint of the
                // far neighbors equals the dragged item's stored
                // order if it was placed there before), and even if
                // committed it wouldn't move the visible row because
                // the arrival-time DESC rule still puts it in the
                // wrong group. Drop into the prev neighbor's group
                // by ignoring next when their dates differ (or vice
                // versa).
                final prevTodoForOrder =
                    prevTodoDate == effectiveTargetDate ? prevTodo : null;
                final nextTodoForOrder =
                    nextTodoDate == effectiveTargetDate ? nextTodo : null;
                final newOrder = Order.between(
                  prevTodoForOrder?.order,
                  nextTodoForOrder?.order,
                );

                final currentDate =
                    activity.on?.start ?? activity.at?.start?.toDate();
                final dateChanged = effectiveTargetDate != currentDate;
                final wasPinned = activity.isPinnedTodo;
                // Pin time: gap start when dropped into a gap (passedGap),
                // event start when dropped right after an event.
                final DateTime? pinTime;
                if (passedGap && nearestGapStart != null) {
                  pinTime = nearestGapStart;
                } else if (!passedGap && targetEvent?.at?.start != null) {
                  pinTime = targetEvent!.at!.start!;
                } else {
                  pinTime = null;
                }
                final pinningToEvent = pinTime != null;

                // Skip if nothing changed (but never skip for associated
                // threads — they always need to disassociate when dragged).
                if (!isAssociated &&
                    newOrder.value == activity.order.value &&
                    !dateChanged &&
                    !pinningToEvent &&
                    !wasPinned) {
                  _log.info(
                    '[onReorder] "${activity.title}" '
                    'order unchanged (${newOrder.value}) '
                    'old=$oldListIndex -> new=$newListIndex '
                    'destBlock=$destBlockId '
                    'prevTodo="${prevTodo?.title}" (${prevTodo?.order.value}) '
                    'nextTodo="${nextTodo?.title}" (${nextTodo?.order.value}), '
                    'skipping',
                  );
                  return;
                }

                _log.info(
                  '[onReorder] "${activity.title}" '
                  'old=$oldListIndex -> new=$newListIndex '
                  'destBlock=$destBlockId '
                  'prevTodo="${prevTodo?.title}" (${prevTodo?.order.value}) '
                  'nextTodo="${nextTodo?.title}" (${nextTodo?.order.value}) '
                  '-> newOrder=${newOrder.value} '
                  'todo=${activity.todo} '
                  'isAssociated=$isAssociated '
                  'hasUserSched=${activity.hasUserSchedule} '
                  'outstandingTasks=${activity.outstandingTasks}'
                  '${dateChanged ? ' dateChange=$currentDate->$effectiveTargetDate' : ''}'
                  '${pinningToEvent ? ' pinTime=$pinTime gap=$passedGap nearestGap=$nearestGapStart event="${targetEvent?.title}"' : ''}'
                  '${wasPinned && !pinningToEvent ? ' unpinning' : ''}',
                );

                Thread updatedActivity;
                bool needsFullSave = false;
                bool useAssociation = false;

                // Dropped immediately after a scheduled event (link or
                // user-created) — treat the drop as "add this thread to
                // the event". Association archives the thread's user
                // schedule so it disappears from elsewhere in the agenda
                // and renders only as a child of the event.
                final droppingOnEvent = !passedGap && targetEvent != null;

                if (droppingOnEvent) {
                  // CREATE/MOVE ASSOCIATION: dropped right after an event.
                  // Mirror what `associateWith` will persist by archiving
                  // the user schedule on the optimistic copy. Without this,
                  // the optimistic agenda renders the thread BOTH at its
                  // old scheduled position (still has todo=true) AND under
                  // the event header — the thread visibly disappears and
                  // reappears once the DB write catches up.
                  updatedActivity = activity.withScheduleArchived();
                  useAssociation = true;
                } else if (isAssociated) {
                  // REMOVE ASSOCIATION: associated thread dragged away.
                  // Apply schedule changes so the optimistic UI shows the
                  // thread at its new position as a regular todo.
                  if (activity.todo) {
                    // Thread has active user schedule — update it
                    if (dateChanged || activity.isPinnedTodo) {
                      updatedActivity = activity.reorderTo(
                        newOrder,
                        date: effectiveTargetDate,
                      );
                    } else {
                      updatedActivity = activity.reorder(newOrder);
                    }
                  } else {
                    // No active user schedule — disassociate will create one.
                    // Use reorderTo so the optimistic copy has the new order,
                    // ensuring _pendingReorderOrder doesn't match immediately.
                    updatedActivity = activity
                        .copyWith(todo: true)
                        .reorderTo(newOrder, date: effectiveTargetDate);
                  }
                } else if (pinningToEvent) {
                  // Dropped in a gap → pin to gap start. (The "dropped
                  // immediately after an event" case was captured by
                  // [droppingOnEvent] above and turned into an
                  // association, so this branch now only handles gap
                  // drops.)
                  updatedActivity = activity.reorderToAfterEvent(
                    newOrder,
                    eventEndTime: pinTime,
                  );
                } else if (dateChanged || wasPinned) {
                  // Date changed or unpinning a previously pinned todo
                  updatedActivity = activity.reorderTo(
                    newOrder,
                    date: effectiveTargetDate,
                  );
                } else {
                  // Use reorderTo to normalize the schedule date to the
                  // target section so todoCompareTo (which sorts by date
                  // first, then order) doesn't override the user's chosen
                  // position with a stale date.
                  if (effectiveTargetDate != null ||
                      activity.on?.start != null ||
                      activity.at?.start != null) {
                    updatedActivity = activity.reorderTo(
                      newOrder,
                      date: effectiveTargetDate,
                    );
                  } else {
                    updatedActivity = activity.reorder(newOrder);
                  }
                }

                // End-of-block drops keep the thread's own priority so a
                // new block is created (or — when the destination period
                // already contains a block of the thread's priority —
                // consolidation merges into it). The exception is a
                // same-period drop: the source's priority block IS the
                // existing block in this period, so the user is clearly
                // moving the thread OUT of it; fall through to the
                // standard "adopt destination block's priority" path.
                String? justBelowBlockId;
                var justBelowFound = false;
                for (var i = dropAnchor + 1; i < listItems.length; i++) {
                  if (i == oldListIndex) continue;
                  final li = listItems[i];
                  if (li is AgendaHeaderItem && li.date != null) {
                    justBelowFound = true;
                    break;
                  }
                  final blockId = li.when<String?>(
                    header: (h) => h.parentBlockId,
                    activity: (a) => a.parentBlockId,
                  );
                  if (blockId == null) continue;
                  justBelowFound = true;
                  justBelowBlockId = blockId;
                  break;
                }
                final isEndOfBlockDrop =
                    destBlockId != null &&
                    (!justBelowFound || justBelowBlockId != destBlockId);

                final sourcePeriod = _resolvePeriod(
                  listItems,
                  oldListIndex,
                  scanFromIndex: oldListIndex,
                );
                final destPeriod = _resolvePeriod(
                  listItems,
                  oldListIndex,
                  scanFromIndex: dropAnchor,
                );
                final crossesPeriod =
                    sourcePeriod.gapAnchor != destPeriod.gapAnchor ||
                    sourcePeriod.dateAnchor != destPeriod.dateAnchor;

                final keepOwnPriority = isEndOfBlockDrop && crossesPeriod;

                // Drop into a different priority block: adopt that
                // block's priority. Skipped for [useAssociation] — the
                // thread is being put under an event association and
                // its priority is governed by the association edge, not
                // the block boundary. Skipped for end-of-block drops
                // that cross periods — see comment above.
                if (!useAssociation &&
                    !keepOwnPriority &&
                    targetBlockPriority != null &&
                    targetBlockPriority.id != updatedActivity.priority.id) {
                  updatedActivity = updatedActivity.copyWith(
                    priority: targetBlockPriority,
                  );
                  needsFullSave = true;
                }

                // Optimistic update: stitch the moved thread into the
                // bloc's cached source list and rebuild the agenda
                // model. The block-aware rebuild moves headers in
                // sync with the thread, avoiding the visual jank
                // splice-based reorderViewItems used to produce.
                context.read<PriorityBloc>().moveAgendaItem(
                  movedThread: updatedActivity,
                  associatingWithParent: useAssociation
                      ? targetEvent!.id
                      : null,
                  // Match the order `associateWith` is about to write so
                  // the optimistic association row sorts at the dropped
                  // position rather than at the source thread's stale
                  // user-schedule order.
                  associationOrder: useAssociation ? newOrder : null,
                  disassociating: isAssociated && !droppingOnEvent,
                );

                // Persist changes
                if (useAssociation) {
                  // Create association, then archive the user schedule so
                  // the thread renders only under the event (matches the
                  // visual position the user dropped it at).
                  activity
                      .associateWith(
                        parentThreadId: targetEvent!.id,
                        order: newOrder,
                      )
                      .then((_) => activity.withScheduleArchived().save());
                } else if (isAssociated && !droppingOnEvent) {
                  // Optimistically clear association so _makeAgenda doesn't
                  // re-add the thread under the event on next rebuild.
                  context.read<PriorityBloc>().optimisticallyDisassociate(
                    activity.id,
                  );
                  // Remove association, then restore the user schedule at
                  // the dropped position so the thread reappears as a todo.
                  activity
                      .disassociate(order: newOrder)
                      .then(
                        (_) => activity
                            .withScheduleRestored(
                              order: newOrder,
                              date: effectiveTargetDate,
                            )
                            .save(),
                      );
                } else if (needsFullSave) {
                  updatedActivity.save();
                } else {
                  updatedActivity.saveOrder();
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _log.info(
                    '[onReorder] post-frame: reorderViewItems=${context.read<PriorityBloc>().state.reorderViewItems != null}',
                  );
                });
              };
            }
          : null,
    );

    // Re-wire the controller's dispatcher each build so it always points
    // at the latest [listItems] (the source-of-truth for resolving target
    // boundaries). Without this, a stale list captured at first build
    // would be used, and drops after any agenda change would target wrong
    // boundaries — or worse, ones that have since vanished.
    _blockDragController.dispatcher = (payload, target) {
      _dispatchBlockDrop(context, listItems, payload, target);
    };

    // Same re-wire pattern: the preview builder needs the latest
    // [listItems] to find the source block's content. The active
    // [BlockDropZone] calls this to render a dimmed copy of the block
    // inside the gap.
    _blockDragController.previewBuilder = (payload) =>
        _buildBlockDragPreview(state, listItems, payload);

    return BlockDragScope(controller: _blockDragController, child: list);
  }

  /// Build a static dimmed preview of the source block's content
  /// (header + visible thread rows + collapsed-overflow row, if any).
  /// Returned widget is rendered inside the active [BlockDropZone] so
  /// the gap shows what will land there. Caller wraps in [Opacity] +
  /// [IgnorePointer].
  ///
  /// Returns `null` when the source block can't be found (the drop
  /// zone falls back to an empty gap).
  Widget? _buildBlockDragPreview(
    PriorityState state,
    List<AgendaItem> listItems,
    BlockDragPayload payload,
  ) {
    final children = <Widget>[];
    var started = false;
    for (final item in listItems) {
      final itemBlockId = item.when(
        header: (h) => h.parentBlockId,
        activity: (a) => a.parentBlockId,
      );
      if (!started) {
        if (item is AgendaHeaderItem && itemBlockId == payload.blockId) {
          started = true;
        } else {
          continue;
        }
      } else if (itemBlockId != payload.blockId) {
        break;
      }

      item.when(
        header: (h) {
          // Pass parentBlockId: null so the preview header isn't
          // itself draggable / wrapped in the BlockDragHidden source
          // collapse logic — we want a static visual.
          children.add(
            AgendaHeader(
              priorityContext: state.context,
              dateTimeRange: h.dateTimeRange,
              date: h.date,
              now: h.now,
              isNext: h.isNext,
              thread: h.thread,
              text: h.text,
              scheduleAt: h.scheduleAt,
              blockPriority: h.blockPriority,
              isOutsidePriority: h.isOutsidePriority,
            ),
          );
        },
        activity: (a) {
          // Hidden rows (collapsed block) don't contribute to the
          // drag preview — we render only what's actually visible in
          // the agenda above the drop zone.
          if (a.hidden) return;
          children.add(
            ThreadWidget(
              activity: a.thread,
              context: state.context,
              now: a.now,
              isNext: a.isNext,
              isAssociated: a.isAssociated,
              isOutsidePriority: a.isOutsidePriority,
            ),
          );
        },
      );
    }

    if (children.isEmpty) return null;

    // Interleave 1px dividers between consecutive rows AND append one
    // after the last row so the preview matches the source block's
    // captured height. The list's [_buildSeparator] inserts a divider
    // between every consecutive pair of rows; [sourceTotalHeight] is
    // measured from the source's top to the top of the slot that sits
    // *below* the trailing separator, so the divider after the last
    // thread is part of that captured height. Without these dividers
    // the preview is shorter than the expanded drop zone, leaving an
    // empty strip at the bottom and producing a visible vertical shift
    // whenever the dragged content renders anywhere but its origin.
    final dividerColor = Color.alphaBlend(
      context.theme.colors.border,
      context.colour.background,
    );
    Widget divider() => Container(height: 1, color: dividerColor);
    final interleaved = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) interleaved.add(divider());
      interleaved.add(children[i]);
    }
    interleaved.add(divider());
    return Column(mainAxisSize: MainAxisSize.min, children: interleaved);
  }

  /// Dispatch a block-drop event from the [BlockDragController].
  ///
  /// Source identity comes from [payload.blockId]; target slot is
  /// described by [target]. Same-period reorders go through
  /// [PriorityBloc.reorderBlockWithinPeriod] (writes a `priority_block`
  /// row). Cross-period or cross-date moves go through
  /// [PriorityBloc.moveBlock] (rewrites every contained thread's
  /// schedule). Drops adjacent to the source are filtered upstream by
  /// the controller's no-op slot logic, so we only see meaningful drops
  /// here.
  void _dispatchBlockDrop(
    BuildContext context,
    List<AgendaItem> listItems,
    BlockDragPayload payload,
    BlockDropTarget target,
  ) {
    // Find the source row to read its sourceDate/sourcePeriodStart.
    // Collecting ids from `listItems` alone is unsafe: `listItems` is
    // the collapsed flat view, so threads beyond the block's collapse
    // limit are absent and would silently stay behind. Resolve the
    // full thread set from the canonical agenda block instead, with
    // a `listItems`-walk fallback for the race window where the bloc
    // emitted a state with no matching block.
    AgendaHeaderItem? source;
    int? sourceIndex;
    final fallbackThreadIds = <ThreadId>{};
    for (var i = 0; i < listItems.length; i++) {
      final it = listItems[i];
      if (source == null) {
        if (it is AgendaHeaderItem && it.parentBlockId == payload.blockId) {
          source = it;
          sourceIndex = i;
        }
        continue;
      }
      // We've found the source header — keep walking while the items
      // belong to the same block, harvesting their thread ids as a
      // fallback in case the canonical block lookup misses.
      if (it is AgendaThreadItem && it.parentBlockId == payload.blockId) {
        fallbackThreadIds.add(it.thread.id);
        continue;
      }
      if (it is AgendaHeaderItem && it.parentBlockId == payload.blockId) {
        // Multi-header block (e.g. event + associated rows wrapped in
        // a single block) — stay on this block.
        continue;
      }
      break;
    }
    final canonicalBlock = context.read<PriorityBloc>().state.agenda.blockById(
      payload.blockId,
    );
    final sourceThreadIds = canonicalBlock != null
        ? {for (final t in canonicalBlock.threads) t.id}
        : fallbackThreadIds;
    if (source == null || sourceIndex == null || source.blockPriority == null) {
      _log.info(
        '[block-drop] dispatch skipped: source not found / no blockPriority '
        '(blockId=${payload.blockId} sourceFound=${source != null} '
        'blockPriorityNull=${source?.blockPriority == null})',
      );
      return;
    }
    final sourcePriority = source.blockPriority!;
    final sourceDate = source.sourceDate;
    final sourcePeriodStart = source.sourcePeriodStart;

    final sameDate = sourceDate == target.targetDate;
    final samePeriod = sourcePeriodStart == target.targetPeriodStart;
    _log.info(
      '[block-drop] dispatch entry: priority=${sourcePriority.id} '
      'sourceDate=$sourceDate sourcePeriodStart=$sourcePeriodStart '
      'targetDate=${target.targetDate} '
      'targetPeriodStart=${target.targetPeriodStart} '
      'targetPrev=${target.prevBlockId} targetNext=${target.nextBlockId} '
      'sameDate=$sameDate samePeriod=$samePeriod '
      'threadIds=${sourceThreadIds.length} '
      '(canonical=${canonicalBlock != null} '
      'visible=${fallbackThreadIds.length})',
    );

    final bloc = context.read<PriorityBloc>();
    if (!sameDate || !samePeriod) {
      // Cross-period move — rewrite contained-thread schedules to the
      // target gap anchor. When the target sits above any gap on its
      // date (e.g. the user drops the block above the day's first
      // event), fall back to a sensible anchor so the block lands at
      // the top of that date instead of the older "no gap → no-op"
      // behavior, which felt like the block snapped back on release.
      //
      //   - Today / past date → `now`, matching the same-period
      //     reorder code path's behavior for missing gap anchors.
      //   - Future date → that date's midnight, so the block sorts
      //     at the very top of the future day's content.
      DateTime? anchor = target.targetPeriodStart;
      if (anchor == null) {
        final td = target.targetDate;
        if (td != null && td.isAfter(Date.today())) {
          anchor = td.toDateTime();
        } else if (td != null) {
          anchor = DateTime.now();
        }
      }
      if (anchor == null) {
        _log.info(
          '[block-drop] cross-period drop with no anchor and no date — '
          'skipping (priority=${sourcePriority.id})',
        );
        return;
      }
      _log.info(
        '[block-drop] cross-period move: priority=${sourcePriority.id} '
        'sourceGap=$sourcePeriodStart -> targetGap=$anchor '
        '(targetPeriodStart=${target.targetPeriodStart}, '
        'targetDate=${target.targetDate})',
      );
      bloc.moveBlock(
        blockId: payload.blockId,
        threadIds: sourceThreadIds,
        targetGapAnchorAt: anchor,
      );
      return;
    }

    // Same-period reorder — find bracketing priority-bearing blocks
    // within the TARGET'S period only. Standalone priority blocks
    // (thread == null) bracket the new ordering; events (thread != null)
    // are skipped because they're anchored to a fixed time and don't
    // participate in priority_block ordering. Headers whose period
    // anchor differs from the target's are skipped — without this, the
    // walk crosses period boundaries and brackets against blocks in the
    // previous period (e.g. dropping at the top of the 1:30 period
    // would bracket against the 12:00 financial_mgmt block above the
    // lunch event), which writes a nonsensical order and visually
    // leaves the source where it was.
    //
    // Outside-priority blocks DO count: the user sees them in the
    // agenda, can drag past them, and expects the visual order to
    // persist. `reorderBlockWithinPeriod` writes a `priority_block`
    // row for the source priority with an order derived from the
    // bracketing priorities' orders, regardless of whether those
    // bracket priorities are "in" or "outside" the current page's
    // priority context.
    final insertionIndex = _targetInsertionIndex(target, listItems);
    _log.info(
      '[block-drop] walks: sourceIndex=$sourceIndex '
      'insertionIndex=$insertionIndex listLen=${listItems.length}',
    );
    final targetPeriod = target.targetPeriodStart;
    bool inSamePeriod(AgendaHeaderItem h) {
      // Gap headers carry their own period; other block headers
      // (events, priority blocks) inherit the surrounding period.
      return h.sourcePeriodStart == targetPeriod;
    }
    PriorityId? above;
    for (var i = insertionIndex - 1; i >= 0; i--) {
      final candidate = listItems[i];
      if (candidate is! AgendaHeaderItem) continue;
      _log.info(
        '[block-drop] above-walk i=$i parentBlockId=${candidate.parentBlockId} '
        'blockPriority=${candidate.blockPriority?.id} '
        'thread=${candidate.thread != null} '
        'date=${candidate.date} '
        'sourcePeriodStart=${candidate.sourcePeriodStart} '
        'isOutside=${candidate.isOutsidePriority}',
      );
      if (candidate.date != null) break;
      if (candidate.parentBlockId == payload.blockId) continue;
      if (!inSamePeriod(candidate)) break;
      if (candidate.blockPriority != null && candidate.thread == null) {
        above = candidate.blockPriority!.id;
        break;
      }
    }
    PriorityId? below;
    for (var i = insertionIndex; i < listItems.length; i++) {
      final candidate = listItems[i];
      if (candidate is! AgendaHeaderItem) continue;
      _log.info(
        '[block-drop] below-walk i=$i parentBlockId=${candidate.parentBlockId} '
        'blockPriority=${candidate.blockPriority?.id} '
        'thread=${candidate.thread != null} '
        'date=${candidate.date} '
        'sourcePeriodStart=${candidate.sourcePeriodStart} '
        'isOutside=${candidate.isOutsidePriority}',
      );
      if (candidate.date != null) break;
      if (candidate.parentBlockId == payload.blockId) continue;
      if (!inSamePeriod(candidate)) break;
      if (candidate.blockPriority != null && candidate.thread == null) {
        below = candidate.blockPriority!.id;
        break;
      }
    }

    if (above == sourcePriority.id || below == sourcePriority.id) {
      _log.info(
        '[block-drop] same-period reorder skipped: bracketing priority '
        'matches source (priority=${sourcePriority.id} '
        'above=$above below=$below insertionIndex=$insertionIndex)',
      );
      return;
    }

    // Nothing else lives in this period — there's no ordering to
    // express. Without this guard each rapid-fire drop in a
    // single-block period would call [reorderBlockWithinPeriod], which
    // writes a new `priority_block` row at `effective_at = now` with
    // `archivePast: true`, churning the timeline and discarding still-
    // meaningful older rows for nothing.
    if (above == null && below == null) {
      _log.info(
        '[block-drop] same-period reorder skipped: no bracketing blocks '
        '(priority=${sourcePriority.id} insertionIndex=$insertionIndex '
        'listLen=${listItems.length})',
      );
      return;
    }

    final periodReferenceTime = target.targetPeriodStart ?? DateTime.now();
    _log.info(
      '[block-drop] same-period reorder: priority=${sourcePriority.id} '
      'above=${above ?? "-"} below=${below ?? "-"} '
      'period=$periodReferenceTime',
    );
    bloc.reorderBlockWithinPeriod(
      priorityId: sourcePriority.id,
      periodReferenceTime: periodReferenceTime,
      above: above,
      below: below,
    );
  }

  /// Resolve the listItems index where a [BlockDropTarget] sits.
  ///
  /// - If [target.nextBlockId] is non-null, the boundary is rendered
  ///   above the row whose [parentBlockId] matches it.
  /// - If [nextBlockId] is null and [prevBlockId] is non-null, the
  ///   boundary sits right after the prev block's last thread row —
  ///   either at the end of the list (afterListBoundary) or at a
  ///   section break (immediately before the next date/text header).
  ///   Both look the same to the dispatcher; we resolve by locating
  ///   prev's header and advancing past its thread rows.
  /// - Otherwise the boundary is at the end of the list.
  int _targetInsertionIndex(
    BlockDropTarget target,
    List<AgendaItem> listItems,
  ) {
    final next = target.nextBlockId;
    if (next != null) {
      for (var i = 0; i < listItems.length; i++) {
        final it = listItems[i];
        if (it is AgendaHeaderItem && it.parentBlockId == next) {
          return i;
        }
      }
    }
    final prev = target.prevBlockId;
    if (prev != null) {
      var prevIdx = -1;
      for (var i = 0; i < listItems.length; i++) {
        final it = listItems[i];
        if (it is AgendaHeaderItem && it.parentBlockId == prev) {
          prevIdx = i;
          break;
        }
      }
      if (prevIdx >= 0) {
        var k = prevIdx + 1;
        while (k < listItems.length) {
          final it = listItems[k];
          // Walk past any rows belonging to prev's block. Anything
          // else (next block's header, next section's header, or end
          // of list) marks the section's end and is the right
          // insertion index.
          if (it is AgendaThreadItem && it.parentBlockId == prev) {
            k++;
            continue;
          }
          if (it is AgendaHeaderItem && it.parentBlockId == prev) {
            k++;
            continue;
          }
          break;
        }
        return k;
      }
    }
    return listItems.length;
  }

  /// Build the reorder callback for a priority-block header drag.
  ///
  /// On drop the closure resolves the **target period** (the gap region
  /// or the date section the new index falls inside) and the
  /// **source period** (the same, scanned around `oldIndex`):
  ///
  ///   * Same period → [PriorityBloc.reorderBlockWithinPeriod] with
  ///     the bracketing priority neighbours and the period's reference
  ///     time (gap start for an explicit gap, `now` for today's do-now).
  ///   * Different period → [PriorityBloc.moveBlock] with the target
  ///     gap's anchor time. Every thread in the block is re-anchored
  ///     to the new gap (rule 3 of the redesign).
  ///
  /// Drops over an event row snap to the nearest gap boundary above /
  /// below the event by scanning backwards / forwards for the closest
  /// gap header before / after the drop point.
  void Function(int newIndex)? _buildBlockHeaderReorderCallback({
    required BuildContext context,
    required List<AgendaItem> listItems,
    required int oldIndex,
    required Priority sourcePriority,
  }) {
    return (int newIndex) {
      if (newIndex == oldIndex || newIndex == oldIndex + 1) {
        // No-op: dropped at its own slot.
        return;
      }

      // Scan center in pre-removal coordinates: when dragging down,
      // indices after oldIndex shift by 1 in the post-removal
      // coordinates the ReorderableListView uses.
      final scanCenter = oldIndex < newIndex ? newIndex : newIndex - 1;

      final source = _resolvePeriod(
        listItems,
        oldIndex,
        scanFromIndex: oldIndex,
      );
      final target = _resolvePeriod(
        listItems,
        oldIndex,
        scanFromIndex: scanCenter,
      );

      // Cross-period move: the target gap differs from the source gap
      // (or the target sits in a different date section). Rewrite every
      // thread in the source block to anchor in the target gap.
      final sameSection = source.dateAnchor == target.dateAnchor;
      final sameGap = source.gapAnchor == target.gapAnchor;
      if (!sameSection || !sameGap) {
        if (target.gapAnchor == null) {
          // Cross-period move into a section with no gap anchor (e.g.
          // dropping into a future day's pre-first-event area before
          // any explicit gap header). Fall back to today's do-now
          // semantics — anchor to the next-event boundary if we can
          // find one, else now.
          _log.info(
            '[onReorder block] cross-period drop with no gap anchor — '
            'no-op for now (priority=${sourcePriority.id})',
          );
          return;
        }
        // Resolve the source block id from the dragged row's
        // `parentBlockId`. The bloc filter scopes the move to that
        // block's threads only — this safety-net path is dormant in
        // practice (block headers don't produce reorderable indices),
        // but if something re-introduces it we don't want it to fall
        // back to the old priority-wide filter.
        final sourceItem = listItems[oldIndex];
        final sourceBlockId = sourceItem is AgendaHeaderItem
            ? sourceItem.parentBlockId
            : null;
        if (sourceBlockId == null) {
          _log.warning(
            '[onReorder block] cross-period drop with no source block id — '
            'skipping (priority=${sourcePriority.id})',
          );
          return;
        }
        // Collect the source block's thread ids from the contiguous
        // run after its header — moveBlock now operates on ids rather
        // than looking the block up from the bloc's agenda.
        final sourceThreadIds = <ThreadId>{};
        for (var i = oldIndex + 1; i < listItems.length; i++) {
          final it = listItems[i];
          if (it is AgendaThreadItem && it.parentBlockId == sourceBlockId) {
            sourceThreadIds.add(it.thread.id);
            continue;
          }
          if (it is AgendaHeaderItem && it.parentBlockId == sourceBlockId) {
            continue;
          }
          break;
        }
        _log.info(
          '[onReorder block] cross-period move: block=$sourceBlockId '
          'priority=${sourcePriority.id} '
          'sourceGap=${source.gapAnchor} -> targetGap=${target.gapAnchor}',
        );
        context.read<PriorityBloc>().moveBlock(
          blockId: sourceBlockId,
          threadIds: sourceThreadIds,
          targetGapAnchorAt: target.gapAnchor!,
        );
        return;
      }

      // Same-period reorder: identify bracketing priority headers in
      // the target period.
      Priority? above;
      Priority? below;
      for (var i = scanCenter; i >= 0; i--) {
        if (i == oldIndex) continue;
        final candidate = listItems[i];
        if (candidate is AgendaHeaderItem) {
          if (candidate.date != null) break;
          if (candidate.blockPriority != null &&
              candidate.thread == null &&
              candidate.date == null) {
            above ??= candidate.blockPriority;
          }
        }
      }
      for (var i = scanCenter + 1; i < listItems.length; i++) {
        if (i == oldIndex) continue;
        final candidate = listItems[i];
        if (candidate is AgendaHeaderItem) {
          if (candidate.date != null) break;
          if (candidate.blockPriority != null &&
              candidate.thread == null &&
              candidate.date == null) {
            below ??= candidate.blockPriority;
            break;
          }
        }
      }

      final periodReferenceTime = target.gapAnchor ?? DateTime.now();
      final aboveId = above?.id;
      final belowId = below?.id;
      if (aboveId == sourcePriority.id || belowId == sourcePriority.id) {
        return;
      }

      _log.info(
        '[onReorder block] same-period reorder: priority=${sourcePriority.id} '
        'above=${above?.path.value ?? "-"} '
        'below=${below?.path.value ?? "-"} '
        'period=$periodReferenceTime',
      );

      context.read<PriorityBloc>().reorderBlockWithinPeriod(
        priorityId: sourcePriority.id,
        periodReferenceTime: periodReferenceTime,
        above: aboveId,
        below: belowId,
      );
    };
  }

  /// Resolve the time period that contains the item at [scanFromIndex].
  ///
  /// Walks backwards looking for the nearest gap header (a header with
  /// a non-null dateTimeRange and no event thread) and the nearest date
  /// header. Returns both anchors so callers can compare them across
  /// source / target positions to detect cross-period moves.
  ({DateTime? gapAnchor, Date? dateAnchor}) _resolvePeriod(
    List<AgendaItem> listItems,
    int oldIndex, {
    required int scanFromIndex,
  }) {
    DateTime? gapAnchor;
    Date? dateAnchor;
    for (var i = scanFromIndex; i >= 0; i--) {
      if (i == oldIndex) continue;
      final candidate = listItems[i];
      if (candidate is AgendaHeaderItem) {
        if (candidate.dateTimeRange?.start != null &&
            candidate.thread == null &&
            candidate.date == null) {
          gapAnchor ??= candidate.dateTimeRange!.start;
        }
        if (candidate.date != null) {
          dateAnchor = candidate.date;
          break;
        }
      }
    }
    return (gapAnchor: gapAnchor, dateAnchor: dateAnchor);
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
    final isSearching = state.search.isNotEmpty;
    final displayItems = <AgendaItem>[...items];
    if (isSearching && state.remoteSearchExtras.isNotEmpty) {
      displayItems.add(const AgendaHeaderItem(text: 'From the server'));
      for (final t in state.remoteSearchExtras) {
        displayItems.add(AgendaThreadItem(t));
      }
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

    // Compute drop boundaries once per build; the same map is re-read by
    // the per-row builder. The dispatcher closure captures `displayItems`
    // and the bloc so it can resolve section context on drop.
    final boundaries = computeActivityFeedDropBoundaries(items: displayItems);
    _activityFeedDragController.dispatcher = (payload, target) {
      dispatchActivityFeedThreadDrop(
        bloc: bloc,
        payload: payload,
        target: target,
      );
    };
    _activityFeedDragController.previewBuilder = (payload) {
      Thread? source;
      for (final item in displayItems) {
        if (item is AgendaThreadItem &&
            item.thread.id.toString() == payload.blockId) {
          source = item.thread;
          break;
        }
      }
      if (source == null) return null;
      return ThreadWidget(
        activity: source,
        selected: false,
        now: false,
        focusNode: FocusNode(skipTraversal: true),
        context: state.context,
        showSubPriority: true,
        bump: false,
        showEventTiming: false,
      );
    };

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
                target: dropAbove,
                slotKey: 'feed_drop_above_$index',
              ),
            ...current.when(
              header: (header) {
                String? displayText = header.text;
                final marker = displayText == null
                    ? null
                    : ActivitySectionMarker.tryDecode(displayText);
                if (marker != null) displayText = marker.label;
                return [
                  AgendaHeader(
                    priorityContext: state.context,
                    dateTimeRange: header.dateTimeRange,
                    date: header.date,
                    now: header.now,
                    thread: header.thread,
                    focusNode: focusNode,
                    text: displayText,
                    scheduleAt: header.scheduleAt,
                  ),
                ];
              },
              activity: (agendaActivity) {
                final baseThread = agendaActivity.thread;
                return [
                  ActivityFeedDraggableRow(
                    threadId: baseThread.id,
                    priorityContext: state.context,
                    child: _ActivityFeedItem(
                      key: ValueKey(
                        'feed_activitywidget_${baseThread.id}',
                      ),
                      baseThread: baseThread,
                      selected:
                          state.thread != null &&
                          baseThread.id == state.thread!.id,
                      now: agendaActivity.now,
                      focusNode: focusNode,
                      priorityContext: state.context,
                    ),
                  ),
                ];
              },
            ),
            if (tail != null)
              BlockDropZone(target: tail, slotKey: 'feed_drop_tail'),
          ],
        );
      },
    );

    return BlockDragScope(
      controller: _activityFeedDragController,
      child: list,
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

class _DesktopTabBar extends StatelessWidget {
  const _DesktopTabBar({
    required this.currentTab,
    required this.onTabChanged,
    required this.priority,
    this.hasUnreadActivity = false,
  });

  final PriorityTab currentTab;
  final ValueChanged<PriorityTab> onTabChanged;
  final Priority priority;
  final bool hasUnreadActivity;

  @override
  Widget build(BuildContext context) {
    final borderSide = BorderSide(color: context.theme.colors.border);
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(bottom: borderSide)),
      position: DecorationPosition.foreground,
      child: Stack(
        children: [
          Row(
            children: [
              _DesktopTab(
                label: 'Agenda',
                selected: currentTab == PriorityTab.agenda,
                border: Border(right: borderSide),
                onTap: () => onTabChanged(PriorityTab.agenda),
              ),
              _DesktopTab(
                label: 'Activity',
                selected: currentTab == PriorityTab.activityFeed,
                onTap: () => onTabChanged(PriorityTab.activityFeed),
                showUnreadDot: hasUnreadActivity,
                trailing: _NotificationButton(
                  onTap: () => context.run(ShowAttentionSettings(priority)),
                ),
              ),
            ],
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 2,
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              alignment: currentTab == PriorityTab.agenda
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: 0.5,
                heightFactor: 1.0,
                child: ColoredBox(
                  color: context.colour.accent.withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopTab extends StatefulWidget {
  const _DesktopTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.border,
    this.showUnreadDot = false,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Border? border;
  final bool showUnreadDot;
  final Widget? trailing;

  @override
  State<_DesktopTab> createState() => _DesktopTabState();
}

class _DesktopTabState extends State<_DesktopTab> {
  bool _hovered = false;

  static const _dotSize = 6.0;
  static const _dotSpacing = 4.0;

  Widget _unreadDot(Color color, {required bool visible}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _dotSpacing),
      child: SizedBox(
        width: _dotSize,
        height: _dotSize,
        child: visible
            ? DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final darkBg = darkenTheme(
      context,
      theme,
      context.colour,
      steps: 2,
    ).colors.background;

    final Color background;
    if (widget.selected) {
      background = theme.colors.background;
    } else if (_hovered) {
      background = theme.colors.secondary;
    } else {
      background = darkBg;
    }

    final textColor = widget.selected
        ? context.colour.accent
        : theme.colors.mutedForeground;

    return Expanded(
      child: GestureDetector(
        onTap: widget.selected ? null : widget.onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Container(
            decoration: BoxDecoration(color: background, border: widget.border),
            padding: EdgeInsets.symmetric(vertical: theme.spacing.xs),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _unreadDot(
                      context.colour.accent.withValues(alpha: 0.7),
                      visible: widget.showUnreadDot,
                    ),
                    Text(
                      widget.label,
                      style: theme.typography.sm.copyWith(
                        fontFamily: theme.typography.fontFamily,
                        color: textColor,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    _unreadDot(textColor, visible: false),
                  ],
                ),
                if (widget.trailing != null)
                  Positioned(right: 0, child: widget.trailing!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationButton extends StatefulWidget {
  const _NotificationButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_NotificationButton> createState() => _NotificationButtonState();
}

class _NotificationButtonState extends State<_NotificationButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Icon(
            PlotIcon.notification,
            size: 14,
            color: _hovered
                ? context.theme.colors.foreground
                : context.theme.plotColors.veryMuted,
          ),
        ),
      ),
    );
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
  });

  final Thread baseThread;
  final bool selected;
  final bool now;
  final FocusNode focusNode;
  final Priority priorityContext;

  @override
  State<_ActivityFeedItem> createState() => _ActivityFeedItemState();
}

class _ActivityFeedItemState extends State<_ActivityFeedItem> {
  late Future<Thread?> _representative;

  @override
  void initState() {
    super.initState();
    _representative = Thread.loadRepresentativeForFeed(
      widget.baseThread,
      now: DateTime.now(),
    );
  }

  @override
  void didUpdateWidget(covariant _ActivityFeedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.baseThread.id != widget.baseThread.id ||
        oldWidget.baseThread.scheduleId != widget.baseThread.scheduleId ||
        oldWidget.baseThread.currentUserRsvp !=
            widget.baseThread.currentUserRsvp) {
      _representative = Thread.loadRepresentativeForFeed(
        widget.baseThread,
        now: DateTime.now(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Thread?>(
      future: _representative,
      builder: (context, snapshot) {
        final rep = snapshot.data;
        final display = rep ?? widget.baseThread;
        return ThreadWidget(
          key: ValueKey(
            'feed_activitywidget_${widget.baseThread.id}_'
            '${rep?.scheduleId ?? widget.baseThread.scheduleId}',
          ),
          activity: display,
          selected: widget.selected,
          now: widget.now,
          focusNode: widget.focusNode,
          context: widget.priorityContext,
          showSubPriority: true,
          bump: false,
          showEventTiming: rep != null,
        );
      },
    );
  }
}

