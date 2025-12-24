import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
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
  final GlobalKey<NoteEditorState> _noteEditorKey =
      GlobalKey<NoteEditorState>();

  // Store reference to provider to avoid unsafe ancestor lookup in dispose()
  PriorityShortcutsProviderState? _provider;

  // Timer for delayed read marking
  Timer? _markReadTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Save reference during a safe lifecycle method
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    // Schedule marking activity as read after 750ms
    _scheduleMarkAsRead();
  }

  @override
  void dispose() {
    // Cancel the mark-as-read timer if still pending
    _markReadTimer?.cancel();
    // Unregister from the focus coordination provider
    // Use saved reference instead of looking up during dispose()
    _provider?.unregisterActivityPanel();
    super.dispose();
  }

  /// Schedules marking the activity as read after 750ms.
  /// Cancels any previously scheduled mark-as-read operation.
  void _scheduleMarkAsRead() {
    // Cancel any existing timer
    _markReadTimer?.cancel();

    // Start new timer for 750ms delay
    _markReadTimer = Timer(const Duration(milliseconds: 750), () {
      final activity = context.read<ActivityBloc>().state.activity;
      if (activity.unread) {
        activity.copyWith(unread: false).save();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ActivityBloc, ActivityState>(
      listener: (context, state) {
        // Reschedule mark as read when new notes are synced
        _scheduleMarkAsRead();
      },
      listenWhen: (previous, current) =>
          previous.notes != current.notes &&
          current.activity.unread,
      child: BlocListener<ActivityBloc, ActivityState>(
        listener: (context, state) {
          // Focus NoteEditor when activity thread changes
          // (BidirectionalListSelector is keyed by activity.id, so it creates a fresh controller)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _noteEditorKey.currentState?.focus();
          });
        },
        listenWhen: (previous, current) =>
            previous.activity.id != current.activity.id,
        child: BlocBuilder<ActivityBloc, ActivityState>(
          builder: (context, state) {
            return _buildContent(context, state);
          },
        ),
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

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && !layoutStateForPanels.multiPanel) {
              context.run(ChangeCurrentActivity(null));
            }
          },
          child: BidirectionalListSelector(
            key: ValueKey('activity_list_${state.activity.id}'),
            reverse: true,
            builder: (context, listController) {
              // Register this ActivityPage with the global focus coordination provider
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final provider = ActivityPanelControllerProvider.maybeOf(
                  context,
                );
                provider?.registerActivityPanel(
                  listController: listController,
                  editorFocusCallback: () =>
                      _noteEditorKey.currentState?.focus(),
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
                      // If already at first item (index 0), focus the NoteEditor
                      if (listController.focusedIndex == 0) {
                        listController.clearFocus();
                        _noteEditorKey.currentState?.focus();
                      } else {
                        listController.moveFocus(-1);
                      }
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.enter) {
                      final focusedIndex = listController.focusedIndex;
                      if (focusedIndex != null) {
                        final note = _getNoteAtIndex(state, focusedIndex);
                        if (note != null) {
                          context.run(
                            OpenFocusedItemActions(listController, (index) {
                              final note = _getNoteAtIndex(state, index);
                              if (note == null) return [];
                              return noteCommandGroups(note);
                            }),
                          );
                          return KeyEventResult.handled;
                        }
                      }
                    }
                    if (event.logicalKey == LogicalKeyboardKey.escape) {
                      listController.clearFocus();
                      // Focus NoteEditor after clearing item focus
                      _noteEditorKey.currentState?.focus();
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
                    childPad: layoutStateForPanels.multiPanel,
                    header: Header(
                      title: state.activity.displayTitle,
                      prefixCommands: prefixActions,
                      onSearchChanged: (search) =>
                          context.read<ActivityBloc>().updateSearch(search),
                      onSearchClosed: () =>
                          context.read<ActivityBloc>().updateFilter([]),
                      filterCommands: state.tags
                          .map(
                            (tagData) =>
                                ToggleNoteFilter(tagData.$1, context: context),
                          )
                          .toList(),
                      commands: [
                        // Show primary command based on activity state
                        primaryActivityCommand(
                          state.activity,
                          stateIcon: false,
                        ),

                        // Show active tags (up to 3)
                        ...state.tags
                            .where(
                              (tagData) => state.activity.hasTag(tagData.$1),
                            )
                            .take(3)
                            .map(
                              (tagData) =>
                                  ToggleActivityTag(state.activity, tagData.$1),
                            ),

                        // Always show the command menu
                        ShowActivityCommands(state.activity),
                      ],
                    ),
                    body: Column(
                      spacing: 8,
                      children: [
                        Flexible(
                          flex: 1,
                          fit: FlexFit.tight,
                          child: layoutStateForPanels.multiPanel
                              ? _buildActivityList(
                                  state,
                                  listController,
                                  context,
                                )
                              : Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 16),
                                  child: _buildActivityList(
                                    state,
                                    listController,
                                    context,
                                  ),
                                ),
                        ),
                        // Editor is edge-to-edge in single panel mode
                        NoteEditor(
                          key: _noteEditorKey,
                          draft: state.draft,
                          flushToBottom: !layoutStateForPanels.multiPanel,
                        ),
                      ],
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

  int _getTotalItemCount(ActivityState state) {
    return state.notes.length;
  }

  Note? _getNoteAtIndex(ActivityState state, int index) {
    if (index >= 0 && index < state.notes.length) {
      return state.notes[index];
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
      builder: (context, index, focusNode, {reorderableIndex}) {
        return _buildItemAtIndex(
          state,
          index,
          focusNode,
          reorderableIndex: reorderableIndex,
        );
      },
    );
  }

  Widget _buildItemAtIndex(
    ActivityState state,
    int index,
    FocusNode focusNode, {
    int? reorderableIndex,
  }) {
    final note = _getNoteAtIndex(state, index);
    if (note != null) {
      return NoteWidget(
        note: note,
        selected: false, // No selection on ActivityPage
        focusNode: focusNode,
        key: ValueKey(note.id),
        reorderableIndex: reorderableIndex,
      );
    }
    return const SizedBox.shrink();
  }
}
